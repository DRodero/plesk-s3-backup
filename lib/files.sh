#!/usr/bin/env bash
# File backups: one tar.gz per Plesk subscription (/var/www/vhosts/<domain>).
# Uploaded to $S3_FILES_PREFIX/YYYY/MM/DD/<domain>/

FILES_OK=0
FILES_FAILED=0

# Directories in the vhosts root that are not subscriptions
VHOSTS_SYSTEM_DIRS=(system default chroot fs fs-passwd .skel)

list_domains() {
    if [[ $DOMAINS != auto ]]; then
        printf '%s\n' $DOMAINS
    elif command -v plesk > /dev/null; then
        # Each subscription has its own webspace at $VHOSTS_DIR/<name>;
        # add-on domains and subdomains live inside it.
        plesk bin subscription --list 2>> "$LOG_FILE" | grep -E '^[A-Za-z0-9.-]+$'
    else
        local d
        for d in "$VHOSTS_DIR"/*/; do
            d=$(basename "$d")
            in_list "$d" "${VHOSTS_SYSTEM_DIRS[@]}" || echo "$d"
        done
    fi
}

# backup_domain DOMAIN
backup_domain() {
    local domain=$1
    local file="$LOCAL_FILES_DIR/${RUN_STAMP}-files-${domain}.tar.gz"

    if [[ ! -d $VHOSTS_DIR/$domain ]]; then
        log_warn "files $domain: $VHOSTS_DIR/$domain does not exist, skipped"
        return 0
    fi

    local excludes=() pattern
    for pattern in "${TAR_EXCLUDE[@]}"; do
        excludes+=(--exclude="$pattern")
    done

    tar -czf "$file" "${excludes[@]}" -C "$VHOSTS_DIR" "$domain" 2>> "$LOG_FILE"
    local rc=$?

    # GNU tar exits 1 when files changed while being read: the archive is
    # still valid, so it is only a warning.
    if (( rc == 1 )); then
        log_warn "files $domain: some files changed while being archived"
    elif (( rc != 0 )); then
        mv -f "$file" "$file.failed" 2> /dev/null
        log_error "files $domain: tar failed (exit $rc)"
        FILES_FAILED=$((FILES_FAILED + 1))
        return 1
    fi

    log "files $domain: OK $(du -h "$file" | cut -f1)"
    if s3_upload "$file" "$S3_FILES_PREFIX/$RUN_DATE_PATH/$domain/"; then
        FILES_OK=$((FILES_OK + 1))
    else
        FILES_FAILED=$((FILES_FAILED + 1))
    fi
}

# backup_files [DOMAIN...]  (no arguments = every domain)
backup_files() {
    log "== Files backup"
    mkdir -p "$LOCAL_FILES_DIR"

    local domains domain
    if (( $# > 0 )); then
        domains=$(printf '%s\n' "$@")
    elif ! domains=$(list_domains) || [[ -z $domains ]]; then
        log_error "cannot get the list of domains"
        FILES_FAILED=1
        return 1
    fi

    while IFS= read -r domain; do
        [[ -z $domain ]] && continue
        if (( $# == 0 )) && in_list "$domain" "${DOMAINS_EXCLUDE[@]}"; then
            log "files $domain: excluded"
            continue
        fi
        backup_domain "$domain"
    done <<< "$domains"

    report "Files: $FILES_OK OK, $FILES_FAILED failed"
    (( FILES_FAILED == 0 ))
}
