# Antlerfoundry SQL Server (dev) — Database Backup

Backup tooling for the Antlerfoundry SQL Server 2019 database running in its
own Docker container. Runs from cron on the host that container runs on,
ships everything to Google Cloud Storage. Exports a **`.bacpac`** (schema +
data) via SqlPackage, connecting directly to the SQL Server TCP endpoint —
no `docker exec`/`docker cp` involved.

**Backup-only** — there is intentionally no restore script in this repo.

There is no "Vertical Platform" / Postgres system here — that was a different,
now-removed project. Everything in this repo backs up exactly one thing: the
Antlerfoundry SQL Server database below.

## 1. What's being backed up

One database, named by `MSSQL_DATABASE` in `config/backup.env`, inside the
`ms-sql-server-dev-antlerhrmdfc` container (image
`mcr.microsoft.com/mssql/server:2019-latest`). Its port 1433 is mapped to
`13727` on the host, and the backup script connects to
`${MSSQL_HOST}:${MSSQL_PORT}` (i.e. `localhost:13727` when run on that same
host) — the same way any SQL client would.

## Is this actually working correctly? (status as of last review)

- **Export logic**: `sqlpackage /Action:Export` → sha256 sidecar → upload to
  GCS with daily/weekly/monthly tiering — verified by reading the script
  end-to-end, internally consistent.
