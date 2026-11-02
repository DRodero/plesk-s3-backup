#!/usr/bin/env bash
# Email report sent at the end of `run`: an HTML dashboard, a plain text
# version for clients without HTML, and the full log attached.

# Filled by report_collect
R_STATUS=OK
R_DURATION=0
R_DB_BYTES=0
R_FILES_BYTES=0
R_S3_DB_BYTES=""
R_S3_FILES_BYTES=""
R_NEXT_FILES_DAY=""
R_LAST_FILES_SET=""
R_PROTECTED_DOMAINS=""
R_DETECTED_DOMAINS=""

html_escape() {
    local s=$1
    s=${s//&/"&amp;"}
    s=${s//</"&lt;"}
    s=${s//>/"&gt;"}
    printf '%s' "$s"
}

# s3_usage PREFIX -> bytes stored under PREFIX (empty if unknown)
s3_usage() {
    s3 du "$1/" 2>> "$LOG_FILE" | awk '$1 ~ /^[0-9]+$/ { print $1; exit }'
}

# next_files_day -> e.g. "Sun 8 Nov" (next day in FILES_WEEKDAYS after today)
next_files_day() {
    local today_n i n u
    days_from_civil "${RUN_DATE:0:4}" "${RUN_DATE:5:2}" "${RUN_DATE:8:2}"
    today_n=$REPLY
    for (( i = 1; i <= 7; i++ )); do
        n=$(( today_n + i ))
        u=$(( (n + 3) % 7 + 1 ))   # 1970-01-01 was a Thursday (4)
        if in_list "$u" $FILES_WEEKDAYS; then
            civil_from_days "$n"
            local names=(Mon Tue Wed Thu Fri Sat Sun)
            local months=(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
            echo "${names[u - 1]} $((10#${REPLY:8:2})) ${months[10#${REPLY:5:2} - 1]}"
            return
        fi
    done
}

# rotation_stat LABEL -> the ROTATION_STATS entry for LABEL
rotation_stat() {
    local entry
    for entry in "${ROTATION_STATS[@]}"; do
        [[ ${entry%%|*} == "$1" ]] && { echo "$entry"; return 0; }
    done
    return 1
}

report_collect() {
    local files_ran=$1 entry name status bytes secs

    R_STATUS=OK
    (( ${#WARNINGS[@]} > 0 )) && R_STATUS=WARNING
    (( ${#ERRORS[@]} > 0 )) && R_STATUS=ERROR
    R_DURATION=$(( $(date +%s) - RUN_START ))

    for entry in "${DB_RESULTS[@]}"; do
        IFS='|' read -r name status bytes secs <<< "$entry"
        R_DB_BYTES=$(( R_DB_BYTES + bytes ))
    done
    for entry in "${FILES_RESULTS[@]}"; do
        IFS='|' read -r name status bytes secs <<< "$entry"
        R_FILES_BYTES=$(( R_FILES_BYTES + bytes ))
    done

    if [[ $REPORT_S3_USAGE == yes ]]; then
        R_S3_DB_BYTES=$(s3_usage "$S3_DB_PREFIX")
        R_S3_FILES_BYTES=$(s3_usage "$S3_FILES_PREFIX")
    fi

    R_NEXT_FILES_DAY=$(next_files_day)

    # Domains protected by the most recent files backup in S3
    if [[ $files_ran != yes ]]; then
        R_DETECTED_DOMAINS=$(list_domains 2> /dev/null)
        local stat
        if stat=$(rotation_stat files); then
            R_LAST_FILES_SET=$(cut -d'|' -f11 <<< "$stat")
        fi
        if [[ -n $R_LAST_FILES_SET ]]; then
            R_PROTECTED_DOMAINS=$(s3_list_dirs "$S3_FILES_PREFIX/${R_LAST_FILES_SET//-//}")
        fi
    fi
}

# ---------------------------------------------------------------------------
# Plain text version

report_text() {
    local files_ran=$1 line entry name status bytes secs

    echo "Backup report: $HOST"
    echo "Status:    $R_STATUS"
    echo "Date:      $RUN_STAMP"
    echo "Duration:  $(human_duration "$R_DURATION")"
    echo
    echo "Databases: $DB_OK OK, $DB_FAILED failed ($(human_size "$R_DB_BYTES"))"
    if [[ $files_ran == yes ]]; then
        echo "Files:     $FILES_OK OK, $FILES_FAILED failed ($(human_size "$R_FILES_BYTES"))"
    else
        echo "Files:     not scheduled today, next on $R_NEXT_FILES_DAY"
    fi
    if [[ -n $R_S3_DB_BYTES$R_S3_FILES_BYTES ]]; then
        echo "In S3:     databases $(human_size "${R_S3_DB_BYTES:-0}"), files $(human_size "${R_S3_FILES_BYTES:-0}")"
    fi

    if (( ${#ERRORS[@]} > 0 )); then
        echo; echo "Errors:"
        for line in "${ERRORS[@]}"; do echo "  - $line"; done
    fi
    if (( ${#WARNINGS[@]} > 0 )); then
        echo; echo "Warnings:"
        for line in "${WARNINGS[@]}"; do echo "  - $line"; done
    fi

    echo; echo "Summary:"
    for line in "${REPORT[@]}"; do echo "  $line"; done

    if (( ${#DB_RESULTS[@]} > 0 )); then
        echo; echo "Databases:"
        for entry in "${DB_RESULTS[@]}"; do
            IFS='|' read -r name status bytes secs <<< "$entry"
            printf '  %-40s %10s  %s\n' "$name" "$(human_size "$bytes")" "$status"
        done
    fi
    if (( ${#FILES_RESULTS[@]} > 0 )); then
        echo; echo "Domains:"
        for entry in "${FILES_RESULTS[@]}"; do
            IFS='|' read -r name status bytes secs <<< "$entry"
            printf '  %-40s %10s  %s\n' "$name" "$(human_size "$bytes")" "$status"
        done
    fi

    echo
    echo "Full log attached ($(basename "$LOG_FILE"))."
    echo "plesk-s3-backup $VERSION"
}

# ---------------------------------------------------------------------------
# HTML dashboard (table layout and inline styles: what email clients support)

C_TEXT="#1f2937"; C_MUTED="#6b7280"; C_BORDER="#e5e7eb"; C_BG="#f3f4f6"
C_OK="#15803d"; C_OK_BG="#dcfce7"
C_WARN="#a16207"; C_WARN_BG="#fef9c3"
C_ERR="#b91c1c"; C_ERR_BG="#fee2e2"
C_INFO="#1d4ed8"; C_INFO_BG="#dbeafe"

# badge TEXT KIND(ok|warning|error|info|muted)
badge() {
    local fg=$C_MUTED bg=$C_BG
    case $2 in
        ok) fg=$C_OK; bg=$C_OK_BG ;;
        warning) fg=$C_WARN; bg=$C_WARN_BG ;;
        error | failed) fg=$C_ERR; bg=$C_ERR_BG ;;
        info) fg=$C_INFO; bg=$C_INFO_BG ;;
    esac
    printf '<span style="display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px;font-weight:600;color:%s;background:%s;">%s</span>' \
        "$fg" "$bg" "$(html_escape "$1")"
}

# tile VALUE LABEL SUBLABEL
tile() {
    printf '<td width="50%%" style="padding:6px;" valign="top"><div style="border:1px solid %s;border-radius:10px;padding:14px 16px;">' "$C_BORDER"
    printf '<div style="font-size:26px;font-weight:700;color:%s;line-height:1.2;">%s</div>' "$C_TEXT" "$1"
    printf '<div style="font-size:13px;font-weight:600;color:%s;margin-top:2px;">%s</div>' "$C_TEXT" "$(html_escape "$2")"
    printf '<div style="font-size:12px;color:%s;margin-top:2px;">%s</div></div></td>\n' "$C_MUTED" "$3"
}

# section_title TEXT [EXTRA_HTML]
section_title() {
    printf '<tr><td style="padding:22px 24px 8px;"><div style="font-size:15px;font-weight:700;color:%s;">%s %s</div></td></tr>\n' \
        "$C_TEXT" "$(html_escape "$1")" "${2:-}"
}

TH="padding:6px 8px;border-bottom:2px solid $C_BORDER;font-size:12px;font-weight:600;color:$C_MUTED;text-align:left;"
TD="padding:6px 8px;border-bottom:1px solid $C_BORDER;font-size:13px;color:$C_TEXT;"

# results_table KIND(db|files) ENTRIES...   (failed rows first)
results_table() {
    local kind=$1 entry name status bytes secs pass label
    shift
    [[ $kind == db ]] && label=Database || label=Domain
    printf '<tr><td style="padding:0 24px;"><table width="100%%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">\n'
    printf '<tr><th style="%s">%s</th><th style="%s;text-align:right;">Size</th><th style="%s;text-align:right;">Time</th><th style="%s;text-align:right;">Status</th></tr>\n' \
        "$TH" "$label" "$TH" "$TH" "$TH"
    for pass in failed other; do
        for entry in "$@"; do
            IFS='|' read -r name status bytes secs <<< "$entry"
            if [[ $pass == failed && $status != failed ]] || [[ $pass == other && $status == failed ]]; then
                continue
            fi
            printf '<tr><td style="%s">%s</td><td style="%s;text-align:right;white-space:nowrap;">%s</td><td style="%s;text-align:right;white-space:nowrap;color:%s;">%s</td><td style="%s;text-align:right;">%s</td></tr>\n' \
                "$TD" "$(html_escape "$name")" "$TD" "$(human_size "$bytes")" \
                "$TD" "$C_MUTED" "$(human_duration "$secs")" "$TD" "$(badge "$status" "$status")"
        done
    done
    printf '</table></td></tr>\n'
}

# retention_value LABEL FIELD -> one field of the ROTATION_STATS entry, or "-"
retention_value() {
    local stat
    stat=$(rotation_stat "$1") || { echo "-"; return; }
    cut -d'|' -f"$2" <<< "$stat"
}

# Rows are the retention tiers, columns the backup types: narrow enough for phones
retention_table() {
    local db_kept=- files_kept=- label stat
    for label in databases files; do
        if stat=$(rotation_stat "$label"); then
            IFS='|' read -r _ _ _ _ daily biweekly monthly yearly recent _ <<< "$stat"
            local kept=$(( daily + biweekly + monthly + yearly + recent ))
            if [[ $label == databases ]]; then db_kept=$kept; else files_kept=$kept; fi
        fi
    done

    local deleted_label="Deleted today"
    [[ $ROTATE_DRY_RUN == yes ]] && deleted_label="Would be deleted"
    local yearly_label="Yearly"
    [[ $KEEP_YEARLY_YEARS == 0 ]] && yearly_label="Yearly (forever)" || yearly_label="Yearly (${KEEP_YEARLY_YEARS} years)"

    printf '<tr><td style="padding:0 24px;"><table width="100%%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">\n'
    printf '<tr><th style="%s">Copies kept</th><th style="%stext-align:right;">Databases</th><th style="%stext-align:right;">Files</th></tr>\n' "$TH" "$TH" "$TH"

    # retention_row LABEL HINT DB_VALUE FILES_VALUE [bold]
    retention_row() {
        local weight=400
        [[ ${5:-} == bold ]] && weight=700
        printf '<tr><td style="%sfont-weight:%s;">%s <span style="color:%s;font-size:12px;font-weight:400;">%s</span></td>' "$TD" "$weight" "$1" "$C_MUTED" "$2"
        printf '<td style="%stext-align:right;white-space:nowrap;font-weight:%s;">%s</td><td style="%stext-align:right;white-space:nowrap;font-weight:%s;">%s</td></tr>\n' \
            "$TD" "$weight" "$3" "$TD" "$weight" "$4"
    }
    retention_row "Daily" "&le;&nbsp;${KEEP_DAILY_UNTIL}&nbsp;d" "$(retention_value databases 5)" "$(retention_value files 5)"
    retention_row "Every 15 days" "&le;&nbsp;${KEEP_BIWEEKLY_UNTIL}&nbsp;d" "$(retention_value databases 6)" "$(retention_value files 6)"
    retention_row "Monthly" "&le;&nbsp;${KEEP_MONTHLY_UNTIL}&nbsp;d" "$(retention_value databases 7)" "$(retention_value files 7)"
    retention_row "$yearly_label" "" "$(retention_value databases 8)" "$(retention_value files 8)"
    if [[ $(retention_value databases 9) != [0-] || $(retention_value files 9) != [0-] ]]; then
        retention_row "Safety net" "most recent" "$(retention_value databases 9)" "$(retention_value files 9)"
    fi
    retention_row "Total" "" "$db_kept" "$files_kept" bold
    retention_row "$deleted_label" "" "$(retention_value databases 3)" "$(retention_value files 3)"
    retention_row "Oldest copy" "" "$(retention_value databases 10)" "$(retention_value files 10)"
    printf '</table>\n'

    local notes=()
    rotation_stat databases > /dev/null || notes+=("Database rotation was skipped today.")
    rotation_stat files > /dev/null || notes+=("Files rotation was skipped today.")
    [[ $ROTATE_DRY_RUN == yes ]] && notes+=("Dry run is on: nothing is deleted until ROTATE_DRY_RUN=no.")
    if (( ${#notes[@]} > 0 )); then
        printf '<div style="font-size:12px;color:%s;padding-top:8px;">%s</div>' "$C_MUTED" "${notes[*]}"
    fi
    printf '</td></tr>\n'
}

protected_domains_table() {
    local domain
    printf '<tr><td style="padding:0 24px;"><table width="100%%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">\n'
    printf '<tr><th style="%s">Domain</th><th style="%s;text-align:right;">Status</th></tr>\n' "$TH" "$TH"
    while IFS= read -r domain; do
        [[ -z $domain ]] && continue
        if in_list "$domain" "${DOMAINS_EXCLUDE[@]}"; then
            printf '<tr><td style="%s;color:%s;">%s</td><td style="%s;text-align:right;">%s</td></tr>\n' \
                "$TD" "$C_MUTED" "$(html_escape "$domain")" "$TD" "$(badge excluded muted)"
        elif grep -Fxq -- "$domain" <<< "$R_PROTECTED_DOMAINS"; then
            printf '<tr><td style="%s">%s</td><td style="%s;text-align:right;">%s</td></tr>\n' \
                "$TD" "$(html_escape "$domain")" "$TD" "$(badge protected ok)"
        else
            printf '<tr><td style="%s">%s</td><td style="%s;text-align:right;">%s</td></tr>\n' \
                "$TD" "$(html_escape "$domain")" "$TD" "$(badge "not in last backup" warning)"
        fi
    done <<< "$R_DETECTED_DOMAINS"
    printf '</table></td></tr>\n'
}

report_html() {
    local files_ran=$1 line kind
    case $R_STATUS in OK) kind=ok ;; WARNING) kind=warning ;; *) kind=error ;; esac

    cat << EOF
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light"><title>Backup report</title></head>
<body style="margin:0;padding:0;background:$C_BG;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:$C_TEXT;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:$C_BG;"><tr><td align="center" style="padding:24px 12px;">
<table width="100%" cellpadding="0" cellspacing="0" style="max-width:680px;background:#ffffff;border:1px solid $C_BORDER;border-radius:12px;">
<tr><td style="padding:22px 24px 4px;">
<table width="100%" cellpadding="0" cellspacing="0"><tr>
<td><div style="font-size:12px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:$C_MUTED;">Backup report</div>
<div style="font-size:20px;font-weight:700;color:$C_TEXT;margin-top:2px;">$(html_escape "$HOST")</div></td>
<td align="right" valign="top">$(badge "$R_STATUS" "$kind")</td>
</tr></table>
<div style="font-size:13px;color:$C_MUTED;margin-top:6px;">$RUN_DATE $(tr . : <<< "${RUN_STAMP:11:5}") &middot; took $(human_duration "$R_DURATION")</div>
</td></tr>
EOF

    # KPI tiles (2 x 2, readable on phones too)
    printf '<tr><td style="padding:12px 18px 0;"><table width="100%%" cellpadding="0" cellspacing="0"><tr>\n'
    local db_total=$(( DB_OK + DB_FAILED ))
    tile "$DB_OK<span style=\"font-size:16px;color:$C_MUTED;\"> / $db_total</span>" "Databases backed up" "$(human_size "$R_DB_BYTES") compressed"
    if [[ $files_ran == yes ]]; then
        tile "$FILES_OK<span style=\"font-size:16px;color:$C_MUTED;\"> / $(( FILES_OK + FILES_FAILED ))</span>" "Domains backed up" "$(human_size "$R_FILES_BYTES") compressed"
    else
        local protected=0 domain
        while IFS= read -r domain; do
            [[ -n $domain ]] && grep -Fxq -- "$domain" <<< "$R_PROTECTED_DOMAINS" && protected=$((protected + 1))
        done <<< "$R_DETECTED_DOMAINS"
        tile "$protected" "Domains protected" "last files backup ${R_LAST_FILES_SET:-none}, next ${R_NEXT_FILES_DAY}"
    fi
    printf '</tr><tr>\n'
    tile "$(human_duration "$R_DURATION")" "Total time" "started $(html_escape "${RUN_STAMP:11:5}" | tr . :)"
    if [[ -n $R_S3_DB_BYTES$R_S3_FILES_BYTES ]]; then
        tile "$(human_size $(( ${R_S3_DB_BYTES:-0} + ${R_S3_FILES_BYTES:-0} )))" "Stored in S3" \
            "databases $(human_size "${R_S3_DB_BYTES:-0}") &middot; files $(human_size "${R_S3_FILES_BYTES:-0}")"
    else
        tile "${#ERRORS[@]}" "Errors" "${#WARNINGS[@]} warning(s)"
    fi
    printf '</tr></table></td></tr>\n'

    # Errors and warnings
    if (( ${#ERRORS[@]} + ${#WARNINGS[@]} > 0 )); then
        printf '<tr><td style="padding:16px 24px 0;">'
        if (( ${#ERRORS[@]} > 0 )); then
            printf '<div style="background:%s;border-radius:10px;padding:12px 16px;margin-bottom:8px;"><div style="font-weight:700;color:%s;font-size:14px;">Errors</div><ul style="margin:6px 0 0;padding-left:18px;color:%s;font-size:13px;">' "$C_ERR_BG" "$C_ERR" "$C_ERR"
            for line in "${ERRORS[@]}"; do printf '<li>%s</li>' "$(html_escape "$line")"; done
            printf '</ul></div>'
        fi
        if (( ${#WARNINGS[@]} > 0 )); then
            printf '<div style="background:%s;border-radius:10px;padding:12px 16px;"><div style="font-weight:700;color:%s;font-size:14px;">Warnings</div><ul style="margin:6px 0 0;padding-left:18px;color:%s;font-size:13px;">' "$C_WARN_BG" "$C_WARN" "$C_WARN"
            for line in "${WARNINGS[@]}"; do printf '<li>%s</li>' "$(html_escape "$line")"; done
            printf '</ul></div>'
        fi
        printf '</td></tr>\n'
    fi

    section_title "Retention in S3" "$([[ $ROTATE_DRY_RUN == yes ]] && badge "dry run" info)"
    retention_table

    if (( ${#DB_RESULTS[@]} > 0 )); then
        section_title "Databases (${#DB_RESULTS[@]})"
        results_table db "${DB_RESULTS[@]}"
    fi

    if (( ${#FILES_RESULTS[@]} > 0 )); then
        section_title "Domains (${#FILES_RESULTS[@]})"
        results_table files "${FILES_RESULTS[@]}"
    elif [[ -n $R_DETECTED_DOMAINS ]]; then
        section_title "Domains" "<span style=\"font-weight:400;font-size:12px;color:$C_MUTED;\">last files backup ${R_LAST_FILES_SET:-none} &middot; next ${R_NEXT_FILES_DAY}</span>"
        protected_domains_table
    fi

    cat << EOF
<tr><td style="padding:22px 24px;font-size:12px;color:$C_MUTED;border-top:1px solid $C_BORDER;">
Full log attached ($(html_escape "$(basename "$LOG_FILE")")) &middot; also on the server at $(html_escape "$LOG_FILE")<br>
<a href="https://github.com/DRodero/plesk-s3-backup" style="color:$C_MUTED;">plesk-s3-backup</a> $VERSION
</td></tr>
</table></td></tr></table>
</body></html>
EOF
}

# ---------------------------------------------------------------------------

send_report() {
    local files_ran=$1
    report_collect "$files_ran"
    [[ $R_STATUS == OK && $MAIL_ON_SUCCESS != yes ]] && return 0

    local subject="[backup] $R_STATUS $HOST $RUN_DATE" text html="" attachment=""
    text=$(report_text "$files_ran")
    [[ $MAIL_FORMAT == html ]] && html=$(report_html "$files_ran")
    [[ $MAIL_ATTACH_LOG == yes ]] && attachment=$LOG_FILE

    log "Sending report to $MAIL_TO"
    send_mail "$subject" "$text" "$html" "$attachment"
}
