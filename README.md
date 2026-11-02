# plesk-s3-backup

Daily backups of a **Plesk** server to **S3** (or any S3-compatible storage),
with **automatic rotation** of the copies kept in the bucket.

[Leer en español](README.es.md)

- **Databases**: every day, one gzipped `mysqldump` per database (plus an
  optional dump of all databases together). Each dump is checked before it
  is uploaded.
- **Files**: one `tar.gz` per Plesk subscription (`/var/www/vhosts/<domain>`)
  on the days of the week you choose. Domains are **detected automatically**
  from Plesk, so new sites are backed up without editing anything.
- **Rotation in S3**: daily copies for 2 months, then one every 15 days up to
  6 months, one per month up to a year, and one per year after that.
- **Local cleanup** of old local copies and logs.
- **One entry point**, run once a day by a systemd timer, and **one email
  report** per run.

This project is the evolution of
[mysql_backup](https://github.com/DRodero/mysql_backup), which only backed
up the databases. It keeps its dump check and email report, and adds file
backups, S3 rotation and a systemd installer.

## How the rotation works

Every backup run is stored under a date folder:

```
s3://bucket/server/BD/2026/11/02/<database>/<database>_2026-11-02-03.30.00.sql.gz
s3://bucket/server/Files/2026/11/01/<domain>/2026-11-01-03.45.12-files-<domain>.tar.gz
```

Each date folder is a *backup set*. Every day the rotation lists the sets and
decides which to keep based on their age:

| Age              | Kept                                    |
|------------------|-----------------------------------------|
| 0 – 60 days      | every set                               |
| 60 – 180 days    | one per half month (days 1–15 and 16–end) |
| 180 – 365 days   | one per calendar month                  |
| over 365 days    | one per calendar year (forever, or N years) |

In each bucket the **oldest** set is kept. Buckets are nested (half month ⊂
month ⊂ year), so the set that survives at one level is the same one that
survives at the next, and a kept backup is never replaced by a newer one as
time goes by. In steady state that is about 75 database sets and 23 weekly
file sets, plus one per year.

Safety nets:

- The `KEEP_MIN_RECENT` most recent sets (7 by default) are never deleted, so
  if backups stop working the rotation cannot wipe the history.
- The rotation of a type (databases or files) is skipped if that type's
  backup failed today.
- A set is only deleted when an older set of the same bucket exists, so an
  incomplete S3 listing can only make the rotation keep more, never less.
- `ROTATE_DRY_RUN=yes` (the default in the example config) only reports what
  would be deleted.
- Existing backups that already follow the `PREFIX/YYYY/MM/DD/` layout are
  rotated too.

All the thresholds can be changed in the configuration.

## Requirements

- A Linux Plesk server with systemd (Ubuntu, Debian, AlmaLinux, Rocky…), run
  as root.
- `s3cmd` configured with access to your bucket (`s3cmd --configure`).
- `mysql`/`mysqldump`, `tar`, `gzip`, `flock` (all present on Plesk servers).
- `sendmail` (Postfix/qmail from Plesk) or `mail` for the email report.

## Installation

```bash
# 1. Get the code
git clone https://github.com/DRodero/plesk-s3-backup.git /opt/plesk-s3-backup

# 2. Install: creates /etc/plesk-s3-backup/backup.conf (chmod 600),
#    the data directories and the systemd service and timer
/opt/plesk-s3-backup/install.sh

# 3. Configure
nano /etc/plesk-s3-backup/backup.conf

# 4. Check configuration, MySQL, S3 access and detected domains
plesk-s3-backup check

# 5. First run by hand, following the log
systemctl start plesk-s3-backup.service
journalctl -u plesk-s3-backup -f

# 6. Enable the daily run (03:30 by default)
systemctl enable --now plesk-s3-backup.timer
systemctl list-timers plesk-s3-backup.timer
```

Where things live:

| Path | What |
|------|------|
| `/opt/plesk-s3-backup` | the code (a git checkout) |
| `/usr/local/sbin/plesk-s3-backup` | link to `backup.sh` |
| `/etc/plesk-s3-backup/backup.conf` | configuration (root only) |
| `/var/backups/plesk-s3-backup/` | local copies (kept `LOCAL_KEEP_DAYS` days) |
| `/var/log/plesk-s3-backup/` | one log per run (kept `LOG_KEEP_DAYS` days) |
| `/var/lib/plesk-s3-backup/` | lock and queue of uploads to retry |

To change the time: `systemctl edit plesk-s3-backup.timer` and add

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 02:00:00
```

### Upgrading

```bash
git -C /opt/plesk-s3-backup pull
/opt/plesk-s3-backup/install.sh
```

The configuration is never overwritten. Compare it with
`backup.conf.example` to see new options.

### Without systemd (cron)

```bash
echo '30 3 * * * root /opt/plesk-s3-backup/backup.sh run > /dev/null 2>&1' > /etc/cron.d/plesk-s3-backup
```

### Uninstalling

```bash
/opt/plesk-s3-backup/install.sh --uninstall
```

The configuration, logs and local copies are kept; remove them by hand if you
want to.

## Usage

```
plesk-s3-backup [--config FILE] [--dry-run] COMMAND

  run                 daily entry point (what the timer runs)
  db                  back up the databases now
  files [DOMAIN...]   back up the files now (all domains or the given ones)
  cleanup             remove old local copies and logs
  rotate [db|files]   apply the retention policy in S3
  list [db|files]     show which backups are kept or would be deleted, and why
  check               check configuration, dependencies, MySQL and S3
```

`run` does, in this order: retry uploads that failed on previous days,
databases, files (only on `FILES_WEEKDAYS`), local cleanup, rotation of
databases and files, email report. The exit code is non-zero if anything
failed, so `systemctl status plesk-s3-backup` shows failed runs too.

## Configuration

See [`backup.conf.example`](backup.conf.example); every option is commented.
The most important ones:

| Option | Default | |
|--------|---------|---|
| `S3_DB_PREFIX`, `S3_FILES_PREFIX` | — | where the backups go |
| `MYSQL_DEFAULTS_FILE` | empty | MySQL `[client]` file; empty = Plesk admin account |
| `FILES_WEEKDAYS` | `7` | days for the files backup (1=Monday … 7=Sunday) |
| `DOMAINS` | `auto` | `auto` = every Plesk subscription, or a list |
| `DOMAINS_EXCLUDE` | `()` | subscriptions to skip |
| `KEEP_*` | 60 / 180 / 365 / forever | rotation thresholds |
| `ROTATE_DRY_RUN` | `yes` | set to `no` once you trust the plan |

## Restoring

```bash
# List what is available
s3cmd ls s3://bucket/server/BD/2026/11/02/

# A database
s3cmd get s3://bucket/server/BD/2026/11/02/mydb/mydb_2026-11-02-03.30.00.sql.gz
gunzip < mydb_2026-11-02-03.30.00.sql.gz | MYSQL_PWD=$(cat /etc/psa/.psa.shadow) mysql -uadmin mydb

# The files of a domain (extract somewhere else first and copy what you need)
s3cmd get s3://bucket/server/Files/2026/11/01/example.com/2026-11-01-03.45.12-files-example.com.tar.gz
mkdir /root/restore && tar -xzf 2026-11-01-*-files-example.com.tar.gz -C /root/restore
```

## Security notes

- Backups are uploaded **private**. Never use `s3cmd put -P`: file backups
  contain `wp-config.php`, `.env` files and other credentials. To make
  previously uploaded objects private:
  `s3cmd setacl --acl-private --recursive s3://bucket/prefix/`
- Use an S3 key that can only access the backup bucket.
- Consider enabling versioning or object lock on the bucket if you need
  protection against a compromised server deleting its own backups.

## Tests

```bash
bash tests/test_retention.sh
```

The tests check the date arithmetic, fixed retention cases, and simulate
2.5 years of daily and weekly backups to verify the result and that the
rotation is stable.

## License

[MIT](LICENSE)
