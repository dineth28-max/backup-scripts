# Antlerfoundry SQL Server Backup — Run Guide

Backs up every SQL Server defined as an `MSSQL_<n>_*` block in `config/backup.env`
one after another to `gs://<GCS_BUCKET>/<GCS_PREFIX>/<container>/<stamp>/`,
keeping 3 days per container. Runs at 02:00 from cron.

## 0. One-time

```bash
# SqlPackage
curl -L -o /tmp/sqlpackage.zip https://aka.ms/sqlpackage-linux
sudo mkdir -p /opt/sqlpackage && sudo unzip /tmp/sqlpackage.zip -d /opt/sqlpackage
sudo chmod +x /opt/sqlpackage/sqlpackage && sudo ln -s /opt/sqlpackage/sqlpackage /usr/local/bin/sqlpackage

# Config + per-container password files
cp config/backup.env.example config/backup.env
./scripts/discover_instances.sh --write-secrets /opt/antlerfoundry/secrets/mssql
ls -l /opt/antlerfoundry/secrets/mssql/      # one <container>.password per instance, mode 600
```

Check every `MSSQL_<n>_*` block in `config/backup.env` (the helper prints
ready-made blocks you can paste). Each needs CONTAINER, HOST, PORT, USER,
PASSWORD_FILE and DATABASE.

## 1. Dry run

```bash
./scripts/backup_mssql.sh --dry-run
```

Checks GCP auth, every password file, and logs into every container to list
its databases. Does not export or upload anything.

## 2. Real run

```bash
./scripts/backup_mssql.sh --only ms-sql-server-dev-antlerhrmdfc   # one instance first
./scripts/backup_mssql.sh                                         # then all
gcloud storage ls -r gs://db_backups_antler/ovh-vps-4a559a55/
```

## 3. Schedule

```bash
./scripts/install_cron.sh
crontab -l
```

## Troubleshooting

Logs: `$LOG_DIR/backup_mssql_<date>.log` (includes sqlpackage's own output) and `logs/cron.log`.

| Symptom | Likely cause |
|---|---|
| `[<name>] incomplete block <n>` | That `MSSQL_<n>_*` block is missing the fields listed |
| `[<name>] password file not found` | `MSSQL_<n>_PASSWORD_FILE` points to a file that doesn't exist |
| `backup.env: line N: ...: command not found` | A value with a space in it (e.g. `DbA, DbB`) — remove the space or quote it |
| `[<name>] could not list databases` | Wrong password in the file, container stopped, or name typo |
| `[<name>] no sqlcmd found inside the container` | Container not running, or an image without mssql-tools — set `MSSQL_<n>_DATABASE` to real names instead of `*` |
| `SqlPackage export failed for <db>` | Wrong `MSSQL_<n>_HOST`/`PORT`/`DATABASE`, auth failed, or export timed out (`EXPORT_TIMEOUT`) — see the log |
| `skipping retention prune` | Expected after a failure: older backups for that container are kept |
| `GOOGLE_APPLICATION_CREDENTIALS file not found` / `Failed to activate` | Key path wrong or key revoked |
| `Another backup run is already holding ...` | Previous run still going (16 instances in a queue can take a while) |
| `sqlpackage not found on PATH` | Cron's PATH lacks `/usr/local/bin` — check the symlink from step 0 |
