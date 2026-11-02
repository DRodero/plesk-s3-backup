#!/usr/bin/env bash
# Local cleanup: old local copies, old logs and any extra paths configured.

# clean_dir DIR DAYS -> removes regular files older than DAYS days.
# Files waiting to be re-uploaded are never removed.
clean_dir() {
    local dir=${1%/} days=$2 f count=0
    if [[ -z $dir || $dir == / ]]; then
        log_error "cleanup: refusing to clean '$1'"
        return 1
    fi
    [[ -d $dir ]] || return 0

    while IFS= read -r -d '' f; do
        is_pending "$f" && continue
        rm -f -- "$f" && count=$((count + 1))
    done < <(find "$dir" -type f ! -name '*.sh' -mtime +"$days" -print0)

    # Remove directories left empty (per-database folders)
    find "$dir" -mindepth 1 -type d -empty -delete 2> /dev/null

    log "cleanup $dir: $count file(s) older than $days days removed"
}

cleanup_local() {
    log "== Local cleanup"
    clean_dir "$LOCAL_DB_DIR" "$LOCAL_KEEP_DAYS"
    clean_dir "$LOCAL_FILES_DIR" "$LOCAL_KEEP_DAYS"
    clean_dir "$LOG_DIR" "$LOG_KEEP_DAYS"

    local entry
    for entry in "${EXTRA_CLEANUP[@]}"; do
        clean_dir "${entry%:*}" "${entry##*:}"
    done
}
