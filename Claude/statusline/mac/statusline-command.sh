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

# 리셋까지 남은 시간을 "1d 11h 35m" 형태로 (0인 상위 단위는 생략: "11h 35m", "35m")
fmt_remaining() {
    _r=$(( $1 - NOW )); [ "$_r" -lt 0 ] && _r=0
    _d=$(( _r / 86400 )); _h=$(( (_r % 86400) / 3600 )); _m=$(( (_r % 3600) / 60 ))
    if [ "$_d" -gt 0 ]; then printf '%dd %dh %dm' "$_d" "$_h" "$_m"
    elif [ "$_h" -gt 0 ]; then printf '%dh %dm' "$_h" "$_m"
    else printf '%dm' "$_m"; fi
}

FIVE_H_TXT=""
if [ -n "$FIVE_H" ]; then
    FIVE_H_TXT="5h: $(printf '%.0f' "$FIVE_H")%"
    [ -n "$FIVE_H_RESET" ] && FIVE_H_TXT="$FIVE_H_TXT ($(fmt_remaining "$FIVE_H_RESET"))"
fi

WEEK_TXT=""
if [ -n "$WEEK" ]; then
    WEEK_TXT="7d: $(printf '%.0f' "$WEEK")%"
    [ -n "$WEEK_RESET" ] && WEEK_TXT="$WEEK_TXT ($(fmt_remaining "$WEEK_RESET"))"
fi

# 한도 정보가 없으면 구분자까지 통째로 생략합니다
LIMITS_SEG=""
[ -n "$FIVE_H_TXT" ] && LIMITS_SEG="$LIMITS_SEG | $FIVE_H_TXT"
[ -n "$WEEK_TXT" ] && LIMITS_SEG="$LIMITS_SEG | $WEEK_TXT"

# effort_level이 없으면 세그먼트를 구분자까지 통째로 생략합니다
EFFORT_SEG=""
[ -n "$EFFORT" ] && EFFORT_SEG=" $EFFORT |"

# thinking.enabled가 true이면 세그먼트를 추가합니다
THINKING_SEG=""
[ "$THINKING" = "true" ] && THINKING_SEG=" Thinking |"

if [ -n "$BRANCH" ]; then
    echo "${CYAN}[$MODEL]${RESET} |${EFFORT_SEG}${THINKING_SEG} 📁 ${DIR##*/} | 🌿 $BRANCH +$STAGED ~$MODIFIED${LIMITS_SEG}"
else
    echo "${CYAN}[$MODEL]${RESET} |${EFFORT_SEG}${THINKING_SEG} 📁 ${DIR##*/}${LIMITS_SEG}"
fi


# 세션 시작 시각 = transcript 파일 생성 시각. 세션 내내 불변이므로 한 번만 구해 캐시합니다
START_CACHE="/tmp/statusline-session-start-$SESSION_ID"
if [ -f "$START_CACHE" ]; then
    SESSION_START=$(cat "$START_CACHE")
else
    TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // empty')
    # transcript_path가 입력에 없으면 session_id로 프로젝트 디렉터리에서 찾습니다
    if [ ! -f "$TRANSCRIPT" ]; then
        for _f in "$HOME"/.claude/projects/*/"$SESSION_ID".jsonl; do
            [ -f "$_f" ] && TRANSCRIPT="$_f" && break
        done
    fi
    SESSION_START=""
    if [ -f "$TRANSCRIPT" ]; then
        # stat -f %B는 macOS(생성 시각), stat -c %W는 Linux(미지원이면 0 → mtime으로 대체)
        SESSION_START=$(stat -f %B "$TRANSCRIPT" 2>/dev/null || stat -c %W "$TRANSCRIPT" 2>/dev/null)
        [ "$SESSION_START" = "0" ] && SESSION_START=$(stat -c %Y "$TRANSCRIPT" 2>/dev/null)
    fi
    case "$SESSION_START" in ''|*[!0-9]*) SESSION_START="" ;; esac
    if [ -n "$SESSION_START" ]; then
        echo "$SESSION_START" > "$START_CACHE"
    else
        # transcript를 아직 못 찾은 경우. 캐시하지 않고 다음 호출에서 다시 시도합니다
        SESSION_START=$NOW
    fi
fi

# date -r은 macOS/BSD, date -d @는 GNU
fmt_epoch() {
    date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2" 2>/dev/null
}

# 오늘 시작한 세션이면 시:분만, 날짜가 넘어갔으면 월/일까지 표시합니다
if [ "$(fmt_epoch "$SESSION_START" %F)" = "$(date +%F)" ]; then
    START_FMT=$(fmt_epoch "$SESSION_START" '%H:%M')
else
    START_FMT=$(fmt_epoch "$SESSION_START" '%m/%d %H:%M')
fi

COST_FMT=$(printf '$%.2f' "$COST")
echo "${BAR_COLOR}${BAR}${RESET} ${PCT}% | ${YELLOW}${COST_FMT}${RESET} | ⏱️ ${DURATION_FMT} | 🕒 ${START_FMT} | Session: $SESSION_ID"
