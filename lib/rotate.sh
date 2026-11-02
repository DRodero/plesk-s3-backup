#!/usr/bin/env bash
# S3 rotation: applies the retention policy (lib/retention.sh) to the
# backup sets stored under PREFIX/YYYY/MM/DD/.
#
# Note on safety: a set is deleted only when an older set of the same bucket
# is also listed (or it is beyond KEEP_YEARLY_YEARS). An incomplete listing
# can therefore only make the rotation keep more, never delete more.

# Per type, for the report:
# "label|dry_run|deleted|failed|daily|biweekly|monthly|yearly|recent|oldest|newest"
ROTATION_STATS=()

# rotation_plan PREFIX -> prints the retention plan for PREFIX
rotation_plan() {
    local dates
    dates=$(s3_list_dates "$1") || return 1
    [[ -z $dates ]] && return 0
    retention_plan "$RUN_DATE" <<< "$dates"
}

# rotate LABEL PREFIX DRY_RUN(yes|no)
rotate() {
    local label=$1 prefix=$2 dry_run=$3
    local note=""
    [[ $dry_run == yes ]] && note=" [dry run]"
    log "== S3 rotation: $label ($prefix)$note"

    local plan
    if ! plan=$(rotation_plan "$prefix"); then
        log_error "rotation $label: cannot list $prefix"
        return 1
    fi
    if [[ -z $plan ]]; then
        report "Rotation $label: no backups found"
        return 0
    fi

    local date action reason kept=0 deleted=0 failed=0
    while read -r date action reason; do
        if [[ $action == keep ]]; then
            kept=$((kept + 1))
            continue
        fi
        if [[ $dry_run == yes ]]; then
            log "rotation $label: would delete $date ($reason)"
            deleted=$((deleted + 1))
        elif s3 del --recursive "$prefix/${date//-//}/" >> "$LOG_FILE" 2>&1; then
            log "rotation $label: deleted $date ($reason)"
            deleted=$((deleted + 1))
        else
            log_error "rotation $label: could not delete $date"
            failed=$((failed + 1))
        fi
    done <<< "$plan"

    local keep_lines count reasons=() r
    keep_lines=$(grep ' keep ' <<< "$plan")
    for r in daily biweekly monthly yearly recent; do
        count=$(grep -c " keep $r\$" <<< "$keep_lines")
        reasons+=("$count")
    done
    ROTATION_STATS+=("$label|$dry_run|$deleted|$failed|$(IFS='|'; echo "${reasons[*]}")|$(head -n1 <<< "$keep_lines" | cut -d' ' -f1)|$(tail -n1 <<< "$keep_lines" | cut -d' ' -f1)")

    if [[ $dry_run == yes ]]; then
        report "Rotation $label [DRY RUN]: $kept kept, $deleted would be deleted"
    else
        report "Rotation $label: $kept kept, $deleted deleted, $failed failed"
    fi
    (( failed == 0 ))
}

# print_plan LABEL PREFIX -> human readable plan (for `backup.sh list`)
print_plan() {
    local label=$1 prefix=$2 plan
    echo "== $label ($prefix)"
    if ! plan=$(rotation_plan "$prefix"); then
        echo "cannot list $prefix"
        return 1
    fi
    if [[ -z $plan ]]; then
        echo "no backups found"
        return 0
    fi
    printf '%-12s %-7s %s\n' DATE ACTION REASON
    awk '{ printf "%-12s %-7s %s\n", $1, $2, $3 }' <<< "$plan"
    echo "total: $(wc -l <<< "$plan" | tr -d ' '), to delete: $(grep -c ' delete ' <<< "$plan")"
}
