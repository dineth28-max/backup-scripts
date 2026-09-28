# Antlerfoundry SQL Server — Database Backup (all systems on one host)

One host (OVH `vps-4a559a55`) runs many AntlerHRM systems, each with its own
SQL Server container (`ms-sql-server-dev-antlerhrm*`, `middleware-sqlserver`),
published on its own host port. This repo backs up **all of them** from one
cron job to Google Cloud Storage as **`.bacpac`** exports (schema + data, via
SqlPackage).

**Backup-only** — there is intentionally no restore script in this repo.

## 1. Strategy

```
02:00 cron ─► backup_mssql.sh
                │  for each MSSQL_<n>_* block in backup.env (one at a time — a queue)
                │    for each database in MSSQL_<n>_DATABASE (one at a time)
                │      sqlpackage /Action:Export  -> local .bacpac (staging)
                │      upload .bacpac + .sha256   -> GCS <container>/<stamp>/
                │      delete local copy
                │    prune that container's folder to the last 3 days
                ▼
               GCS
```

- **Sequential, never parallel**: only one export runs at a time, so the host
  (which also serves every system) is never hit by 16 exports at once, and
  local disk only ever holds one `.bacpac`.
- **One failure doesn't stop the queue**: a failed instance is logged and the
  script moves on to the next. At the end it exits non-zero and sends an
  alert (if `ALERT_EMAIL` is set) listing the failed instances.
- **Databases come from `.env`**: `MSSQL_<n>_DATABASE` names them
  (`antler`, or `DbA,DbB`). `*` instead lists every online user database by
  running `sqlcmd` inside that container.
- **Retention: 3 days per container.** After a container's backup succeeds,
  its date folders older than `DAILY_RETENTION_DAYS` are deleted — a 4th
  day's run removes the 1st day, so 3 remain. **If a container's backup
  failed, its folder is not pruned**, so good older backups are never
  deleted while new ones aren't landing.

### GCS layout (bucket `db_backups_antler`)

```
gs://db_backups_antler/<GCS_PREFIX>/                      e.g. ovh-vps-4a559a55/
  ms-sql-server-dev-antlerhrmdfc/
    2026-09-25_020001/<db>_2026-09-25_020001.bacpac(.sha256)
    2026-09-26_020003/...
    2026-09-27_020002/...        (only the last 3 days exist)
  ms-sql-server-dev-antlerhrmwti/
    ...
  middleware-sqlserver/
    ...
```

**`.bacpac` trade-off**: a logical export (schema + data). It does not capture
server logins, the transaction log, or point-in-time recovery, and is slower
than a native `.bak` on large databases. Portable across SQL Server versions.

## 2. Configuration — only `config/backup.env` changes between servers

The scripts are identical on every server. `config/backup.env` (copy of
`config/backup.env.example`, gitignored) decides **how many SQL Servers** are
backed up and **which databases**. Each SQL Server is one numbered block with
its full connection details:

```bash
# --- SQL Server 1 ---
MSSQL_1_CONTAINER=ms-sql-server-dev-antlerhrmdfc     # docker container = GCS folder name
MSSQL_1_HOST=localhost
MSSQL_1_PORT=13727
MSSQL_1_USER=sa
MSSQL_1_PASSWORD_FILE=/opt/antlerfoundry/secrets/mssql_password
MSSQL_1_DATABASE=antler                              # or DbA,DbB  or * (all user DBs)

# --- SQL Server 2 ---
MSSQL_2_CONTAINER=...
```

The script finds every `MSSQL_<n>_CONTAINER`, sorts by `<n>`, and runs them
as a queue. A server with 2 SQL Servers has blocks 1–2; one with 6 has 1–6.
To add a server, add the next block; to skip one, comment out its block.
If a block is missing a field, that server is reported as failed and the
others still run.

Rules: `PASSWORD_FILE` is a **path to a file** containing only the password,
never the password itself. Values can't contain spaces (`DbA,DbB`, not
`DbA, DbB`) unless wrapped in quotes. `DATABASE=*` lists databases with
`sqlcmd` inside the container, so it needs `CONTAINER` to match `docker ps`.

Other settings:

