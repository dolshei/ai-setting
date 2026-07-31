#!/bin/sh
# Claude Code statusLine (macOS) — windows/statusline.ps1 과 동일한 형식으로 출력합니다.
#
#   1행: 모델 | effort | 🌿 브랜치 | 🕐 경과시간 | ctx used: n% | ctx left: n% | 작업 디렉터리
#   2행: 5h used: n% | 5h reset: 3h 41m | 7d used: n% | 7d reset: 4d 17h 31m
#
# 필요 명령: jq (필수), git (선택 — 없으면 브랜치 세그먼트만 빠집니다)

input=$(cat)

# 퍼센트 값에는 소수점이 섞여 들어옵니다("30.4"). 소수 구분자가 쉼표인
# 로케일에서도 printf 가 이 값을 그대로 읽도록 숫자 로케일만 고정합니다.
LC_NUMERIC=C
export LC_NUMERIC

# 이스케이프 문자와 아이콘은 이 파일이 어떤 인코딩으로 저장/전송되든 동일하게
# 나오도록 리터럴 대신 8진 이스케이프로 만듭니다 (파일 자체는 ASCII 전용).
ESC=$(printf '\033')
RESET="${ESC}[0m"
CLOCK=$(printf '\360\237\225\220')       # U+1F550 CLOCK FACE ONE OCLOCK
BRANCH_ICON=$(printf '\360\237\214\277') # U+1F33F HERB (git branch)

# 필요한 필드를 jq 한 번으로 뽑아 셸 변수로 만듭니다. @sh 가 값을 안전하게
# 따옴표 처리하므로 공백이나 특수문자가 든 경로도 그대로 살아남습니다.
FIELDS=$(printf '%s' "$input" | jq -r '
  def s: if . == null then "" else tostring end;
  @sh "MODEL_NAME=\(.model.display_name | s)",
  @sh "MODEL_ID=\(.model.id | s)",
  @sh "EFFORT=\(.effort.level // .effort_level | s)",
  @sh "THINKING=\(if (.thinking.enabled // false) then "1" else "" end)",
  @sh "CWD=\(.cwd // .workspace.current_dir | s)",
  @sh "TRANSCRIPT=\(.transcript_path | s)",
  @sh "CTX_USED=\(.context_window.used_percentage | s)",
  @sh "CTX_LEFT=\(.context_window.remaining_percentage | s)",
  @sh "FIVE_USED=\(.rate_limits.five_hour.used_percentage | s)",
  @sh "FIVE_RESET=\(.rate_limits.five_hour.resets_at | s)",
  @sh "SEVEN_USED=\(.rate_limits.seven_day.used_percentage | s)",
  @sh "SEVEN_RESET=\(.rate_limits.seven_day.resets_at | s)"
' 2>/dev/null)
eval "$FIELDS"

is_num()  { case "$1" in ''|*[!0-9.]*) return 1 ;; *) return 0 ;; esac; }
is_int()  { case "$1" in ''|*[!0-9]*)  return 1 ;; *) return 0 ;; esac; }
lower()   { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# 경과/잔여 시간을 "35m" / "1h 30m" / "1d 2h 32m" 형태로 만듭니다.
# 앞자리가 0인 단위는 생략하되, 더 큰 단위가 이미 표시됐다면 0도 남겨서
# ("1d 0h 5m") 값이 모호하게 읽히지 않도록 합니다.
fmt_duration() {
    _secs=$1
    [ "$_secs" -lt 0 ] && _secs=0
    _tm=$(( _secs / 60 ))
    _d=$(( _tm / 1440 ))
    _h=$(( (_tm % 1440) / 60 ))
    _m=$(( _tm % 60 ))
    _out=""
    [ "$_d" -gt 0 ] && _out="${_d}d "
    if [ "$_d" -gt 0 ] || [ "$_h" -gt 0 ]; then _out="${_out}${_h}h "; fi
    printf '%s%dm' "$_out" "$_m"
}

# 화면에 찍히는 모든 퍼센트가 이 하나의 심각도 램프를 공유합니다. 임계값은
# 반올림된 값에 적용하므로 색과 숫자가 항상 일치합니다(89.6 → 90%, 빨강).
usage_color() {
    if   [ "$1" -ge 90 ]; then printf '38;5;196'   # red
    elif [ "$1" -ge 80 ]; then printf '38;5;208'   # orange
    elif [ "$1" -ge 60 ]; then printf '38;5;220'   # yellow
    else                       printf '38;5;77'    # green
    fi
}

fmt_usage() {
    _r=$(printf '%.0f' "$1")
    printf '%s[%sm%s%%%s' "$ESC" "$(usage_color "$_r")" "$_r" "$RESET"
}

# 잔여량은 방향이 반대라 자기 값이 아니라 여집합으로 색을 정합니다 —
# 41% 남으면 초록, 10% 남으면 빨강. (100 - 잔여)로 유도하면 fmt_usage 와
# 정확히 대칭이 되어, 따로 둔 임계값 표가 어긋날 일이 없습니다.
fmt_remaining() {
    _r=$(printf '%.0f' "$1")
    printf '%s[%sm%s%%%s' "$ESC" "$(usage_color "$(( 100 - _r ))")" "$_r" "$RESET"
}

LINE1=""
LINE2=""
add1() { [ -n "$1" ] && LINE1="${LINE1:+$LINE1 | }$1"; return 0; }
add2() { [ -n "$1" ] && LINE2="${LINE2:+$LINE2 | }$1"; return 0; }

# 1. 모델명(계열별 색상). 버전이 올라가도("Opus 5", "Opus 4.1", ...) 계속
#    동작하도록 전체 이름이 아니라 계열 부분 문자열로 판정합니다. 바로 옆에
#    붙는 effort 램프와 색이 겹치지 않도록 256색 코드를 씁니다.
if [ -n "$MODEL_NAME" ]; then
    HAYSTACK=$(lower "$MODEL_NAME $MODEL_ID")
    case "$HAYSTACK" in
        *opus*)   CODE='38;5;208' ;;  # orange
        *sonnet*) CODE='38;5;75'  ;;  # blue
        *haiku*)  CODE='38;5;114' ;;  # green
        *fable*)  CODE='38;5;176' ;;  # purple
        *)        CODE=''         ;;
    esac
    if [ -n "$CODE" ]; then
        add1 "${ESC}[${CODE}m${MODEL_NAME}${RESET}"
    else
        add1 "$MODEL_NAME"
    fi
