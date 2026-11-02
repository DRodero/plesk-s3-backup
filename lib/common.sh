#!/usr/bin/env bash
# Shared helpers: logging, locking, mail, S3 access and the upload retry queue.

ERRORS=()
WARNINGS=()
REPORT=()

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    if [[ -n ${LOG_FILE:-} ]]; then echo "$msg" >> "$LOG_FILE"; fi
}

log_error() {
    ERRORS+=("$*")
    log "ERROR: $*"
}

log_warn() {
    WARNINGS+=("$*")
    log "WARNING: $*"
}

# Adds a line to the summary sent by email at the end of the run.
report() {
    REPORT+=("$*")
    log "$*"
}

die() {
    log "FATAL: $*"
    exit 1
}

# in_list WORD LIST... -> true if WORD is one of LIST
in_list() {
    local word=$1 item
    shift
    for item in "$@"; do
        [[ $item == "$word" ]] && return 0
    done
    return 1
}

acquire_lock() {
    exec 9> "$STATE_DIR/backup.lock"
    flock -n 9 || die "another run is already in progress"
}

# ---------------------------------------------------------------------------
# Mail

send_mail() {
    local subject=$1 body=$2
    [[ -z ${MAIL_TO:-} ]] && return 0

    if [[ -x $SENDMAIL ]]; then
        {
            printf 'To: %s\n' "$MAIL_TO"
            if [[ -n ${MAIL_FROM:-} ]]; then printf 'From: %s\n' "$MAIL_FROM"; fi
            printf 'Subject: %s\n' "$subject"
            printf 'MIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n'
            printf '%s\n' "$body"
        } | "$SENDMAIL" -t
    elif command -v mail > /dev/null; then
        mail -s "$subject" "$MAIL_TO" <<< "$body"
    else
        log_warn "no sendmail or mail command found, report not sent"
    fi
}

# ---------------------------------------------------------------------------
# S3

s3() {
    if [[ -n ${S3CMD_CONFIG:-} ]]; then
        s3cmd -c "$S3CMD_CONFIG" "${S3CMD_OPTS[@]}" "$@"
    else
        s3cmd "${S3CMD_OPTS[@]}" "$@"
    fi
}

# s3_upload LOCAL_FILE S3_DIR/
#   On failure the file is queued and retried on the next run; queued files
#   are never removed by the local cleanup.
s3_upload() {
    local file=$1 dest=$2
    if s3 put --no-progress "$file" "$dest" >> "$LOG_FILE" 2>&1; then
        return 0
    fi
    log_error "upload failed: $file -> $dest (queued for retry)"
    pending_add "$file" "$dest"
    return 1
}

# s3_list_dirs PREFIX -> prints the names of the "directories" under PREFIX
s3_list_dirs() {
    local out
    out=$(s3 ls "$1/" 2>> "$LOG_FILE") || return 1
    awk '$1 == "DIR" { print $2 }' <<< "$out" | sed -E 's#/$##; s#.*/##'
}

# s3_list_dates PREFIX -> prints every PREFIX/YYYY/MM/DD found, as YYYY-MM-DD
s3_list_dates() {
    local prefix=$1 years months days y m d
    years=$(s3_list_dirs "$prefix") || return 1
    for y in $years; do
        [[ $y =~ ^[0-9]{4}$ ]] || continue
        months=$(s3_list_dirs "$prefix/$y") || return 1
        for m in $months; do
            [[ $m =~ ^[0-9]{2}$ ]] || continue
            days=$(s3_list_dirs "$prefix/$y/$m") || return 1
            for d in $days; do
                is_valid_date "$y-$m-$d" && echo "$y-$m-$d"
            done
        done
    done
}

# ---------------------------------------------------------------------------
# Upload retry queue: one "local_file<TAB>s3_dir" per line

pending_file() { echo "$STATE_DIR/pending_uploads"; }

pending_add() {
    printf '%s\t%s\n' "$1" "$2" >> "$(pending_file)"
}

is_pending() {
    local f
    f=$(pending_file)
    [[ -s $f ]] && cut -f1 "$f" | grep -Fxq -- "$1"
}

pending_retry() {
    local f file dest remaining=() line
    f=$(pending_file)
    [[ -s $f ]] || return 0

    log "Retrying uploads that failed in previous runs"
    while IFS=$'\t' read -r file dest; do
        [[ -z $file ]] && continue
        if [[ ! -f $file ]]; then
            log_warn "queued upload no longer exists locally: $file"
        elif s3 put --no-progress "$file" "$dest" >> "$LOG_FILE" 2>&1; then
            report "Uploaded on retry: $file"
        else
            log_error "upload failed again: $file -> $dest"
            remaining+=("$file"$'\t'"$dest")
        fi
    done < "$f"

    : > "$f"
    for line in "${remaining[@]+"${remaining[@]}"}"; do
        echo "$line" >> "$f"
    done
}
