#!/usr/bin/env bash
# Retention engine: decides which backup sets (one per date) to keep.
#
# Pure functions only (no S3, no filesystem), so they can be unit tested.
# Written to run on bash 3.2+ so the tests also run on macOS.
#
# Policy, by age of the backup set (in days, counted from "today"):
#   age <= KEEP_DAILY_UNTIL           keep every set
#   age <= KEEP_BIWEEKLY_UNTIL        keep one per half month (days 1-15, 16-end)
#   age <= KEEP_MONTHLY_UNTIL         keep one per calendar month
#   older                             keep one per calendar year
#                                     (for KEEP_YEARLY_YEARS years; 0 = forever)
#
# Inside each bucket the OLDEST set is kept. Buckets are nested
# (half month ⊂ month ⊂ year), so the set kept at one level is the same one
# that survives at the next level, and a set that has been kept is never
# swapped for a newer one as time goes by.
#
# Additionally, the KEEP_MIN_RECENT most recent sets are always kept, so that
# if backups stop working the rotation can never wipe the history.

: "${KEEP_DAILY_UNTIL:=60}"
: "${KEEP_BIWEEKLY_UNTIL:=180}"
: "${KEEP_MONTHLY_UNTIL:=365}"
: "${KEEP_YEARLY_YEARS:=0}"
: "${KEEP_MIN_RECENT:=7}"

# days_from_civil Y M D -> sets REPLY to days since 1970-01-01.
# (Howard Hinnant's algorithm; avoids GNU/BSD `date` differences and forks.)
days_from_civil() {
    local y=$((10#$1)) m=$((10#$2)) d=$((10#$3))
    (( m <= 2 )) && y=$((y - 1))
    local era=$(( (y >= 0 ? y : y - 399) / 400 ))
    local yoe=$(( y - era * 400 ))
    local mp=$(( (m + 9) % 12 ))
    local doy=$(( (153 * mp + 2) / 5 + d - 1 ))
    local doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
    REPLY=$(( era * 146097 + doe - 719468 ))
}

# civil_from_days N -> sets REPLY to YYYY-MM-DD.
civil_from_days() {
    local z=$(( $1 + 719468 ))
    local era=$(( (z >= 0 ? z : z - 146096) / 146097 ))
    local doe=$(( z - era * 146097 ))
    local yoe=$(( (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 ))
    local y=$(( yoe + era * 400 ))
    local doy=$(( doe - (365 * yoe + yoe / 4 - yoe / 100) ))
    local mp=$(( (5 * doy + 2) / 153 ))
    local d=$(( doy - (153 * mp + 2) / 5 + 1 ))
    local m=$(( mp < 10 ? mp + 3 : mp - 9 ))
    (( m <= 2 )) && y=$((y + 1))
    printf -v REPLY '%04d-%02d-%02d' "$y" "$m" "$d"
}

# is_valid_date YYYY-MM-DD
is_valid_date() {
    [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    days_from_civil "${1:0:4}" "${1:5:2}" "${1:8:2}"
    local n=$REPLY
    civil_from_days "$n"
    [[ $REPLY == "$1" ]]
}

# retention_plan TODAY
#   Reads backup set dates (YYYY-MM-DD, one per line, any order) from stdin.
#   Prints one line per date, oldest first:  "<date> keep|delete <reason>"
#   Reasons: recent, daily, biweekly, monthly, yearly, superseded, expired, future
retention_plan() {
    local today=$1
    days_from_civil "${today:0:4}" "${today:5:2}" "${today:8:2}"
    local today_n=$REPLY

    local dates=() line
    while IFS= read -r line; do
        [[ -n $line ]] && dates+=("$line")
    done
    (( ${#dates[@]} == 0 )) && return 0

    # Oldest first, without duplicates.
    local sorted=()
    while IFS= read -r line; do
        sorted+=("$line")
    done < <(printf '%s\n' "${dates[@]}" | sort -u)

    local total=${#sorted[@]}
    local recent_from=$(( total - KEEP_MIN_RECENT ))
    local yearly_until=$(( KEEP_MONTHLY_UNTIL + KEEP_YEARLY_YEARS * 365 ))
    local seen=" " i date age day key tier action

    for (( i = 0; i < total; i++ )); do
        date=${sorted[$i]}
        days_from_civil "${date:0:4}" "${date:5:2}" "${date:8:2}"
        age=$(( today_n - REPLY ))
        day=$((10#${date:8:2}))

        if (( age < 0 )); then
            tier=future; key=""
        elif (( age <= KEEP_DAILY_UNTIL )); then
            tier=daily; key=""
        elif (( age <= KEEP_BIWEEKLY_UNTIL )); then
            tier=biweekly; key="b:${date:0:7}:$(( day <= 15 ? 1 : 2 ))"
        elif (( age <= KEEP_MONTHLY_UNTIL )); then
            tier=monthly; key="m:${date:0:7}"
        elif (( KEEP_YEARLY_YEARS == 0 || age <= yearly_until )); then
            tier=yearly; key="y:${date:0:4}"
        else
            tier=expired; key=""
        fi

        if [[ $tier == future || $tier == daily ]]; then
            action="keep $tier"
        elif [[ $tier == expired ]]; then
            action="delete expired"
        elif [[ $seen == *" $key "* ]]; then
            action="delete superseded"
        else
            seen="$seen$key "
            action="keep $tier"
        fi

        # Safety net: never delete the most recent sets.
        if (( i >= recent_from )) && [[ $action == delete* ]]; then
            action="keep recent"
        fi

        echo "$date $action"
    done
}
