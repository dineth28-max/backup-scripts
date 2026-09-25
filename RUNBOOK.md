# Antlerfoundry SQL Server Backup — Run Guide

Assumes the SQL Server container, database, and GCS bucket are already up
and provisioned. This is just how to run the backup script.

Backs up as a **`.bacpac`** (schema + data, via SqlPackage) — connects
directly to the SQL Server TCP endpoint, no `docker exec` needed for the
export itself.

## 0. One-time: install SqlPackage on the host

```bash
curl -L -o /tmp/sqlpackage.zip https://aka.ms/sqlpackage-linux
sudo mkdir -p /opt/sqlpackage
sudo unzip /tmp/sqlpackage.zip -d /opt/sqlpackage
sudo chmod +x /opt/sqlpackage/sqlpackage
sudo ln -s /opt/sqlpackage/sqlpackage /usr/local/bin/sqlpackage
sqlpackage /version
```

## 1. Confirm `config/backup.env` is filled in

```
GCP_PROJECT_ID=<your real GCP project id>
MSSQL_HOST=localhost
MSSQL_PORT=13727
MSSQL_DATABASE=<the real database name>
MSSQL_PASSWORD_FILE=/opt/antlerfoundry/secrets/mssql_sa_password
BACKUP_NAME_PREFIX=<e.g. ovh_ms-sql-server-dev-antlerhrmdfc>
```

**`MSSQL_PASSWORD_FILE` must be a path to a file, not the password itself.**
That file and the GCS key file must already exist on the host:

```bash
cat /opt/antlerfoundry/secrets/mssql_sa_password       # should print the sa password, nothing else
cat /opt/antlerfoundry/secrets/gcs_service_account.json  # should be a JSON key file
```

## 2. Dry run

```bash
cd /path/to/Backupscripting
./scripts/backup_mssql.sh --dry-run
```

Checks config, GCP auth, and the lock file — does not touch SQL Server or
upload anything (does not prove `sqlpackage` or the `sa` credentials work).

## 3. Real run

```bash
./scripts/backup_mssql.sh
```

Verify it landed:

```bash
gcloud storage ls -l gs://db_backups_antler/mssql-test/daily/
```

(use whatever `GCS_PREFIX` is actually set to in your `backup.env`)

## 4. Schedule it (cron)

```bash
./scripts/install_cron.sh
crontab -l   # confirm the mssql-backup block is present
```

Runs daily at 02:00 from then on.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `MSSQL_PASSWORD_FILE not found: ...` | That field has the password itself instead of a file path, or the file doesn't exist yet |
| `GOOGLE_APPLICATION_CREDENTIALS file not found` | Wrong path in `backup.env`, or key file missing |
| `Failed to activate GCP service account credentials` | Key file invalid/revoked, or wrong `GCP_PROJECT_ID` |
| `SqlPackage export failed for <db>` | Wrong `MSSQL_DATABASE`/`MSSQL_HOST`/`MSSQL_PORT`, `sa` auth failed, or `sqlpackage` not installed |
| `SSL routines:tls_process_server_certificate` | Should already be fixed via `/SourceTrustServerCertificate:True` — if it recurs, check the flag is still in the script |
| `Another backup run is already holding ...` | A previous run is still in progress or crashed mid-run holding the lock |
