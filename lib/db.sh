#!/usr/bin/env bash
# Database backups: one gzipped dump per database, plus an optional
# --all-databases dump. Uploaded to $S3_DB_PREFIX/YYYY/MM/DD/<database>/

DB_OK=0
DB_FAILED=0
DB_RESULTS=()     # "name|status|bytes|seconds" per database (status: ok, failed)
MYSQL_AUTH=()

# Credentials: an explicit defaults file, or the Plesk admin password.
mysql_setup_auth() {
    if [[ -n ${MYSQL_DEFAULTS_FILE:-} ]]; then
        [[ -r $MYSQL_DEFAULTS_FILE ]] || { log_error "cannot read MYSQL_DEFAULTS_FILE $MYSQL_DEFAULTS_FILE"; return 1; }
        MYSQL_AUTH=(--defaults-extra-file="$MYSQL_DEFAULTS_FILE")
    elif [[ -r /etc/psa/.psa.shadow ]]; then
        MYSQL_AUTH=(-uadmin)
        MYSQL_PWD=$(< /etc/psa/.psa.shadow)
        export MYSQL_PWD
    else
        log_error "no MySQL credentials: set MYSQL_DEFAULTS_FILE (or run on a Plesk server as root)"
        return 1
    fi
}

mysql_list_databases() {
    mysql "${MYSQL_AUTH[@]}" -N -B -e 'SHOW DATABASES' 2>> "$LOG_FILE"
}

# dump_database NAME MYSQLDUMP_ARGS...
dump_database() {
    local name=$1
    shift
    local dir="$LOCAL_DB_DIR/$name"
    local file="$dir/${name}_${RUN_STAMP}.sql.gz"
    local start=$SECONDS
    mkdir -p "$dir"

    mysqldump "${MYSQL_AUTH[@]}" "${MYSQLDUMP_OPTS[@]}" "$@" 2>> "$LOG_FILE" | gzip > "$file"
    local rc=("${PIPESTATUS[@]}")

    # mysqldump writes "-- Dump completed" as the last line of a full dump
    if (( rc[0] != 0 || rc[1] != 0 )) || ! gzip -cd "$file" | tail -n1 | grep -q 'Dump completed'; then
        mv -f "$file" "$file.failed"
        log_error "DB $name: dump failed (mysqldump exit ${rc[0]}, gzip exit ${rc[1]})"
        DB_FAILED=$((DB_FAILED + 1))
        DB_RESULTS+=("$name|failed|0|$((SECONDS - start))")
        return 1
    fi

    local bytes
    bytes=$(file_size "$file")
    log "DB $name: OK $(human_size "$bytes")"
    if s3_upload "$file" "$S3_DB_PREFIX/$RUN_DATE_PATH/$name/"; then
        DB_OK=$((DB_OK + 1))
        DB_RESULTS+=("$name|ok|$bytes|$((SECONDS - start))")
    else
        DB_FAILED=$((DB_FAILED + 1))
        DB_RESULTS+=("$name|failed|$bytes|$((SECONDS - start))")
    fi
}

backup_databases() {
    log "== Database backup"
    mysql_setup_auth || { DB_FAILED=1; return 1; }

    local dbs db
    if ! dbs=$(mysql_list_databases); then
        log_error "cannot list databases"
        DB_FAILED=1
        return 1
    fi

    while IFS= read -r db; do
        [[ -z $db ]] && continue
        in_list "$db" "${DB_EXCLUDE[@]}" && continue
        dump_database "$db" "$db"
    done <<< "$dbs"

    if [[ $DB_ALL_DATABASES == yes ]]; then
        dump_database "_all_databases" --all-databases
    fi

    report "Databases: $DB_OK OK, $DB_FAILED failed"
    (( DB_FAILED == 0 ))
}
