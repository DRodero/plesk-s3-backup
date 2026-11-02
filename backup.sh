#!/usr/bin/env bash
# plesk-s3-backup: database and file backups of a Plesk server to S3,
# with automatic rotation (daily / biweekly / monthly / yearly).
#
# https://github.com/DRodero/plesk-s3-backup
# Run `backup.sh help` for usage.

set -o pipefail

VERSION="1.1.0"

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2> /dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)

# shellcheck source=lib/retention.sh
source "$SCRIPT_DIR/lib/retention.sh"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/db.sh
source "$SCRIPT_DIR/lib/db.sh"
# shellcheck source=lib/files.sh
source "$SCRIPT_DIR/lib/files.sh"
# shellcheck source=lib/cleanup.sh
source "$SCRIPT_DIR/lib/cleanup.sh"
# shellcheck source=lib/rotate.sh
source "$SCRIPT_DIR/lib/rotate.sh"
# shellcheck source=lib/report.sh
source "$SCRIPT_DIR/lib/report.sh"

usage() {
    cat << EOF
plesk-s3-backup $VERSION

Usage: backup.sh [--config FILE] [--dry-run] COMMAND [ARGS]

Commands:
  run                 Daily entry point (cron / systemd timer):
                        databases every day, files on FILES_WEEKDAYS,
                        local cleanup, S3 rotation and email report
  db                  Back up the databases now
  files [DOMAIN...]   Back up the files now (all domains, or the given ones)
  cleanup             Remove old local copies and logs
  rotate [db|files]   Apply the retention policy in S3 (both by default)
  list [db|files]     Show which S3 backups are kept or would be deleted
  check               Check configuration, dependencies, MySQL and S3 access
  version             Show the version

Options:
  --config FILE       Configuration file (default: /etc/plesk-s3-backup/backup.conf)
  --dry-run           Rotation only reports what it would delete
EOF
}

# ---------------------------------------------------------------------------
# Configuration

load_config() {
    local file=$1
    if [[ -z $file ]]; then
        for file in "${PLESK_S3_BACKUP_CONF:-}" /etc/plesk-s3-backup/backup.conf "$SCRIPT_DIR/backup.conf"; do
            [[ -n $file && -f $file ]] && break
        done
    fi
    [[ -f $file ]] || { echo "Configuration file not found. See backup.conf.example" >&2; exit 1; }
    # shellcheck source=backup.conf.example
    source "$file"
    CONFIG_FILE=$file

    : "${S3_DB_PREFIX:?S3_DB_PREFIX is not set in $file}"
    : "${S3_FILES_PREFIX:?S3_FILES_PREFIX is not set in $file}"
    S3_DB_PREFIX=${S3_DB_PREFIX%/}
    S3_FILES_PREFIX=${S3_FILES_PREFIX%/}

    : "${LOCAL_DB_DIR:=/var/backups/plesk-s3-backup/db}"
    : "${LOCAL_FILES_DIR:=/var/backups/plesk-s3-backup/files}"
    : "${LOCAL_KEEP_DAYS:=2}"
    : "${LOG_DIR:=/var/log/plesk-s3-backup}"
    : "${LOG_KEEP_DAYS:=30}"
    : "${STATE_DIR:=/var/lib/plesk-s3-backup}"
    : "${MAIL_TO:=}"
    : "${MAIL_FROM:=}"
    : "${MAIL_ON_SUCCESS:=yes}"
    : "${SENDMAIL:=/usr/sbin/sendmail}"
    : "${MAIL_FORMAT:=html}"
    : "${MAIL_ATTACH_LOG:=yes}"
    : "${REPORT_S3_USAGE:=yes}"
    : "${S3CMD_CONFIG:=}"
    : "${MYSQL_DEFAULTS_FILE:=}"
    : "${DB_ALL_DATABASES:=yes}"
    : "${FILES_WEEKDAYS:=7}"
    : "${DOMAINS:=auto}"
    : "${VHOSTS_DIR:=/var/www/vhosts}"
    : "${ROTATE_DRY_RUN:=no}"

    declare -p S3CMD_OPTS &> /dev/null || S3CMD_OPTS=()
    declare -p DB_EXCLUDE &> /dev/null || DB_EXCLUDE=(information_schema performance_schema mysql sys)
    declare -p MYSQLDUMP_OPTS &> /dev/null || MYSQLDUMP_OPTS=(--single-transaction --quick --routines --events --triggers)
    declare -p DOMAINS_EXCLUDE &> /dev/null || DOMAINS_EXCLUDE=()
    declare -p TAR_EXCLUDE &> /dev/null || TAR_EXCLUDE=()
    declare -p EXTRA_CLEANUP &> /dev/null || EXTRA_CLEANUP=()
}