- A real run against the container previously failed on a TLS/certificate
  error (`sqlcmd`'s ODBC Driver 18 refusing the self-signed cert) when this
  used a native `BACKUP DATABASE` — that approach has since been replaced
  entirely by the `.bacpac` export below. The TLS fix (`/SourceTrustServerCertificate:True`)
  carries over to this version.
- **Not yet proven by an actual run with SqlPackage**: nobody has executed
  this version of `backup_mssql.sh` yet. Until that happens, "the script is
  correct on paper" and "the script actually backs up this database" are not
  the same claim.
- **Before trusting it**: confirm `sqlpackage` is installed on the host
  (section 3), fill in `config/backup.env`, then run `./scripts/backup_mssql.sh`
  for real once and confirm the `.bacpac` + `.sha256` land in
  `gs://db_backups_antler/mssql-dev/daily/`. That's the only way to turn
  "should work" into "does work."

## 2. Strategy

```
SQL Server (TCP, e.g. localhost:13727)
   │  sqlpackage /Action:Export (schema + data -> .bacpac)
   ▼
 Upload
   │
   ▼
   GCS
```

One cron job, once a day: export the database to a `.bacpac`, upload to GCS.
The same day's export is also copied into a `weekly/` folder on Sundays and a
`monthly/` folder on the 1st of the month, giving three retention tiers from
one export run (grandfather-father-son rotation) — no extra load on SQL
Server to produce the weekly/monthly copies.

| Tier    | Taken            | Kept for  |
|---------|-------------------|-----------|
| Daily   | every day         | 14 days   |
| Weekly  | every Sunday      | 8 weeks   |
| Monthly | 1st of the month  | 12 months |

**Important trade-off vs. a native `.bak` backup**: a `.bacpac` is a logical
export (schema + data via `INSERT`-style bulk copy) — it does **not** capture
server-level logins, some SQL Server-specific features, or the transaction
log, and it's slower to produce/restore on larger databases. It's more
portable (works across SQL Server versions/editions, even into Azure SQL) but
is not a substitute for a true point-in-time disaster-recovery backup. This
was chosen because it's specifically what was asked for — revisit if this
database grows large enough that export time or feature coverage becomes a
problem.

## 3. Setup

**Install SqlPackage on the host** (this is new — it wasn't required by the
old `sqlcmd`-based approach):

```bash
curl -L -o /tmp/sqlpackage.zip https://aka.ms/sqlpackage-linux
sudo mkdir -p /opt/sqlpackage
sudo unzip /tmp/sqlpackage.zip -d /opt/sqlpackage
sudo chmod +x /opt/sqlpackage/sqlpackage
sudo ln -s /opt/sqlpackage/sqlpackage /usr/local/bin/sqlpackage
sqlpackage /version   # confirm it runs (requires the .NET runtime — the
                       # installer will tell you if that's missing)
```

Then the usual config:

```bash
cd Backupscripting
cp config/backup.env.example config/backup.env
# edit config/backup.env: real GCP_PROJECT_ID, GCS_BUCKET, MSSQL_DATABASE,
# MSSQL_HOST/MSSQL_PORT, BACKUP_NAME_PREFIX, paths for your host

mkdir -p /opt/antlerfoundry/secrets
echo -n 'the real sa password' > /opt/antlerfoundry/secrets/mssql_sa_password
chmod 600 /opt/antlerfoundry/secrets/mssql_sa_password

# service account needs Storage Object Admin (or equivalent) on the bucket
gcloud iam service-accounts keys create /opt/antlerfoundry/secrets/gcs_service_account.json \
  --iam-account=mssql-backup@your-gcp-project-id.iam.gserviceaccount.com
chmod 600 /opt/antlerfoundry/secrets/gcs_service_account.json
```

`config/backup.env` and the credential files are gitignored — never commit
real secrets. The example file ships with a **placeholder** project/bucket.
**`MSSQL_PASSWORD_FILE` must be a path to a file containing the password —
never the password itself.**

Test by hand before trusting cron with it:

```bash
./scripts/backup_mssql.sh --dry-run
./scripts/backup_mssql.sh          # real run — check logs/ and the GCS bucket
```

Install the daily cron job (merges into the existing crontab, doesn't
overwrite it):

```bash
./scripts/install_cron.sh
crontab -l   # confirm the mssql-backup block is present
```

Then **prove cron itself actually fires** — don't just trust the schedule:

```bash
# run once a minute temporarily to confirm cron is invoking the script at all
crontab -e   # add: * * * * * /path/to/Backupscripting/scripts/backup_mssql.sh --dry-run >> /path/to/Backupscripting/logs/cron_test.log 2>&1
tail -f Backupscripting/logs/cron_test.log
# once confirmed, remove the test line — the real 02:00 schedule from install_cron.sh stays
```

## 4. GCS layout (bucket: `db_backups_antler`)

```
gs://db_backups_antler/mssql-dev/
  daily/2026-09-25_020000/<BACKUP_NAME_PREFIX>_2026-09-25_020000.bacpac(.sha256)
  weekly/2026-09-20_020000/...   (same file, copied on Sundays)
  monthly/2026-09-01_020000/...  (same file, copied on the 1st)
```

`BACKUP_NAME_PREFIX` (set in `config/backup.env`) identifies which host/container
the backup came from, e.g. `ovh_ms-sql-server-dev-antlerhrmdfc`.

Every object gets a `.sha256` sidecar alongside it.

## 5. Retention

Enforced by `backup_mssql.sh` itself after every run (deletes objects older
than the configured window in each tier — `DAILY_RETENTION_DAYS=14`,
`WEEKLY_RETENTION_DAYS=56`, `MONTHLY_RETENTION_DAYS=365` in `backup.env`).

Belt-and-suspenders: also set a GCS **Object Lifecycle Management** rule on
the bucket (`daily/` → delete after 14d, `weekly/` → 56d, `monthly/` → 365d,
matched by object name prefix) so retention still happens even if a cron run
silently stops working.

## 6. Notes / open items

- **Backup-only.** Restoring means downloading the `.bacpac` and running
  `sqlpackage /Action:Import` against a target SQL Server — there's no
  scripted path for that here.
- **Password exposure via `ps`**: SqlPackage has no environment-variable
  equivalent to `sqlcmd`'s `SQLCMDPASSWORD`, so `/SourcePassword` is passed
  as a CLI argument to `sqlpackage`, which other local users on the host
  could see via `ps` for the duration of the export. Restrict shell access
  to this host accordingly.
- **`.bacpac` vs `.bak` trade-off** — see section 2. Not a full
  disaster-recovery backup; a schema+data export.
- `--dry-run` skips the actual SqlPackage export and the GCS upload, so it
  only proves the config/lock/logging plumbing and GCP auth work — it does
  not prove `sqlpackage` is installed, or that the `sa` credentials / network
  path to SQL Server are correct. Do one real run before trusting cron with it.

## 7. Files

```
Backupscripting/
├── README.md                    this file
├── config/backup.env.example    dummy config — copy to backup.env, fill in real values
├── lib/common.sh                shared logging / GCS / locking helpers
├── scripts/
│   ├── backup_mssql.sh          sqlpackage export -> GCS (daily/weekly/monthly)
│   └── install_cron.sh          merges cron/crontab.txt into the user's crontab
├── cron/crontab.txt              schedule template (one daily job)
└── logs/                        cron.log + per-script daily logs land here
```
