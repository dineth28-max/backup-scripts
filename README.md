# Antlerfoundry SQL Server (dev) — Database Backup

Backup tooling for the Antlerfoundry SQL Server 2019 database running in its
own Docker container. Runs from cron on the host that container runs on,
ships everything to Google Cloud Storage. No app/infra changes required —
this only reads from the running container via `docker exec`.

**Backup-only** — there is intentionally no restore script in this repo.

There is no "Vertical Platform" / Postgres system here — that was a different,
now-removed project. Everything in this repo backs up exactly one thing: the
Antlerfoundry SQL Server database below.

## 1. What's being backed up

One database, named by `MSSQL_DATABASE` in `config/backup.env`, inside the
`ms-sql-server-dev-antlerhrmdfc` container (image
`mcr.microsoft.com/mssql/server:2019-latest`, port 1433 in the container
mapped to `13727` on the host).

## Is this actually working correctly? (status as of last review)

- **Backup logic**: `BACKUP DATABASE` → `docker cp` → `gzip` → sha256 sidecar
  → upload to GCS with daily/weekly/monthly tiering — verified by reading the
  script end-to-end, internally consistent.
- **Not yet proven by an actual run**: nobody has executed
  `backup_mssql.sh` against the real `ms-sql-server-dev-antlerhrmdfc`
  container yet. Until that happens, "the script is correct on paper" and
  "the script actually backs up this database" are not the same claim.
- **Before trusting it**: fill in `MSSQL_DATABASE`, create the secret files
  (section 3), then run `./scripts/backup_mssql.sh` for real once and confirm
  the `.bak.gz` + `.sha256` land in `gs://db_backups_antler/mssql-dev/daily/`.
  That's the only way to turn "should work" into "does work."

## 2. Strategy

```
SQL Server (in container)
   │  BACKUP DATABASE ... TO DISK (via sqlcmd)
   ▼
 docker cp
   │
   ▼
 gzip
   │
   ▼
 Upload
   │
   ▼
   GCS
```

One cron job, once a day: `BACKUP DATABASE` inside the container, copy the
`.bak` out, `gzip` it, upload to GCS. The same day's dump is also copied into
a `weekly/` folder on Sundays and a `monthly/` folder on the 1st of the
month, giving three retention tiers from one backup run (grandfather-father-
son rotation) — no extra load on SQL Server to produce the weekly/monthly
copies.

| Tier    | Taken            | Kept for  |
|---------|-------------------|-----------|
| Daily   | every day         | 14 days   |
| Weekly  | every Sunday      | 8 weeks   |
| Monthly | 1st of the month  | 12 months |

This is intentionally simple: a full native backup every run, no log
shipping / point-in-time recovery. Revisit with transaction-log backups if
RPO requirements tighten.

## 3. Setup

```bash
cd Backupscripting
cp config/backup.env.example config/backup.env
# edit config/backup.env: real GCP_PROJECT_ID, GCS_BUCKET, MSSQL_DATABASE, paths for your host

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
  daily/2026-09-25_020000/<database>_2026-09-25_020000.bak.gz(.sha256)
  weekly/2026-09-20_020000/...   (same file, copied on Sundays)
  monthly/2026-09-01_020000/...  (same file, copied on the 1st)
```

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

- **Backup-only.** Restoring means downloading the `.bak.gz`, gunzipping it,
  copying it into a target SQL Server container, and running
  `RESTORE DATABASE ... FROM DISK` by hand — there's no scripted path for
  that here.
- `sqlcmd` path is assumed to be `/opt/mssql-tools/bin/sqlcmd`, which is what
  the `2019-latest` image ships at — verify this once with
  `docker exec <container> ls /opt/mssql-tools/bin/` if the image ever
  changes.
- `--dry-run` skips the actual `BACKUP DATABASE` and the GCS upload, so it
  only proves the config/lock/logging plumbing works — it does not prove the
  container name, `sa` credentials, or GCS access are correct. Do one real
  run before trusting cron with it.

## 7. Files

```
Backupscripting/
├── README.md                    this file
├── config/backup.env.example    dummy config — copy to backup.env, fill in real values
├── lib/common.sh                shared logging / GCS / locking helpers
├── scripts/
│   ├── backup_mssql.sh          BACKUP DATABASE -> gzip -> GCS (daily/weekly/monthly)
│   └── install_cron.sh          merges cron/crontab.txt into the user's crontab
├── cron/crontab.txt              schedule template (one daily job)
└── logs/                        cron.log + per-script daily logs land here
```
