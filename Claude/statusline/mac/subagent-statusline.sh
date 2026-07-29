#!/bin/sh
# Claude Code statusLine — plain colored text, pipe-separated.
#

input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name')
# 실제 JSON은 effort.level (중첩). 구버전 호환으로 effort_level도 함께 봅니다
EFFORT=$(echo "$input" | jq -r '.effort.level // .effort_level // empty')
# "// empty"는 rate_limits이 없을 때 출력을 생성하지 않습니다
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVE_H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
WEEK_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

# resets_at은 Unix epoch(초). 숫자가 아니면 잔여 시간 표시를 생략합니다
case "$FIVE_H_RESET" in ''|*[!0-9]*) FIVE_H_RESET="" ;; esac
case "$WEEK_RESET" in ''|*[!0-9]*) WEEK_RESET="" ;; esac
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
SESSION_ID=$(echo "$input" | jq -r '.session_id')
THINKING=$(echo "$input" | jq -r '.thinking.enabled // false')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

# 컨텍스트 사용량에 따라 막대 색상 선택
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((PCT / 10)); EMPTY=$((10 - FILLED))
printf -v FILL "%${FILLED}s"; printf -v PAD "%${EMPTY}s"
BAR="${FILL// /█}${PAD// /░}"

# 총 소요 시간을 "3h 34m 20s" 형태로 (1시간 미만이면 "34m 20s")
TOTAL_SECS=$((DURATION_MS / 1000))
HRS=$((TOTAL_SECS / 3600)); MINS=$(((TOTAL_SECS % 3600) / 60)); SECS=$((TOTAL_SECS % 60))
if [ "$HRS" -gt 0 ]; then
    DURATION_FMT="${HRS}h ${MINS}m ${SECS}s"
else
    DURATION_FMT="${MINS}m ${SECS}s"
fi

BRANCH=""
git rev-parse --git-dir > /dev/null 2>&1 && BRANCH=" | 🌿 $(git branch --show-current 2>/dev/null)"

CACHE_FILE="/tmp/statusline-git-cache-$SESSION_ID"
CACHE_MAX_AGE=5  # seconds
LIMITS=""

cache_is_stale() {
    [ ! -f "$CACHE_FILE" ] || \
    # stat -f %m은 macOS, stat -c %Y는 Linux
    [ $(($(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0))) -gt $CACHE_MAX_AGE ]
}

if cache_is_stale; then
    if git rev-parse --git-dir > /dev/null 2>&1; then
        BRANCH=$(git branch --show-current 2>/dev/null)
        STAGED=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
        MODIFIED=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
        echo "$BRANCH|$STAGED|$MODIFIED" > "$CACHE_FILE"
    else
        echo "||" > "$CACHE_FILE"
    fi
fi

IFS='|' read -r BRANCH STAGED MODIFIED < "$CACHE_FILE"

NOW=$(date +%s)

# 리셋까지 남은 시간을 "1h20m" 형태로 (5시간 한도용, 1시간 미만이면 "20m")
fmt_remaining_hm() {
    _r=$(( $1 - NOW )); [ "$_r" -lt 0 ] && _r=0
    _h=$(( _r / 3600 )); _m=$(( (_r % 3600) / 60 ))
    if [ "$_h" -gt 0 ]; then printf '%dh%dm' "$_h" "$_m"; else printf '%dm' "$_m"; fi
}

# 리셋까지 남은 시간을 "1d4h" 형태로 (7일 한도용, 1일 미만이면 "4h")
fmt_remaining_dh() {
    _r=$(( $1 - NOW )); [ "$_r" -lt 0 ] && _r=0
    _d=$(( _r / 86400 )); _h=$(( (_r % 86400) / 3600 ))
    if [ "$_d" -gt 0 ]; then printf '%dd%dh' "$_d" "$_h"; else printf '%dh' "$_h"; fi
}

FIVE_H_TXT=""
if [ -n "$FIVE_H" ]; then
    FIVE_H_TXT="5h: $(printf '%.0f' "$FIVE_H")%"
    [ -n "$FIVE_H_RESET" ] && FIVE_H_TXT="$FIVE_H_TXT ($(fmt_remaining_hm "$FIVE_H_RESET"))"
fi

WEEK_TXT=""
if [ -n "$WEEK" ]; then
    WEEK_TXT="7d: $(printf '%.0f' "$WEEK")%"
    [ -n "$WEEK_RESET" ] && WEEK_TXT="$WEEK_TXT ($(fmt_remaining_dh "$WEEK_RESET"))"
fi

LIMITS="$FIVE_H_TXT"
[ -n "$WEEK_TXT" ] && LIMITS="${LIMITS:+$LIMITS, }$WEEK_TXT"

# effort_level이 없으면 세그먼트를 구분자까지 통째로 생략합니다
EFFORT_SEG=""
[ -n "$EFFORT" ] && EFFORT_SEG=" $EFFORT |"

# thinking.enabled가 true이면 세그먼트를 추가합니다
THINKING_SEG=""
[ "$THINKING" = "true" ] && THINKING_SEG=" Thinking |"

if [ -n "$BRANCH" ]; then
    echo "${CYAN}[$MODEL]${RESET} |${EFFORT_SEG}${THINKING_SEG} 📁 ${DIR##*/} | 🌿 $BRANCH +$STAGED ~$MODIFIED | ${LIMITS}"
else
    echo "${CYAN}[$MODEL]${RESET} |${EFFORT_SEG}${THINKING_SEG} 📁 ${DIR##*/} | ${LIMITS}"
fi


COST_FMT=$(printf '$%.2f' "$COST")
echo "${BAR_COLOR}${BAR}${RESET} ${PCT}% | ${YELLOW}${COST_FMT}${RESET} | ⏱️ ${DURATION_FMT} | Session: $SESSION_ID"
