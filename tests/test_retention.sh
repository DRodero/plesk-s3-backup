#!/usr/bin/env bash
# Tests for lib/retention.sh. Run: bash tests/test_retention.sh
set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/retention.sh
source "$TEST_DIR/../lib/retention.sh"

FAILED=0
PASSED=0

assert_eq() {
    local expected=$1 actual=$2 msg=$3
    if [[ "$expected" == "$actual" ]]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$msg" "$expected" "$actual"
    fi
}

# Action for one date in a plan
action_of() { awk -v d="$1" '$1 == d { print $2 " " $3 }' <<< "$2"; }

# ---------------------------------------------------------------------------
echo "== date math"

days_from_civil 1970 01 01; assert_eq 0 "$REPLY" "epoch"
days_from_civil 2000 03 01; assert_eq 11017 "$REPLY" "2000-03-01"
days_from_civil 2026 11 02; assert_eq 20759 "$REPLY" "2026-11-02"

bad=0
for (( n = 18000; n < 22000; n++ )); do
    civil_from_days "$n"; d=$REPLY
    days_from_civil "${d:0:4}" "${d:5:2}" "${d:8:2}"
    (( REPLY == n )) || bad=$((bad + 1))
done
assert_eq 0 "$bad" "civil/days round trip"

is_valid_date 2024-02-29 && r=ok || r=bad; assert_eq ok "$r" "leap day is valid"
is_valid_date 2026-02-29 && r=ok || r=bad; assert_eq bad "$r" "non-leap 29 Feb is invalid"
is_valid_date 2026-1-02 && r=ok || r=bad; assert_eq bad "$r" "malformed date is invalid"

# ---------------------------------------------------------------------------
echo "== fixed plan"

KEEP_MIN_RECENT=1
plan=$(retention_plan 2026-11-02 <<'EOF'
2026-11-02
2026-10-01
2026-08-25
2026-08-20
2026-08-01
2026-04-20
2026-04-10
2025-06-01
2025-03-01
2023-12-31
2026-11-05
EOF
)
assert_eq "keep daily"        "$(action_of 2026-11-02 "$plan")" "today"
assert_eq "keep daily"        "$(action_of 2026-10-01 "$plan")" "32 days old"
assert_eq "keep biweekly"     "$(action_of 2026-08-20 "$plan")" "first of 2nd half of August"
assert_eq "delete superseded" "$(action_of 2026-08-25 "$plan")" "later in 2nd half of August"
assert_eq "keep biweekly"     "$(action_of 2026-08-01 "$plan")" "first half of August"
assert_eq "keep monthly"      "$(action_of 2026-04-10 "$plan")" "first of April"
assert_eq "delete superseded" "$(action_of 2026-04-20 "$plan")" "later in April"
assert_eq "keep yearly"       "$(action_of 2025-03-01 "$plan")" "first of 2025"
assert_eq "delete superseded" "$(action_of 2025-06-01 "$plan")" "later in 2025"
assert_eq "keep yearly"       "$(action_of 2023-12-31 "$plan")" "only one of 2023"
assert_eq "keep future"       "$(action_of 2026-11-05 "$plan")" "date in the future"

KEEP_YEARLY_YEARS=1
plan=$(printf '%s\n' 2026-11-02 2025-03-01 2023-12-31 | retention_plan 2026-11-02)
assert_eq "keep yearly"    "$(action_of 2025-03-01 "$plan")" "yearly within limit"
assert_eq "delete expired" "$(action_of 2023-12-31 "$plan")" "yearly beyond limit"
KEEP_YEARLY_YEARS=0

echo "== safety net"
KEEP_MIN_RECENT=3
plan=$(printf '%s\n' 2024-01-01 2024-01-02 2024-01-03 2024-01-04 2024-01-05 | retention_plan 2026-11-02)
assert_eq "keep yearly"       "$(action_of 2024-01-01 "$plan")" "first of 2024"
assert_eq "delete superseded" "$(action_of 2024-01-02 "$plan")" "not among the 3 most recent"
assert_eq "keep recent"       "$(action_of 2024-01-03 "$plan")" "3rd most recent kept"
assert_eq "keep recent"       "$(action_of 2024-01-05 "$plan")" "most recent kept"
KEEP_MIN_RECENT=7