init_run() {
    local command=$1
    RUN_START=$(date +%s)
    RUN_DATE=$(date +%F)
    RUN_DATE_PATH=${RUN_DATE//-//}
    RUN_STAMP=$(date +%Y-%m-%d-%H.%M.%S)
    HOST=$(hostname -f 2> /dev/null || hostname)

    mkdir -p "$LOG_DIR" "$STATE_DIR" "$LOCAL_DB_DIR" "$LOCAL_FILES_DIR" || exit 1
    chmod 700 "$STATE_DIR" "$LOCAL_DB_DIR" "$LOCAL_FILES_DIR" 2> /dev/null
    LOG_FILE="$LOG_DIR/$RUN_STAMP-$command.log"
    ( umask 077 && touch "$LOG_FILE" )

    acquire_lock
    log "plesk-s3-backup $VERSION on $HOST: $command (config: $CONFIG_FILE)"
}

require_commands() {
    local cmd missing=()
    for cmd in "$@"; do
        command -v "$cmd" > /dev/null || missing+=("$cmd")
    done
    (( ${#missing[@]} == 0 )) || die "missing commands: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# Commands

is_files_day() {
    local today
    today=$(date +%u)
    in_list "$today" $FILES_WEEKDAYS
}

cmd_run() {
    require_commands s3cmd mysql mysqldump tar gzip flock
    pending_retry

    local db_ok=yes files_ok=yes files_ran=no
    backup_databases || db_ok=no

    if is_files_day; then
        files_ran=yes
        backup_files || files_ok=no
    else
        log "== Files backup: not today (FILES_WEEKDAYS=$FILES_WEEKDAYS)"
    fi

    cleanup_local

    # Never rotate a type whose backup failed today
    if [[ $db_ok == yes ]]; then
        rotate databases "$S3_DB_PREFIX" "$ROTATE_DRY_RUN"
    else
        log_warn "rotation of databases skipped because today's backup had errors"
    fi
    if [[ $files_ok == yes ]]; then
        rotate files "$S3_FILES_PREFIX" "$ROTATE_DRY_RUN"
    else
        log_warn "rotation of files skipped because today's backup had errors"
    fi

    send_report "$files_ran"
}

cmd_rotate() {
    require_commands s3cmd
    local what=${1:-all}
    case $what in
        db) rotate databases "$S3_DB_PREFIX" "$ROTATE_DRY_RUN" ;;
        files) rotate files "$S3_FILES_PREFIX" "$ROTATE_DRY_RUN" ;;
        all)
            rotate databases "$S3_DB_PREFIX" "$ROTATE_DRY_RUN"
            rotate files "$S3_FILES_PREFIX" "$ROTATE_DRY_RUN"
            ;;
        *) die "rotate: unknown type '$what' (db or files)" ;;
    esac
}

cmd_list() {
    require_commands s3cmd
    local what=${1:-all}
    case $what in
        db) print_plan databases "$S3_DB_PREFIX" ;;
        files) print_plan files "$S3_FILES_PREFIX" ;;
        all)
            print_plan databases "$S3_DB_PREFIX"
            echo
            print_plan files "$S3_FILES_PREFIX"
            ;;
        *) die "list: unknown type '$what' (db or files)" ;;
    esac
}