fi

# 2. 현재 추론(thinking) 수준
#    effort.level(low/medium/high/xhigh/max)은 reasoning-effort 설정을 지원하는
#    모델에만 존재하므로, 없을 때는 thinking.enabled 로 대체합니다. 레이블 없이
#    값만 찍되 차가운색→뜨거운색 램프로 칠해 한눈에 알아보게 합니다.
if [ -n "$EFFORT" ]; then
    case "$(lower "$EFFORT")" in
        low)    CODE='32' ;;  # green
        medium) CODE='36' ;;  # cyan
        high)   CODE='33' ;;  # yellow
        xhigh)  CODE='95' ;;  # bright magenta
        max)    CODE='91' ;;  # bright red
        *)      CODE=''   ;;
    esac
    if [ -n "$CODE" ]; then
        add1 "${ESC}[${CODE}m${EFFORT}${RESET}"
    else
        add1 "$EFFORT"
    fi
elif [ -n "$THINKING" ]; then
    add1 "thinking: on"
fi

# 3. git 브랜치
#    statusLine JSON 스키마에는 "현재 브랜치" 필드가 없어서 git 을 직접
#    호출해 알아냅니다(optional lock 은 건너뜁니다).
if [ -n "$CWD" ]; then
    BRANCH=$(git --no-optional-locks -C "$CWD" branch --show-current 2>/dev/null)
    [ -n "$BRANCH" ] && add1 "$BRANCH_ICON $BRANCH"
fi

# 4. 세션 시작 이후 경과 시간, 예: "1h 30m" / "1d 2h 32m"
#    "세션 시작 시각" 필드도 JSON 에 없으므로, 세션 트랜스크립트
#    (transcript_path)에서 가장 먼저 나오는 "timestamp" 값으로 유도합니다.
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    START_TS=$(head -n 20 "$TRANSCRIPT" 2>/dev/null \
        | jq -Rr 'fromjson? | .timestamp? // empty' 2>/dev/null | head -n 1)
    if [ -n "$START_TS" ]; then
        # fromdateiso8601 은 소수점 이하 초를 못 받으므로 먼저 떼어냅니다.
        START_EPOCH=$(printf '%s' "$START_TS" \
            | jq -Rr '(sub("\\.[0-9]+";"") | fromdateiso8601?) // empty' 2>/dev/null)
        if [ -z "$START_EPOCH" ]; then
            # "+09:00" 같은 오프셋 표기 등 위에서 실패한 형식은 date 로 처리합니다.
            START_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' \
                "$(printf '%s' "$START_TS" | cut -c1-19)" '+%s' 2>/dev/null) \
                || START_EPOCH=$(date -d "$START_TS" '+%s' 2>/dev/null) \
                || START_EPOCH=""
        fi
        if is_int "$START_EPOCH"; then
            add1 "$CLOCK $(fmt_duration "$(( $(date '+%s') - START_EPOCH ))")"
        fi
    fi
fi

# 5. 미리 계산된 컨텍스트 윈도 사용률
is_num "$CTX_USED" && add1 "ctx used: $(fmt_usage "$CTX_USED")"

# 6. 미리 계산된 컨텍스트 윈도 잔여율
is_num "$CTX_LEFT" && add1 "ctx left: $(fmt_remaining "$CTX_LEFT")"

# 7. 현재 작업 디렉터리. 가장 길고 변동이 큰 항목이라, 폭이 고정된 항목들
#    뒤에 두어 줄 왼쪽이 흔들리지 않게 합니다.
[ -n "$CWD" ] && add1 "$CWD"

# 8. 사용 한도와 리셋까지 남은 시간. 별도의 둘째 줄에 5시간 → 7일 순서로
#    찍고, 페이로드에 없는 창은 그냥 건너뜁니다.
NOW=$(date '+%s')
for WINDOW in "5h:$FIVE_USED:$FIVE_RESET" "7d:$SEVEN_USED:$SEVEN_RESET"; do
    LABEL=${WINDOW%%:*}
    REST=${WINDOW#*:}
    USED=${REST%%:*}
    RESETS_AT=${REST#*:}

    is_num "$USED" && add2 "$LABEL used: $(fmt_usage "$USED")"
    if is_int "$RESETS_AT"; then
        LEFT=$(( RESETS_AT - NOW ))
        [ "$LEFT" -gt 0 ] && add2 "$LABEL reset: $(fmt_duration "$LEFT")"
    fi
done

# 사용 한도는 2행에 놓습니다. 한도 정보가 없으면(구독 미적용이거나 첫 API 응답
# 이전) 1행만 출력하고 빈 줄을 남기지 않습니다.
[ -n "$LINE1" ] && printf '%s\n' "$LINE1"
[ -n "$LINE2" ] && printf '%s\n' "$LINE2"
exit 0
