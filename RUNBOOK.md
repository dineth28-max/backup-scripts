# Antlerfoundry SQL Server Backup — Run Guide

Assumes the SQL Server container, database, and GCS bucket are already up
and provisioned. This is just how to run the backup script.

## 1. Confirm `config/backup.env` is filled in

Two fields must have real values (not placeholders) before running:

```
GCP_PROJECT_ID=<your real GCP project id>
MSSQL_DATABASE=<the real database name>
```

And these two files must already exist on the host:
- `/opt/antlerfoundry/secrets/mssql_sa_password`
- `/opt/antlerfoundry/secrets/gcs_service_account.json`

## 2. Dry run

```bash
cd /path/to/Backupscripting
./scripts/backup_mssql.sh --dry-run
```

Checks config, GCP auth, and the lock file — does not touch SQL Server or
upload anything.

## 3. Real run

```bash
./scripts/backup_mssql.sh
```

Verify it landed:

```bash
gcloud storage ls -l gs://db_backups_antler/mssql-dev/daily/
```

## 4. Schedule it (cron)

```bash
./scripts/install_cron.sh
crontab -l   # confirm the mssql-backup block is present
```

Runs daily at 02:00 from then on.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `GOOGLE_APPLICATION_CREDENTIALS file not found` | Wrong path in `backup.env`, or key file missing |
| `Failed to activate GCP service account credentials` | Key file invalid/revoked, or wrong `GCP_PROJECT_ID` |
| `BACKUP DATABASE failed for <db>` | Wrong `MSSQL_DATABASE` name, or `sa` auth failed |
| `docker cp failed` | Backup file was never created — check container disk space |
| `Another backup run is already holding ...` | A previous run is still in progress or crashed mid-run holding the lock |