| Setting | What it does |
|---|---|
| `GCP_PROJECT_ID`, `GCS_BUCKET`, `GOOGLE_APPLICATION_CREDENTIALS` | Where backups go / service-account key file |
| `GCS_PREFIX` | Top-level folder for this server in the bucket |
| `BACKUP_CRON_SCHEDULE` | Cron time, **server timezone** (`"0 2 * * *"`). Re-run `install_cron.sh` after changing |
| `EXPORT_TIMEOUT` | Max time per database export (default `6h`; force-killed 5 min later if it won't stop) |
| `MIN_FREE_GB` | Skip an export if the staging disk has less free space than this (default `20`) |
| `BACKUP_TMP_DIR`, `LOG_DIR`, `LOCK_FILE` | Local staging / logs / lock |
| `LOG_RETENTION_DAYS` | Daily log files older than this are deleted (default `30`) |
| `DAILY_RETENTION_DAYS` | Days kept per SQL Server (`3`) |
| `ALERT_EMAIL` | Optional; needs `mail` installed on the host |

## 3. Setup (on the host)

**Install SqlPackage:**

```bash
curl -L -o /tmp/sqlpackage.zip https://aka.ms/sqlpackage-linux
sudo mkdir -p /opt/sqlpackage
sudo unzip /tmp/sqlpackage.zip -d /opt/sqlpackage
sudo chmod +x /opt/sqlpackage/sqlpackage
sudo ln -s /opt/sqlpackage/sqlpackage /usr/local/bin/sqlpackage
sqlpackage /version
```

**Config + secrets:**

```bash
cd Backupscripting
cp config/backup.env.example config/backup.env    # then edit

# Optional helper: prints an MSSQL_<n>_* block for every SQL container running
# here, and writes one password file per container from its
# MSSQL_SA_PASSWORD / SA_PASSWORD env var (existing files never overwritten).
./scripts/discover_instances.sh --write-secrets /opt/antlerfoundry/secrets/mssql
```

If an `sa` password was changed after its container was created, the env
var is stale — fix that container's `.password` file by hand. Each file must
contain only the password.

The user running cron must be able to run `docker` (it's in the `docker`
group on this host) and read the secrets directory.

The GCP service account needs **`roles/storage.objectAdmin`** on the bucket
(create + list + delete). With only `objectCreator`, uploads work but the
3-day prune can't list/delete, so old backups pile up (logged as `WARN`).

git stores the scripts without the execute bit; run them with `bash`
(e.g. `bash scripts/backup_mssql.sh --dry-run`) or `chmod +x scripts/*.sh`
once. The cron line already calls `/bin/bash` explicitly.

**Test by hand before trusting cron:**

```bash
./scripts/backup_mssql.sh --dry-run                                  # checks GCP auth, passwords, lists every DB — exports nothing
./scripts/backup_mssql.sh --only ms-sql-server-dev-antlerhrmdfc      # real backup of one instance
./scripts/backup_mssql.sh                                             # full real run
```

**Install the cron job** (merges into the existing crontab). Cron uses the
server's timezone — check it first, and set `BACKUP_CRON_SCHEDULE` so the
run happens at night local time (on a UTC server, 02:00 Sri Lanka time is
`"30 20 * * *"`):

```bash
timedatectl | grep 'Time zone'
./scripts/install_cron.sh
crontab -l
```

gcloud runs with its own config dir (`Backupscripting/.gcloud/`), so the
script never changes the active gcloud account for anything else on the host.

## 4. Notes

- Restoring = download the `.bacpac`, verify with `sha256sum -c`, then
  `sqlpackage /Action:Import` into a target server. Not scripted here.
- `/SourcePassword` is passed to `sqlpackage` on the command line (it has no
  env-var alternative), so it's visible in `ps` during that export. Database
  discovery passes the password via the environment instead.
- A full run backs up 16 instances one by one — check `logs/` after the first
  night to see how long it takes and make sure it finishes well before the
  working day.
- Belt-and-braces: a GCS lifecycle rule (delete objects under `<GCS_PREFIX>/`
  older than ~7 days) catches anything left behind if cron silently stops.
  Keep it longer than 3 days so it never beats the script's own retention.
- Old single-instance backups under `gs://db_backups_antler/mssql-test/` are
  not touched by this script — delete them manually when no longer needed.

## 5. Files

```
Backupscripting/
├── README.md / RUNBOOK.md
├── config/backup.env.example     template — copy to backup.env
├── lib/common.sh                 logging / GCS / lock / retention helpers
├── scripts/
│   ├── backup_mssql.sh           the queue: every MSSQL_<n> block -> GCS, 3-day retention
│   ├── discover_instances.sh     prints MSSQL_<n>_* blocks from `docker ps`, writes password files
│   └── install_cron.sh           merges cron/crontab.txt into the user's crontab
├── cron/crontab.txt              02:00 daily
└── logs/
```