# ---------------------------------------------------------------------------
# simulate START DAYS STEP: runs the rotation once per day for DAYS days,
# adding a backup every STEP days. Leaves the survivors in SURVIVORS and
# the final plan in FINAL_PLAN.
simulate() {
    local start=$1 days=$2 step=$3
    days_from_civil "${start:0:4}" "${start:5:2}" "${start:8:2}"
    local start_n=$REPLY n today
    SURVIVORS=()
    UNSTABLE=0
    for (( n = start_n; n < start_n + days; n++ )); do
        civil_from_days "$n"; today=$REPLY
        (( (n - start_n) % step == 0 )) && SURVIVORS+=("$today")
        FINAL_PLAN=$(printf '%s\n' "${SURVIVORS[@]}" | retention_plan "$today")
        SURVIVORS=()
        while read -r d a _; do
            [[ $a == keep ]] && SURVIVORS+=("$d")
        done <<< "$FINAL_PLAN"
        # Idempotence: rotating the survivors again must delete nothing.
        # (checked every few days to keep the test fast)
        (( (n - start_n) % 5 == 0 )) || continue
        if printf '%s\n' "${SURVIVORS[@]}" | retention_plan "$today" | grep -q ' delete '; then
            UNSTABLE=$((UNSTABLE + 1))
        fi
    done
}

count_reason() { grep -c " keep $1\$" <<< "$FINAL_PLAN"; }

echo "== simulation: daily backups for ~2.5 years (this takes a moment)"
simulate 2024-05-17 900 1
assert_eq 0 "$UNSTABLE" "rotation is idempotent"
assert_eq 61 "$(count_reason daily)" "61 daily sets (0..60 days)"
biweekly=$(count_reason biweekly)
(( biweekly >= 7 && biweekly <= 9 )) && r=ok || r="got $biweekly"
assert_eq ok "$r" "7-9 biweekly sets"
monthly=$(count_reason monthly)
(( monthly >= 5 && monthly <= 7 )) && r=ok || r="got $monthly"
assert_eq ok "$r" "5-7 monthly sets"
assert_eq 2 "$(count_reason yearly)" "one set per year beyond 12 months"
assert_eq 0 "$(count_reason recent)" "safety net not needed when backups run"

# Every kept set must be the oldest backup of its bucket (here backups exist
# every day, so: day 1 or 16 for biweekly, day 1 for monthly, Jan 1 for yearly).
bad=$(awk '$3=="biweekly" && substr($1,9,2)!="01" && substr($1,9,2)!="16"' <<< "$FINAL_PLAN" | wc -l | tr -d ' ')
assert_eq 0 "$bad" "biweekly sets are the 1st or the 16th"
bad=$(awk '$3=="monthly" && substr($1,9,2)!="01"' <<< "$FINAL_PLAN" | wc -l | tr -d ' ')
assert_eq 0 "$bad" "monthly sets are the 1st of the month"
first_yearly=$(awk '$3=="yearly" {print $1; exit}' <<< "$FINAL_PLAN")
assert_eq 2024-05-17 "$first_yearly" "first yearly set is the very first backup of 2024"
second_yearly=$(awk '$3=="yearly" {n++} $3=="yearly" && n==2 {print $1}' <<< "$FINAL_PLAN")
assert_eq 2025-01-01 "$second_yearly" "2025 yearly set is 1 January"

echo "== simulation: weekly backups for ~2.5 years"
simulate 2024-05-19 900 7
assert_eq 0 "$UNSTABLE" "rotation is idempotent"
daily=$(count_reason daily)
(( daily >= 8 && daily <= 9 )) && r=ok || r="got $daily"
assert_eq ok "$r" "8-9 weekly sets in the daily window"
total=${#SURVIVORS[@]}
(( total >= 22 && total <= 27 )) && r=ok || r="got $total"
assert_eq ok "$r" "22-27 sets in total"

# ---------------------------------------------------------------------------
echo
echo "passed: $PASSED  failed: $FAILED"
(( FAILED == 0 ))