cmd_check() {
    local ok=yes cmd

    check() {
        if [[ $1 == ok ]]; then echo "  [OK]   $2"; else echo "  [FAIL] $2"; ok=no; fi
    }

    echo "Configuration: $CONFIG_FILE"
    local perms
    perms=$(stat -c %a "$CONFIG_FILE" 2> /dev/null || stat -f %Lp "$CONFIG_FILE")
    if [[ $perms == 600 || $perms == 400 ]]; then
        check ok "configuration file permissions ($perms)"
    else
        echo "  [WARN] configuration file permissions are $perms, 600 recommended"
    fi

    echo "Commands:"
    for cmd in s3cmd mysql mysqldump tar gzip flock; do
        command -v "$cmd" > /dev/null && check ok "$cmd" || check fail "$cmd not found"
    done
    if [[ -x $SENDMAIL ]] || command -v mail > /dev/null; then
        check ok "mail delivery (sendmail/mail)"
    else
        check fail "no sendmail or mail command: reports cannot be sent"
    fi

    echo "MySQL:"
    local dbs db n=0
    if mysql_setup_auth && dbs=$(mysql_list_databases); then
        while IFS= read -r db; do
            [[ -n $db ]] && ! in_list "$db" "${DB_EXCLUDE[@]}" && n=$((n + 1))
        done <<< "$dbs"
        check ok "connection ($n databases to back up)"
    else
        check fail "cannot connect to MySQL (see $LOG_FILE)"
    fi

    echo "S3:"
    local prefix
    for prefix in "$S3_DB_PREFIX" "$S3_FILES_PREFIX"; do
        if s3 ls "$prefix/" > /dev/null 2>> "$LOG_FILE"; then
            check ok "access to $prefix"
        else
            check fail "cannot access $prefix (see $LOG_FILE)"
        fi
    done

    echo "Domains (files backup on weekday(s) $FILES_WEEKDAYS, 1=Monday):"
    local domains domain
    if domains=$(list_domains) && [[ -n $domains ]]; then
        while IFS= read -r domain; do
            if in_list "$domain" "${DOMAINS_EXCLUDE[@]}"; then
                echo "         $domain (excluded)"
            else
                echo "         $domain"
            fi
        done <<< "$domains"
    else
        check fail "cannot get the list of domains"
    fi

    echo "Rotation: daily up to $KEEP_DAILY_UNTIL days, biweekly up to $KEEP_BIWEEKLY_UNTIL," \
        "monthly up to $KEEP_MONTHLY_UNTIL, then yearly" \
        "($([[ $KEEP_YEARLY_YEARS == 0 ]] && echo forever || echo "$KEEP_YEARLY_YEARS years"))," \
        "dry run: $ROTATE_DRY_RUN"

    [[ $ok == yes ]]
}

# ---------------------------------------------------------------------------
# Main

main() {
    local config="" dry_run=no
    while (( $# > 0 )); do
        case $1 in
            --config) config=$2; shift 2 ;;
            --config=*) config=${1#*=}; shift ;;
            --dry-run) dry_run=yes; shift ;;
            -h | --help | help) usage; exit 0 ;;
            -V | --version | version) echo "plesk-s3-backup $VERSION"; exit 0 ;;
            -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
            *) break ;;
        esac
    done

    local command=${1:-}
    [[ -z $command ]] && { usage >&2; exit 2; }
    shift

    case $command in
        run | db | files | cleanup | rotate | list | check) ;;
        *) echo "Unknown command: $command" >&2; usage >&2; exit 2 ;;
    esac

    load_config "$config"
    [[ $dry_run == yes ]] && ROTATE_DRY_RUN=yes
    init_run "$command"

    case $command in
        run) cmd_run ;;
        db) require_commands s3cmd mysql mysqldump gzip; backup_databases ;;
        files) require_commands s3cmd tar gzip; backup_files "$@" ;;
        cleanup) cleanup_local ;;
        rotate) cmd_rotate "$@" ;;
        list) cmd_list "$@" ;;
        check) cmd_check ;;
    esac
    local rc=$?

    (( ${#ERRORS[@]} > 0 )) && rc=1
    log "Finished with ${#ERRORS[@]} error(s) and ${#WARNINGS[@]} warning(s)"
    exit "$rc"
}

main "$@"
