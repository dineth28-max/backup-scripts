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

Run every command below from the repo folder as the **same user cron will
use** (`ubuntu`) — never with `sudo`, or root ends up owning the lock file
and `.gcloud/` and the cron run fails. `bash scripts/...` works even if the
scripts lost their execute bit.

## 1. Dry run

```bash
bash scripts/backup_mssql.sh --dry-run
```

Checks GCP auth, every password file, and prints the queue — every
`MSSQL_<n>_*` block in number order. For `DATABASE=*` it logs into the
container to list databases; for a fixed name (`DATABASE=antler`) it does
**not** connect, so a wrong port only shows up in the real run.
Does not export or upload anything.

## 2. Real run

### 2a. One SQL Server first

```bash
bash scripts/backup_mssql.sh --only ms-sql-server-dev-antlerhrmdfc
```

`--only <container>` backs up just that block. Use any `MSSQL_<n>_CONTAINER`
name from `backup.env`.

### 2b. All SQL Servers, one after another

```bash
bash scripts/backup_mssql.sh
```

This single command is the whole backup. It does exactly what cron does at
02:00. It walks every `MSSQL_<n>_*` block in `backup.env` **one at a time**
(1, 2, 3 …). Nothing runs in parallel. For each block it:

1. exports each database to a `.bacpac` (the live SqlPackage output is shown on screen)
2. uploads the `.bacpac` + `.sha256` to `gs://<GCS_BUCKET>/<GCS_PREFIX>/<container>/<stamp>/`
3. deletes the local copy
4. deletes that container's backup folders older than 3 days

If one server fails, it is logged and the queue moves on to the next.

With the current `backup.env` (5 servers) a successful run looks like:

```
[INFO] Queue: 5 SQL Server(s) defined in backup.env
[INFO] --- [sqlserver1] sa@localhost:1433 ---
...
[INFO] [sqlserver1] antler done
[INFO] --- [ms-sql-server-dev-antlerhrmdfc] sa@localhost:13727 ---
...
[INFO] [sqlserver4] antler done
[INFO] === backup_mssql.sh completed successfully (5 instances) ===
```

If anything failed, the last line is instead
`=== finished with failures: N failed, M ok. Failed: <names> ===`.

### 2c. Check that every SQL Server landed in GCS

```bash
# one folder per SQL Server (5 expected)
gcloud storage ls gs://db_backups_antler/ovh-vps-4a559a55/

# every backup, with sizes: each container/<stamp>/ must hold a .bacpac AND a .bacpac.sha256
gcloud storage ls -l -r gs://db_backups_antler/ovh-vps-4a559a55/

# optional: prove one backup is intact (checksum must print "OK")
mkdir -p /tmp/verify && cd /tmp/verify
gcloud storage cp "gs://db_backups_antler/ovh-vps-4a559a55/<container>/<stamp>/*" .
sha256sum -c *.sha256
cd - && rm -rf /tmp/verify
```

A `.bacpac` of only a few KB usually means an empty database. Compare sizes
between runs.

## 3. Schedule

```bash
timedatectl | grep 'Time zone'     # UTC server -> BACKUP_CRON_SCHEDULE="30 20 * * *" for 02:00 Sri Lanka
bash scripts/install_cron.sh       # must print "= 02:00 Sri Lanka time"
crontab -l
```

From then on, `bash scripts/backup_mssql.sh` (step 2b) runs by itself every
night. Check the result each morning:

```bash
tail -3 <LOG_DIR>/backup_mssql_$(date +%F).log   # last line should say "completed successfully"
```

After day 4, each `<container>/` folder should hold only 3 date folders.

## Troubleshooting

Logs: `$LOG_DIR/backup_mssql_<date>.log` (includes sqlpackage's own output) and `logs/cron.log`.

| Symptom | Likely cause |
|---|---|
| `[<name>] incomplete block <n>` | That `MSSQL_<n>_*` block is missing the fields listed |
| `[<name>] password file not found` | `MSSQL_<n>_PASSWORD_FILE` points to a file that doesn't exist |
| `backup.env: line N: ...: command not found` | A value with a space in it (e.g. `DbA, DbB`) — remove the space or quote it |
| `[<name>] could not list databases` | Wrong password in the file, container stopped, or name typo |
| `[<name>] no sqlcmd found inside the container` | Container not running, or an image without mssql-tools — set `MSSQL_<n>_DATABASE` to real names instead of `*` |
| `SqlPackage export failed for <db>` | Wrong `MSSQL_<n>_HOST`/`PORT`/`DATABASE`, auth failed, or export timed out (`EXPORT_TIMEOUT`). See the log |
| Stuck on `Connecting to database ...` | `MSSQL_<n>_PORT` doesn't match `docker ps` (the host port before `->1433/tcp`) |
| `skipping retention prune` | Expected after a failure: older backups for that container are kept |
| `GOOGLE_APPLICATION_CREDENTIALS file not found` / `Failed to activate` | Key path wrong or key revoked |
| `Another backup run is already holding ...` | Previous run still going (all instances run in one queue, which can take a while) |
| `sqlpackage not found on PATH` | Cron's PATH lacks `/usr/local/bin` — check the symlink from step 0 |
