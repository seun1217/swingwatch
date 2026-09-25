#!/bin/bash
# =============================================================================
# 스윙워치 설치 도우미 — iPhone과 Apple Watch에 스윙워치를 설치합니다.
#
# 터미널에 아래 한 줄을 붙여 넣고 Enter:
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/seun1217/swingwatch/main/Scripts/install.sh)"
#
# 자동으로 하는 일: Xcode 준비 → 코드 내려받기(~/SwingWatch) → 서명 팀 찾기
#   → iPhone·워치 확인 → 빌드·서명 → iPhone 설치·실행 → 워치에 직접 설치
# 사람이 꼭 해야 하는 일(Apple ID 로그인, iPhone·워치 화면의 버튼)은 그때그때
# 화면에 안내하고, 끝나면 자동으로 알아차리고 이어갑니다.
#
# 무료 Apple ID로 설치한 앱은 7일 뒤 만료됩니다. 같은 명령을 다시 실행하면 됩니다.
#
# 환경 변수(보통은 필요 없음):
#   SWINGWATCH_DIR          설치 폴더 (기본: ~/SwingWatch)
#   SWINGWATCH_BRANCH       내려받을 브랜치 (기본: main)
#   SWINGWATCH_TEAM_ID      서명 팀 ID 직접 지정
#   SWINGWATCH_DEVICE       설치할 iPhone(UDID 또는 CoreDevice ID) 직접 지정
#   SWINGWATCH_SKIP_WATCH=1 Apple Watch 단계 건너뛰기
#   SWINGWATCH_CI=1         CI 점검용: 서명·기기 없이 빌드만 확인
#
# macOS 기본 bash 3.2에서 동작해야 한다: 연관 배열·mapfile·${v,,} 금지,
# set -u 상태에서 빈 배열 확장 금지, $( ) 안의 here-doc 금지.
# =============================================================================

set -u
set -o pipefail
# 사용자 환경의 XCODE_XCCONFIG_FILE은 명령줄 빌드 설정까지 덮어쓰므로 이 스크립트에선 쓰지 않는다.
unset XCODE_XCCONFIG_FILE

REPO_URL="https://github.com/seun1217/swingwatch.git"
INSTALL_DIR="${SWINGWATCH_DIR:-$HOME/SwingWatch}"
BRANCH="${SWINGWATCH_BRANCH:-main}"
CI_MODE="${SWINGWATCH_CI:-0}"
DEFAULT_BUNDLE_PREFIX="com.seun1217"
PROJECT_NAME="SwingWatch"
IOS_SCHEME="SwingWatch"
WATCH_SCHEME="SwingWatchWatch"

STATE_DIR="$INSTALL_DIR/.install"   # .gitignore 대상: 로그·설정
LOG_FILE=""
WORK="$(mktemp -d "${TMPDIR:-/tmp}/swingwatch.XXXXXX")"
JXA="$WORK/devicectl.js"
TAB="$(printf '\t')"

XCODE_APP=""; XCODE_MAJOR=0
TEAM_ID=""; BUNDLE_PREFIX=""
IPHONE_ID=""; IPHONE_UDID=""; IPHONE_NAME=""; IPHONE_OS=""; IPHONE_DEVMODE=""
IPHONE_PAIR=""; IPHONE_TUNNEL=""; IPHONE_TRANSPORT=""
WATCH_ID=""; WATCH_UDID=""; WATCH_NAME=""; WATCH_OS=""; WATCH_DEVMODE=""
WATCH_PAIR=""; WATCH_TUNNEL=""; WATCH_READY=0
DERIVED=""; APP_PATH=""; WATCH_APP_PATH=""
BUILD_ERR=""; PLATFORMS_DOWNLOADED=0; POLL_REPLY=""; PREFERRED_IPHONE=""; LAST_DEVICES_LOG=""

# ----------------------------------------------------------------------------
# 화면 출력
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_B=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_0=$'\033[0m'
else
  C_B=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_0=""
fi

STEP_NO=0
# 기록 파일에는 Apple ID 이메일과 Mac 사용자 이름을 가려서 남긴다(도움 요청 때 보내도 되도록).
redact() {
  sed -E -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<이메일>/g' \
         -e 's#/Users/[^/ "]+#/Users/<사용자>#g'
}
log()  { [ -n "$LOG_FILE" ] && printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | redact >> "$LOG_FILE" 2>/dev/null; return 0; }
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s[%d] %s%s\n' "$C_B$C_BLU" "$STEP_NO" "$1" "$C_0"; log "=== STEP $STEP_NO: $1"; }
info() { printf '    %s\n' "$1"; log "INFO: $1"; }
ok()   { printf '    %s✓ %s%s\n' "$C_GRN" "$1" "$C_0"; log "OK: $1"; }
warn() { printf '    %s! %s%s\n' "$C_YEL" "$1" "$C_0"; log "WARN: $1"; }
todo() {
  printf '\n    %s👉 직접 해주세요%s\n' "$C_B$C_YEL" "$C_0"
  printf '%s\n' "$1" | sed 's/^/       /'
  log "TODO: $1"
}
die() {
  printf '\n    %s✗ %s%s\n' "$C_B$C_RED" "$1" "$C_0"
  log "FATAL: $1"
  if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    printf '\n    자세한 기록: %s\n' "$LOG_FILE"
    printf '    이 파일을 개발 도우미(Claude)에게 보내주시면 원인을 찾아드려요.\n'
    printf '    (이메일·Mac 사용자 이름은 가려서 저장했지만 기기 정보가 있으니 공개된 곳엔 올리지 마세요)\n'
  fi
  printf '    문제를 해결한 뒤 같은 명령을 다시 실행하면 이어서 진행됩니다.\n\n'
  exit 1
}

BG_PID=""   # 지금 진행 표시 중인 백그라운드 명령(빌드·설치 등)
stop_job() {   # 프로세스와 그 자식들을 끝낸다
  [ -n "$1" ] || return 0
  pkill -TERM -P "$1" 2>/dev/null
  kill -TERM "$1" 2>/dev/null
  return 0
}
cleanup() {
  stop_job "$BG_PID"
  stop_job "${PLATFORM_PID:-}"
  rm -rf "$WORK" 2>/dev/null
}
on_interrupt() {
  printf '\n\n    멈췄어요. 같은 명령을 다시 실행하면 이어서 진행해요.\n\n'
  exit 130   # EXIT 트랩(cleanup)이 백그라운드 빌드·다운로드도 정리한다
}
trap cleanup EXIT
trap on_interrupt INT TERM

have_tty() { ( : </dev/tty ) 2>/dev/null; }

# 최대 $1초 기다린다. 그 사이 Enter를 치면 바로 반환하고, 입력한 글자는 POLL_REPLY에 담긴다.
poll_wait() {
  POLL_REPLY=""
  if have_tty; then
    read -r -t "$1" POLL_REPLY </dev/tty 2>/dev/null || POLL_REPLY=""
  else
    sleep "$1"
  fi
}
wants_skip() { case "$POLL_REPLY" in s|S|ㄴ) return 0 ;; esac; return 1; }

press_enter() {
  have_tty || return 0
  printf '\n    %s다 됐으면 Enter 키를 누르세요…%s ' "$C_DIM" "$C_0"
  read -r _ </dev/tty || true
}

# 번호 선택. 결과(1부터)를 표준 출력으로.
choose() {
  local count="$1" answer
  have_tty || { echo 1; return; }
  while :; do
    printf '    번호를 입력하고 Enter: ' >/dev/tty
    read -r answer </dev/tty || answer=1
    case "$answer" in
      ''|*[!0-9]*) ;;
      *) if [ "$answer" -ge 1 ] && [ "$answer" -le "$count" ]; then echo "$answer"; return; fi ;;
    esac
    printf '    1부터 %s 사이의 번호를 입력하세요.\n' "$count" >/dev/tty
  done
}

# 명령을 백그라운드로 돌리며 진행 표시. $1: 안내 문구, $2: 출력 파일, 나머지: 명령
run_with_progress() {
  local label="$1" out="$2" pid elapsed=0 rc
  shift 2
  "$@" > "$out" 2>&1 &
  pid=$!
  BG_PID=$pid
  printf '    %s' "$label"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5; elapsed=$((elapsed + 5))
    if [ $((elapsed % 60)) -eq 0 ]; then printf ' %d분' $((elapsed / 60)); else printf '.'; fi
  done
  wait "$pid"; rc=$?
  BG_PID=""
  echo
  [ -n "$LOG_FILE" ] && { echo "----- $* (exit $rc)"; cat "$out"; } | redact >> "$LOG_FILE" 2>/dev/null
  return $rc
}

# ----------------------------------------------------------------------------
# devicectl JSON 파서 (jq/python 없이 macOS 내장 JavaScript for Automation 사용)
# JSON 파일만이 devicectl의 공식 스크립트용 출력이다. Xcode 26(jsonVersion 2~3)과
# Xcode 27(jsonVersion 5, 'properties' 스키마)을 모두 읽는다.
# ----------------------------------------------------------------------------
write_jxa() {
  cat > "$JXA" <<'JS'
ObjC.import('Foundation');
function readJSON(path) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  var t = ObjC.unwrap(s);
  if (typeof t !== 'string' || t.length === 0) return null;
  try { return JSON.parse(t); } catch (e) { return null; }
}
function f(v) {
  if (v === undefined || v === null || v === '') return '-';
  return String(v).replace(/[\t\r\n]/g, ' ').replace(/ /g, ' ');
}
function devRow(d) {
  var hp = d.hardwareProperties || {}, dp = d.deviceProperties || {}, cp = d.connectionProperties || {};
  var p = d.properties || {}, ph = p.hardware || {}, pc = p.connection || {}, ps = p.state || {}, sw = p.software || {};
  var dm = dp.developerModeStatus;
  if (dm === undefined || dm === null) {
    var o = ps.developerModeStatus;   // Xcode 27: {"enabled":{...}} | {"disabled":{}}
    dm = (o && typeof o === 'object') ? (('enabled' in o) ? 'enabled' : 'disabled') : (typeof o === 'string' ? o : '');
  }
  var osv = dp.osVersionNumber || sw.osVersionNumber || '';
  if (osv && typeof osv === 'object') osv = osv.stringValue || osv.string || '';
  var ddi = dp.ddiServicesAvailable === true ? 'yes' : (dp.ddiServicesAvailable === false ? 'no' : '');
  return [f(d.identifier), f(hp.udid || ph.udid), f(hp.platform || ph.platform),
          f(hp.deviceType || ph.deviceType), f(dp.name || ps.name),
          f(dm), f(cp.tunnelState || pc.state), f(cp.transportType || pc.transportType),
          f(cp.pairingState || pc.pairingState), f(osv), f(hp.reality || ph.reality), f(ddi)].join('\t');
}
function run(argv) {
  var mode = argv[0], j = readJSON(argv[1]);
  if (!j) return '';
  if (mode === 'devices') {
    // list devices -> result.devices[] ; device info details -> result는 기기 하나
    var r = j.result || {}, devs = r.devices ? r.devices : (r.identifier ? [r] : []), out = [];
    for (var i = 0; i < devs.length; i++) out.push(devRow(devs[i] || {}));
    return out.join('\n');
  }
  if (mode === 'apps-count') {
    var apps = (j.result && j.result.apps) || [];
    return String(apps.length);
  }
  if (mode === 'error') {
    // 가장 안쪽 오류 설명까지 이어 붙인다(분류용).
    var e = j.error, parts = [];
    while (e) {
      var ui = e.userInfo || {};
      var d = ui.NSLocalizedDescription, r2 = ui.NSLocalizedFailureReason;
      if (d) parts.push(typeof d === 'object' ? (d.string || '') : String(d));
      if (r2) parts.push(typeof r2 === 'object' ? (r2.string || '') : String(r2));
      parts.push((e.domain || '') + ' ' + (e.code === undefined ? '' : e.code));
      e = ui.NSUnderlyingError ? (ui.NSUnderlyingError.error || null) : null;
    }
    return parts.join(' | ');
  }
  return '';
}
JS
}

jxa() { osascript -l JavaScript "$JXA" "$@" 2>>"$WORK/jxa.err"; }

# ----------------------------------------------------------------------------
# 1. Xcode 준비
# ----------------------------------------------------------------------------
find_xcode() {
  local dev candidate
  for dev in "${DEVELOPER_DIR:-}" "$(xcode-select -p 2>/dev/null)"; do
    case "$dev" in
      *.app/Contents/Developer)
        if [ -x "$dev/usr/bin/xcodebuild" ]; then XCODE_APP="${dev%/Contents/Developer}"; return 0; fi ;;
    esac
  done
  if [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]; then
    XCODE_APP=/Applications/Xcode.app; return 0
  fi
  candidate="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null \
    | grep -v '/Volumes/' | sort | tail -1)"
  if [ -n "$candidate" ] && [ -x "$candidate/Contents/Developer/usr/bin/xcodebuild" ]; then
    XCODE_APP="$candidate"; return 0
  fi
  return 1
}

prepare_xcode() {
  step "Xcode 확인"
  [ "$(uname -s)" = "Darwin" ] || die "이 스크립트는 Mac에서만 실행할 수 있어요."

  if ! find_xcode; then
    todo "Xcode가 없어요. 열리는 App Store에서 Xcode를 설치하세요(수십 분 걸려요).
설치가 끝나면 Xcode를 한 번 실행했다가 닫고, 이 명령을 다시 실행하세요."
    open "macappstore://apps.apple.com/app/id497799835" 2>/dev/null || true
    exit 1
  fi
  # 이 스크립트 안에서만 이 Xcode를 쓴다(xcode-select 설정은 건드리지 않아 sudo 불필요).
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
  # 버전은 앱 번들에서 읽는다(라이선스 동의 전에는 xcodebuild -version도 거부된다).
  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$XCODE_APP/Contents/Info.plist" 2>/dev/null)"
  XCODE_MAJOR="${version%%.*}"
  case "$XCODE_MAJOR" in ''|*[!0-9]*) XCODE_MAJOR=0 ;; esac
  ok "Xcode ${version:-?} ($XCODE_APP)"
  if [ "$XCODE_MAJOR" -gt 0 ] && [ "$XCODE_MAJOR" -lt 15 ]; then
    die "Xcode 15 이상이 필요해요. App Store에서 Xcode를 업데이트하세요."
  fi

  # 라이선스 동의 / 첫 실행 구성요소 — 필요할 때만 관리자 암호를 묻는다.
  local need_license=0 need_first=0
  if xcodebuild -license check >/dev/null 2>&1; then :; else need_license=1; fi
  if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then :; else need_first=1; fi
  if [ "$need_license" = 1 ] || [ "$need_first" = 1 ]; then
    [ "$CI_MODE" = 1 ] && die "CI 환경에서 Xcode 라이선스/첫 실행 구성이 필요합니다."
    todo "Xcode 라이선스 동의와 구성요소 설치에 Mac 로그인 암호가 필요해요.
암호를 입력해도 화면에 아무것도 안 보이는 게 정상이에요. 입력 후 Enter."
    if [ "$need_license" = 1 ]; then
      sudo "$DEVELOPER_DIR/usr/bin/xcodebuild" -license accept || die "Xcode 라이선스 동의에 실패했어요."
      ok "Xcode 라이선스 동의"
    fi
    if [ "$need_first" = 1 ]; then
      sudo -v || die "관리자 암호 확인에 실패했어요."   # 백그라운드 작업은 암호를 물을 수 없으니 미리 인증
      run_with_progress "Xcode 구성요소 설치 중(몇 분)" "$WORK/firstlaunch.log" \
        sudo "$DEVELOPER_DIR/usr/bin/xcodebuild" -runFirstLaunch \
        || {
          tail -15 "$WORK/firstlaunch.log" | sed 's/^/      /'
          mkdir -p "$HOME/Library/Logs" && redact < "$WORK/firstlaunch.log" > "$HOME/Library/Logs/swingwatch-firstlaunch.log"
          die "Xcode 구성요소 설치에 실패했어요. Xcode를 직접 한 번 실행해 안내를 따른 뒤 다시 시도하세요.
    (기록: ~/Library/Logs/swingwatch-firstlaunch.log)"
        }
      ok "Xcode 구성요소 설치"
    fi
  fi
}

# ----------------------------------------------------------------------------
# 2. 코드 내려받기 / 업데이트
# ----------------------------------------------------------------------------
fetch_code() {
  step "스윙워치 코드 내려받기"
  if [ -d "$INSTALL_DIR/.git" ]; then
    update_code
  else
    if [ -e "$INSTALL_DIR" ]; then
      local backup
      backup="$INSTALL_DIR.backup-$(date +%Y%m%d-%H%M%S)"
      mv "$INSTALL_DIR" "$backup" || die "$INSTALL_DIR 폴더를 정리하지 못했어요."
      warn "원래 있던 $INSTALL_DIR 폴더는 $backup 으로 옮겨뒀어요."
    fi
    git clone --quiet --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR" 2>>"$WORK/git.log" \
      || { cat "$WORK/git.log" >&2; die "코드를 내려받지 못했어요. 인터넷 연결을 확인하세요."; }
    ok "코드를 내려받았어요 ($INSTALL_DIR)"
  fi

  mkdir -p "$STATE_DIR"
  LOG_FILE="$STATE_DIR/install.log"
  : > "$LOG_FILE"
  log "installer: branch=$BRANCH xcode=$XCODE_APP major=$XCODE_MAJOR macOS=$(sw_vers -productVersion 2>/dev/null) commit=$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null)"
  cat "$WORK"/*.log 2>/dev/null | redact >> "$LOG_FILE" || true
  [ -f "$INSTALL_DIR/$PROJECT_NAME.xcodeproj/project.pbxproj" ] || die "내려받은 코드에 Xcode 프로젝트가 없어요."
  DERIVED="$INSTALL_DIR/.build"
}

gitc() { git -C "$INSTALL_DIR" "$@"; }

# 이미 받아둔 코드를 최신으로. 사용자가 고친 코드·커밋은 절대 버리지 않는다.
update_code() {
  local edits branch ahead patch prefix
  mkdir -p "$STATE_DIR"
  # 직접 고친 코드(추적 파일 변경 또는 새 파일). Xcode 프로젝트 파일 변경은 따로 다룬다.
  edits="$(gitc status --porcelain 2>/dev/null | awk '{print $NF}' | grep -v "^$PROJECT_NAME.xcodeproj/" || true)"
  branch="$(gitc symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [ -n "$edits" ] || [ "$branch" != "$BRANCH" ]; then
    warn "직접 고친 코드가 있어서 업데이트는 건너뛰고 지금 코드로 설치할게요."
    return 0
  fi
  # 예전 설치 도우미가 얕게(최근 커밋만) 받아둔 경우 전체 기록을 받아야 안전하게 합칠 수 있다.
  if [ "$(gitc rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    gitc fetch --quiet --unshallow origin 2>>"$WORK/git.log" || true
  fi
  if ! gitc fetch --quiet origin "$BRANCH" 2>>"$WORK/git.log"; then
    warn "업데이트를 받지 못했어요(인터넷 확인). 지금 코드로 계속할게요."
    return 0
  fi
  ahead="$(gitc rev-list --count FETCH_HEAD..HEAD 2>/dev/null || echo 1)"
  if [ "$ahead" != 0 ]; then
    warn "직접 저장(커밋)한 변경이 있어서 업데이트는 건너뛰고 지금 코드로 설치할게요."
    return 0
  fi
  # Xcode에서 바꾼 프로젝트 설정(팀 선택 등)은 백업해 두고 되돌린다. 직접 정한 앱 ID는 이어받는다.
  if ! gitc diff --quiet -- "$PROJECT_NAME.xcodeproj" 2>/dev/null; then
    patch="$STATE_DIR/xcodeproj-$(date +%Y%m%d-%H%M%S).patch"
    gitc diff -- "$PROJECT_NAME.xcodeproj" > "$patch" 2>/dev/null
    prefix="$(sed -n 's/^+[[:space:]]*BUNDLE_ID_PREFIX = \([^;]*\);.*/\1/p' "$patch" | tr -d '"' | head -1)"
    [ -n "$prefix" ] && config_set user_bundle_prefix "$prefix"
    gitc checkout --quiet -- "$PROJECT_NAME.xcodeproj" 2>/dev/null || true
    info "Xcode에서 바꾼 프로젝트 설정은 백업해 두고 되돌렸어요 (${patch#"$INSTALL_DIR"/})"
  fi
  if gitc merge --quiet --ff-only FETCH_HEAD 2>>"$WORK/git.log"; then
    ok "최신 코드로 업데이트했어요 ($INSTALL_DIR)"
  else
    warn "업데이트를 합치지 못해 지금 코드로 계속할게요."
  fi
}

config_get() { [ -f "$STATE_DIR/config" ] && sed -n "s/^$1=//p" "$STATE_DIR/config" | tail -1; return 0; }
config_set() {
  touch "$STATE_DIR/config"
  grep -v "^$1=" "$STATE_DIR/config" > "$WORK/config.new" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$2" >> "$WORK/config.new"
  mv "$WORK/config.new" "$STATE_DIR/config"
}

# ----------------------------------------------------------------------------
# 3. 서명 팀(Apple ID) 찾기
#   1) com.apple.dt.Xcode IDEProvisioningTeamByIdentifier (Xcode 16+/26/27, 계정 UUID 키)
#   2) IDEProvisioningTeams (Xcode 15 이하, 이메일 키 — 업그레이드한 Mac에 남아 있을 수 있음)
#   3) 키체인 "Apple Development" 인증서의 OU (첫 빌드 이후에만 존재)
#   팀 캐시는 로그아웃 뒤에도 남으므로 DVTDeveloperAccountManagerAppleIDLists의
#   로그인 계정과 대조한다. (이 부분은 Apple bash 3.2.57 + Apple awk로 시나리오 테스트됨)
# ----------------------------------------------------------------------------
XT_DOMAIN="com.apple.dt.Xcode"

xt_accounts() {
  local raw
  raw=$(defaults read "$XT_DOMAIN" DVTDeveloperAccountManagerAppleIDLists 2>/dev/null) || return 1
  printf '%s\n' "$raw" | awk '
    function val(s) { sub(/^[^=]*=[ \t]*/, "", s); sub(/;[ \t]*$/, "", s); gsub(/"/, "", s); return s }
    /IDE\.Identifiers\.Prod"?[ \t]*=/ { print "hasids"; list = ($0 ~ /\)/) ? "" : "id"; next }
    /IDE\.Prod"?[ \t]*=/              {                 list = ($0 ~ /\)/) ? "" : "user"; next }
    list != "" && /^[ \t]*\);?[ \t]*$/ { list = ""; next }
    list == "id"   && /^[ \t]*identifier[ \t]*=/ { printf "id\t%s\n",   val($0) }
    list == "user" && /^[ \t]*username[ \t]*=/   { printf "user\t%s\n", val($0) }
  '
  return 0
}

# 출력: 계정키<TAB>순번<TAB>팀ID<TAB>무료(0|1)<TAB>팀종류
xt_team_rows() {
  defaults read "$XT_DOMAIN" "$1" 2>/dev/null | awk '
    function val(s) { sub(/^[^=]*=[ \t]*/, "", s); sub(/;[ \t]*$/, "", s); gsub(/"/, "", s); return s }
    /=[ \t]*\([ \t]*$/ { acct = $0; sub(/^[ \t]*/, "", acct); sub(/[ \t]*=.*$/, "", acct)
                         gsub(/"/, "", acct); idx = -1; next }
    /^[ \t]*\{[ \t]*$/ { idx++; tid = ""; free = "0"; ttype = ""; next }
    /^[ \t]*teamID[ \t]*=/                 { tid = val($0); next }
    /^[ \t]*isFreeProvisioningTeam[ \t]*=/ { free = val($0); next }
    /^[ \t]*teamType[ \t]*=/               { ttype = val($0); next }
    /^[ \t]*\},?[ \t]*$/ {
      if (length(tid) == 10 && tid ~ /^[A-Z0-9]+$/) {
        if (ttype == "Personal Team") free = "1"
        printf "%s\t%d\t%s\t%s\t%s\n", acct, idx, tid, free, (ttype == "" ? "-" : ttype)
      }
      tid = ""; next
    }
  '
  return 0
}

# 키체인의 유효한 "Apple Development" 인증서에서 팀 ID(OU). 괄호 안 ID는 팀 ID가 아니다.
xt_keychain_teams() {
  local tmp cert
  tmp=$(mktemp -d "$WORK/certs.XXXXXX") || return 0
  security find-certificate -a -c "Apple Development" -p 2>/dev/null |
    awk -v dir="$tmp" '/-----BEGIN CERTIFICATE-----/ { n++ } n { print > (dir "/" n ".pem") }'
  for cert in "$tmp"/*.pem; do
    [ -e "$cert" ] || continue
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || continue
    openssl x509 -in "$cert" -noout -subject 2>/dev/null |
      sed -n 's/.*OU[ ]*=[ ]*\([A-Z0-9][A-Z0-9]*\).*/\1/p' |
      awk 'length($0) == 10'
  done | sort -u
  rm -rf "$tmp"
}

# 후보 팀: 팀ID<TAB>무료<TAB>출처(live|cache|cert|stale)<TAB>계정키<TAB>순번<TAB>캐시키
xt_candidate_teams() {
  local accts="" rc=0 live_keys="" signed_in=0 key rows kind k idx tid free
  accts=$(xt_accounts) || rc=1
  if [ $rc -eq 0 ]; then
    live_keys=$(printf '%s\n' "$accts" | awk -F '\t' '
      $1 == "hasids" { modern = 1 } $1 == "id" { id[++ni] = $2 } $1 == "user" { u[++nu] = $2 }
      END { if (modern) { for (i = 1; i <= ni; i++) print id[i] } else { for (i = 1; i <= nu; i++) print u[i] } }')
    [ -n "$live_keys" ] && signed_in=1
  fi
  {
    rows=$(xt_team_rows IDEProvisioningTeamByIdentifier); key=IDEProvisioningTeamByIdentifier
    if [ -z "$rows" ]; then rows=$(xt_team_rows IDEProvisioningTeams); key=IDEProvisioningTeams; fi
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows" | while IFS="$TAB" read -r k idx tid free _; do
        [ -n "$tid" ] || continue
        if [ $rc -ne 0 ]; then kind=cache
        elif printf '%s\n' "$live_keys" | grep -qxF "$k"; then kind=live
        else kind=stale
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tid" "$free" "$kind" "$k" "$idx" "$key"
      done
    fi
    xt_keychain_teams | while read -r tid; do printf '%s\t?\tcert\t-\t-\t-\n' "$tid"; done
  } | awk -F '\t' -v signed_in="$signed_in" '
      $3 == "stale" { if ($6 == "IDEProvisioningTeamByIdentifier" && !sseen[$1]++) stale[++ns] = $0; next }
      !seen[$1]++ { print; np++ }
      END { if (np == 0 && signed_in == 1) for (i = 1; i <= ns; i++) print stale[i] }
    '
}

xt_team_name() {
  local tmp name=""
  for tmp in "$1" "$2" "$3"; do [ -n "$tmp" ] && [ "$tmp" != "-" ] || return 0; done
  tmp="$WORK/xcode-prefs.plist"
  if defaults export "$XT_DOMAIN" "$tmp" 2>/dev/null; then
    name=$(/usr/libexec/PlistBuddy -c "Print :$1:$2:$3:teamName" "$tmp" 2>/dev/null) || name=""
  fi
  printf '%s' "$name"
}

# 0 = 로그인됨, 1 = 확실히 로그아웃, 2 = 알 수 없음
xt_account_signed_in() {
  local accts
  accts=$(xt_accounts) || return 2
  printf '%s\n' "$accts" | awk -F '\t' '
    $1 == "hasids" { modern = 1 } $1 == "id" { ids++ } $1 == "user" { users++ }
    END { if (modern) exit (ids > 0 ? 0 : 1); exit (users > 0 ? 0 : 1) }'
}

# 팀 하나를 골라 표준 출력. 0 = 선택됨, 1 = 아직 없음(계속 기다림), 2 = 사용자 취소
xt_pick_team() {
  local all free pool n i ans s=0 saved tid fr acct idx ckey label
  xt_account_signed_in || s=$?
  [ $s -eq 1 ] && return 1
  all=$(xt_candidate_teams)
  [ -n "$all" ] || return 1
  free=$(printf '%s\n' "$all" | awk -F '\t' '$2 == "1"')
  if [ -n "$free" ]; then pool=$free; else pool=$all; fi
  n=$(printf '%s\n' "$pool" | grep -c .)
  if [ "$n" -eq 1 ]; then printf '%s\n' "$pool" | cut -f1; return 0; fi

  saved="$(config_get team)"
  if [ -n "$saved" ] && printf '%s\n' "$pool" | cut -f1 | grep -qxF "$saved"; then
    printf '%s\n' "$saved"; return 0
  fi
  echo "    Xcode에 팀이 여러 개 있어요. 앱을 서명할 팀 번호를 입력하세요:" >&2
  i=0
  printf '%s\n' "$pool" | while IFS="$TAB" read -r tid fr _ acct idx ckey; do
    i=$((i + 1))
    label=$(xt_team_name "$ckey" "$acct" "$idx")
    [ "$fr" = "1" ] && label="${label:-개인 팀} [무료]"
    printf '      %d) %s  %s\n' "$i" "$tid" "$label" >&2
  done
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    echo "    터미널 입력을 받을 수 없어요. SWINGWATCH_TEAM_ID=<팀ID> 를 지정해 다시 실행하세요." >&2
    return 2
  fi
  while :; do
    printf '    번호 (1-%d, q=취소): ' "$n" >&2
    if ! read -r ans <&3; then exec 3<&-; return 2; fi
    case "$ans" in
      q|Q) exec 3<&-; return 2 ;;
      *[!0-9]*|'') continue ;;
    esac
    if [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ]; then
      exec 3<&-
      printf '%s\n' "$pool" | sed -n "${ans}p" | cut -f1
      return 0
    fi
  done
}

accounts_pane_name() { if [ "$XCODE_MAJOR" -ge 27 ]; then echo "Apple Accounts"; else echo "Accounts"; fi; }

select_team() {
  step "서명 팀(Apple ID) 확인"
  if [ -n "${SWINGWATCH_TEAM_ID:-}" ]; then
    TEAM_ID="$SWINGWATCH_TEAM_ID"; ok "지정된 팀: $TEAM_ID"; config_set team "$TEAM_ID"; return
  fi
  local start=$SECONDS shown=0 hinted=0 rc pane
  pane="$(accounts_pane_name)"
  while :; do
    rc=0; TEAM_ID=$(xt_pick_team) || rc=$?
    if [ $rc -eq 0 ] && [ -n "$TEAM_ID" ]; then break; fi
    [ $rc -eq 2 ] && die "서명 팀을 고르지 않아 설치를 멈췄어요."
    if [ $shown -eq 0 ]; then
      shown=1
      open -a "$XCODE_APP" 2>/dev/null || true
      todo "Xcode에 Apple ID로 로그인해 주세요 (처음 한 번만).
 0. Xcode가 처음 열리면 '구성요소/플랫폼을 고르는 창'이 뜰 수 있어요.
    도우미가 필요한 것만 받고 있으니, 그 창은 그냥 닫거나 건너뛰어도 돼요.
 1. Xcode에서, 화면 맨 위 메뉴 [Xcode] → [Settings…] (단축키 ⌘ ,)
 2. 위쪽 [$pane] 탭 → 왼쪽 아래 [+] → [Apple ID] (또는 Apple Account) → [Continue]
 3. 평소 쓰는 Apple ID, 암호, 인증 코드 입력
 4. 오른쪽에 '내 이름 (Personal Team)'이 보이면 끝이에요.
무료 Apple ID면 충분해요. 로그인되면 자동으로 다음 단계로 넘어가요."
      printf '    로그인 기다리는 중'
    fi
    if [ $hinted -eq 0 ] && [ $((SECONDS - start)) -ge 60 ] && xt_account_signed_in; then
      hinted=1
      echo
      todo "로그인은 확인됐는데 팀 정보가 아직 없어요. Xcode 설정 창에서:
 계정 클릭 → [Manage Certificates…] → 왼쪽 아래 [+] → [Apple Development]
인증서가 만들어지면 바로 이어서 진행해요."
      printf '    기다리는 중'
    fi
    [ $((SECONDS - start)) -ge 1800 ] && { echo; die "30분 동안 Xcode 로그인이 확인되지 않았어요."; }
    printf '.'
    poll_wait 3
  done
  [ $shown -gt 0 ] && echo
  config_set team "$TEAM_ID"
  ok "서명 팀: $TEAM_ID"
}

# ----------------------------------------------------------------------------
# 4. 기기 찾기 (devicectl)
# 열: 1 CoreDevice ID  2 UDID  3 플랫폼  4 종류  5 이름  6 개발자모드  7 터널상태
#     8 연결방식  9 페어링  10 OS버전  11 실기기/시뮬레이터  12 DDI  (빈 값은 "-")
# ----------------------------------------------------------------------------
refresh_devices() {
  rm -f "$WORK/devices.json"
  xcrun devicectl list devices --timeout 30 --json-output "$WORK/devices.json" \
    >"$WORK/devicectl-list.log" 2>&1 || true
  if [ -s "$WORK/devices.json" ]; then jxa devices "$WORK/devices.json" > "$WORK/devices.tsv"; else : > "$WORK/devices.tsv"; fi
  local summary
  summary="$(cut -f1-4,6-12 "$WORK/devices.tsv" | tr '\n' '|')"   # 5번째 열(기기 이름)은 남기지 않는다
  if [ "$summary" != "$LAST_DEVICES_LOG" ]; then LAST_DEVICES_LOG="$summary"; log "devices: $summary"; fi
}

# 기기 하나에 터널을 열어 최신 상태를 다시 읽는다(목록의 개발자 모드 값은 틀릴 수 있음).
device_details() {
  rm -f "$WORK/details.json"
  xcrun devicectl device info details --device "$1" --timeout 30 --json-output "$WORK/details.json" \
    >"$WORK/details.log" 2>&1 || true
  [ -s "$WORK/details.json" ] && jxa devices "$WORK/details.json" | head -1
}

pick_iphone() {
  local best=0 rank ident udid platform dtype name devmode tunnel transport pairing osver reality
  IPHONE_ID=""; IPHONE_UDID=""; IPHONE_NAME=""; IPHONE_OS=""; IPHONE_DEVMODE=""
  IPHONE_PAIR=""; IPHONE_TUNNEL=""; IPHONE_TRANSPORT=""
  while IFS="$TAB" read -r ident udid platform dtype name devmode tunnel transport pairing osver reality _; do
    [ -n "$ident" ] && [ "$ident" != "-" ] || continue
    [ "$reality" = "simulated" ] && continue
    [ "$platform" = "iOS" ] || continue
    case "$dtype" in iPhone|-) ;; *) continue ;; esac
    if [ -n "${SWINGWATCH_DEVICE:-}" ] && [ "$ident" != "$SWINGWATCH_DEVICE" ] && [ "$udid" != "$SWINGWATCH_DEVICE" ]; then
      continue
    fi
    rank=1
    [ "$pairing" = "paired" ] && rank=$((rank + 4))
    if [ "$tunnel" != "unavailable" ] && [ "$transport" != "-" ]; then rank=$((rank + 2)); fi
    [ "$transport" = "wired" ] && rank=$((rank + 1))
    [ -n "$PREFERRED_IPHONE" ] && [ "$udid" = "$PREFERRED_IPHONE" ] && rank=$((rank + 20))
    if [ "$rank" -gt "$best" ]; then
      best=$rank; IPHONE_ID=$ident; IPHONE_UDID=$udid; IPHONE_NAME=$name; IPHONE_OS=$osver
      IPHONE_DEVMODE=$devmode; IPHONE_PAIR=$pairing; IPHONE_TUNNEL=$tunnel; IPHONE_TRANSPORT=$transport
    fi
  done < "$WORK/devices.tsv"
  [ -n "$IPHONE_ID" ]
}

pick_watch() {
  local best=0 rank ident udid platform dtype name devmode tunnel transport pairing osver reality
  WATCH_ID=""; WATCH_UDID=""; WATCH_NAME=""; WATCH_OS=""; WATCH_DEVMODE=""; WATCH_PAIR=""; WATCH_TUNNEL=""
  while IFS="$TAB" read -r ident udid platform dtype name devmode tunnel transport pairing osver reality _; do
    [ -n "$ident" ] && [ "$ident" != "-" ] || continue
    [ "$reality" = "simulated" ] && continue
    [ "$platform" = "watchOS" ] || [ "$dtype" = "appleWatch" ] || continue
    rank=1
    [ "$pairing" = "paired" ] && rank=$((rank + 2))
    [ "$tunnel" != "unavailable" ] && [ "$tunnel" != "-" ] && rank=$((rank + 1))
    [ "$devmode" = "enabled" ] && rank=$((rank + 1))
    if [ "$rank" -gt "$best" ]; then
      best=$rank; WATCH_ID=$ident; WATCH_UDID=$udid; WATCH_NAME=$name; WATCH_OS=$osver
      WATCH_DEVMODE=$devmode; WATCH_PAIR=$pairing; WATCH_TUNNEL=$tunnel
    fi
  done < "$WORK/devices.tsv"
  [ -n "$WATCH_ID" ]
}

# 지금 연결 가능한 iPhone들: UDID<TAB>이름<TAB>iOS
reachable_iphones() {
  awk -F'\t' '$11 != "simulated" && $3 == "iOS" && ($4 == "iPhone" || $4 == "-") &&
               $9 == "paired" && $7 != "unavailable" && $8 != "-" && $2 != "-" { print $2 "\t" $5 "\t" $10 }' \
    "$WORK/devices.tsv"
}

# 상태 이름: none | unpaired | offline | devmode | ready
iphone_state() {
  if [ -z "$IPHONE_ID" ]; then echo none
  elif [ "$IPHONE_PAIR" != "paired" ]; then echo unpaired
  elif [ "$IPHONE_TUNNEL" = "unavailable" ] || [ "$IPHONE_TRANSPORT" = "-" ]; then echo offline
  elif [ "$IPHONE_DEVMODE" != "enabled" ]; then echo devmode
  else echo ready
  fi
}

select_iphone() {
  step "iPhone 확인"
  local state last="" start=$SECONDS nudged=0 line phones n pick devmode_shown=0 msg
  PREFERRED_IPHONE="${SWINGWATCH_DEVICE:-$(config_get iphone)}"
  while :; do
    refresh_devices
    # 연결된 iPhone이 여러 대이고 아직 고른 적이 없으면 물어본다(엉뚱한 폰에 설치하지 않도록).
    phones="$(reachable_iphones)"
    n=$(printf '%s' "$phones" | grep -c . || true)
    if [ "$n" -gt 1 ] && ! printf '%s\n' "$phones" | cut -f1 | grep -qxF "${PREFERRED_IPHONE:-none}"; then
      [ -n "$last" ] && echo
      info "연결된 iPhone이 여러 대예요. 스윙워치를 설치할 iPhone을 골라주세요:"
      printf '%s\n' "$phones" | awk -F'\t' '{printf "      %d) %s (iOS %s)\n", NR, $2, $3}'
      pick="$(choose "$n")"
      PREFERRED_IPHONE="$(printf '%s\n' "$phones" | sed -n "${pick}p" | cut -f1)"
      config_set iphone "$PREFERRED_IPHONE"
      last=""
    fi
    pick_iphone || true
    state="$(iphone_state)"
    if [ "$state" = devmode ]; then
      # 목록의 '개발자 모드 꺼짐'은 가끔 틀린다 → 기기에 직접 물어본다.
      line="$(device_details "$IPHONE_ID")"
      [ -n "$line" ] && [ "$(printf '%s\n' "$line" | cut -f6)" = "enabled" ] && { IPHONE_DEVMODE=enabled; state=ready; }
    fi
    log "iphone state=$state id=$IPHONE_ID udid=$IPHONE_UDID"
    [ "$state" = ready ] && break
    if [ "$state" != "$last" ]; then
      [ -n "$last" ] && echo
      case "$state" in
        none) todo "iPhone을 케이블로 Mac에 연결하고 iPhone 잠금을 풀어주세요.
'이 컴퓨터를 신뢰하겠습니까?'가 뜨면 [신뢰] → iPhone 암호 입력.
(iOS 17 이상이어야 해요. 케이블이 충전 전용이면 다른 케이블을 써보세요)" ;;
        unpaired)
          todo "iPhone 화면의 '이 컴퓨터를 신뢰하겠습니까?'에서 [신뢰]를 누르고 암호를 입력하세요.
창이 안 보이면 케이블을 뺐다가 다시 꽂고 iPhone 잠금을 풀어보세요."
          if [ $nudged -eq 0 ]; then
            nudged=1
            xcrun devicectl manage pair --device "$IPHONE_ID" --timeout 60 >"$WORK/pair.log" 2>&1 &
          fi ;;
        offline)
          if [ $devmode_shown -eq 1 ]; then
            msg="iPhone이 재시동 중이면 켜질 때까지 기다렸다가 잠금을 풀어주세요."
          else
            msg="'${IPHONE_NAME}'에 연결이 안 돼요. 케이블을 다시 꽂고 iPhone 잠금을 풀어주세요."
          fi
          todo "$msg" ;;
        devmode)
          if [ $devmode_shown -eq 1 ]; then
            todo "재시동 후 잠금을 풀면 '개발자 모드를 켜겠습니까?'가 떠요 → [켜기] → 암호 입력.
(이미 켰다면 잠시만 기다리세요. 자동으로 확인해요)"
          else
            devmode_shown=1
            todo "iPhone에서 '개발자 모드'를 켜주세요 (${IPHONE_NAME}):
 1. [설정] → [개인정보 보호 및 보안] → 맨 아래 [개발자 모드] 켜기
 2. [재시동] → 켜지면 잠금 해제 → '개발자 모드를 켜겠습니까?'에서 [켜기] → 암호
(메뉴가 안 보이면 케이블을 다시 꽂고 1분쯤 뒤에 확인하세요)"
          fi ;;
      esac
      printf '    기다리는 중'
      last="$state"
    fi
    printf '.'
    [ $((SECONDS - start)) -ge 1800 ] && { echo; die "30분 동안 iPhone 준비가 끝나지 않았어요."; }
    poll_wait 5
  done
  [ -n "$last" ] && echo
  ok "iPhone: ${IPHONE_NAME} (iOS ${IPHONE_OS})"
  check_os_support "iphoneos" "$IPHONE_OS" "iPhone"
}

# 기기 OS가 Xcode가 아는 것보다 새로우면 경고(설치는 계속 시도).
check_os_support() {
  local sdk dev_major sdk_major
  sdk="$(xcrun --sdk "$1" --show-sdk-version 2>/dev/null)"
  dev_major="${2%%.*}"; sdk_major="${sdk%%.*}"
  case "$dev_major$sdk_major" in *[!0-9]*|'') return 0 ;; esac
  if [ "$dev_major" -gt "$sdk_major" ]; then
    warn "$3 OS($2)가 이 Xcode(SDK $sdk)보다 새로워요. 설치가 실패하면 App Store에서 Xcode를 업데이트하세요."
  fi
}

# ----------------------------------------------------------------------------
# 5. Apple Watch 준비 (선택)
# 워치는 Mac과 '개발용 페어링'이 된 뒤에야 목록에 나타나고, 워치 자체의 개발자 모드가
# 따로 필요하다. 준비가 안 되면 건너뛰고 iPhone만 설치한다(나중에 다시 실행하면 됨).
# ----------------------------------------------------------------------------
devices_window_name() {
  if [ "$XCODE_MAJOR" -ge 27 ]; then echo "[Xcode] → [Open Developer Tool] → [Device Hub]"; else echo "[Window] → [Devices and Simulators] (단축키 ⇧⌘2)"; fi
}

# 연결이 안 되는 기기는 개발자 모드가 '꺼짐'으로 보고되므로(실제 값을 못 읽음) 먼저 연결 상태를 본다.
watch_state() {
  if [ -z "$WATCH_ID" ]; then echo none
  elif [ "$WATCH_PAIR" != "paired" ]; then echo unpaired
  elif [ "$WATCH_TUNNEL" = "unavailable" ] || [ "$WATCH_TUNNEL" = "-" ]; then echo offline
  elif [ "$WATCH_DEVMODE" != "enabled" ]; then echo devmode
  else echo ready
  fi
}

setup_watch() {
  step "Apple Watch 확인 (워치가 없으면 건너뛰어도 돼요)"
  if [ "${SWINGWATCH_SKIP_WATCH:-0}" = 1 ]; then info "워치 단계는 건너뛸게요."; return; fi
  local state last="" start=$SECONDS nudged=0 line win
  win="$(devices_window_name)"
  while :; do
    refresh_devices
    pick_watch || true
    state="$(watch_state)"
    # 연결이 끊겨 보이거나 개발자 모드가 꺼져 보이면 워치에 직접 물어본다(터널을 깨우는 효과도 있음).
    if { [ "$state" = devmode ] || [ "$state" = offline ]; } && [ -n "$WATCH_ID" ]; then
      line="$(device_details "$WATCH_ID")"
      if [ -n "$line" ]; then
        [ "$(printf '%s\n' "$line" | cut -f6)" = "enabled" ] && WATCH_DEVMODE=enabled
        WATCH_TUNNEL="$(printf '%s\n' "$line" | cut -f7)"
        state="$(watch_state)"
      fi
    fi
    log "watch state=$state id=$WATCH_ID udid=$WATCH_UDID"
    [ "$state" = ready ] && break
    if [ "$state" != "$last" ]; then
      [ -n "$last" ] && echo
      case "$state" in
        none) todo "워치를 Mac에 연결할게요. 아래를 확인해 주세요:
 1. 워치를 차거나 충전기에 올리고, 화면을 깨워 잠금을 풀어두기 (워치에 암호가 설정돼 있어야 해요)
 2. Mac의 Wi-Fi와 블루투스 켜기, 워치 [설정] → [Wi-Fi]에서 Mac과 같은 Wi-Fi에 연결
 3. Xcode 메뉴 $win 을 열고 목록에서 워치를 클릭
 4. 워치에 '신뢰하겠습니까?'가 뜨면 [신뢰] (iPhone에도 뜨면 [신뢰])
워치가 없거나 나중에 하려면 s 를 입력하고 Enter → iPhone만 설치해요." ;;
        unpaired)
          todo "워치 화면의 '이 컴퓨터를 신뢰하겠습니까?'에서 [신뢰]를 눌러주세요.
안 보이면 Xcode의 $win 에서 워치를 클릭하세요. (건너뛰려면 s + Enter)"
          if [ $nudged -eq 0 ]; then
            nudged=1
            xcrun devicectl manage pair --device "$WATCH_ID" --timeout 60 >"$WORK/watch-pair.log" 2>&1 &
          fi ;;
        devmode) todo "워치에서도 '개발자 모드'를 켜주세요 (iPhone과 따로 켜야 해요):
 1. 워치 [설정] → [개인정보 보호 및 보안] → 맨 아래 [개발자 모드] 켜기
 2. [재시동] → 켜지면 [켜기] → 워치 암호 입력
메뉴가 안 보이면 Xcode의 $win 에서 워치를 클릭한 뒤 워치를 재시동해 보세요.
(건너뛰려면 s + Enter)" ;;
        offline) todo "워치에 연결이 안 돼요. 워치 화면을 깨워 잠금을 풀고 Mac 가까이 두세요.
충전기에 올려두면 가장 안정적이에요. Mac의 Wi-Fi·블루투스도 켜주세요.
워치 개발자 모드를 아직 한 번도 안 켰다면: 워치 [설정] → [개인정보 보호 및 보안] → [개발자 모드]
(건너뛰려면 s + Enter)" ;;
      esac
      printf '    기다리는 중'
      last="$state"
    fi
    printf '.'
    if [ $((SECONDS - start)) -ge 1200 ]; then echo; warn "20분 동안 워치가 준비되지 않아 iPhone만 설치할게요."; return; fi
    poll_wait 5
    if wants_skip; then echo; info "워치는 건너뛸게요. 나중에 이 명령을 다시 실행하면 워치도 설치돼요."; return; fi
  done
  [ -n "$last" ] && echo
  ok "Apple Watch: ${WATCH_NAME} (watchOS ${WATCH_OS})"
  check_os_support "watchos" "$WATCH_OS" "Apple Watch"
  # 워치용 개발자 디스크 이미지를 미리 올려둔다(설치 속도·안정성). 실패해도 계속.
  run_with_progress "워치 연결 준비 중" "$WORK/watch-ddi.log" \
    xcrun devicectl device info ddiServices --device "$WATCH_ID" --timeout 120 \
    || warn "워치 준비가 덜 됐지만 계속할게요. 워치 화면을 켜두세요."
  WATCH_READY=1
}

# ----------------------------------------------------------------------------
# 6. 빌드 + 서명
# ----------------------------------------------------------------------------
# 빌드 로그에서 원인 분류. 순서가 중요('No profiles for'는 거의 모든 서명 실패에 붙어 나온다).
classify_build_error() {
  local f="$1"
  if grep -qiE "cannot be registered to your development team because it is not available|Failed Registering Bundle Identifier|Failed to register bundle identifier|could not be registered to your development team" "$f"; then echo bundle_taken
  elif grep -qiE "maximum App ID limit|You may create up to 10 App IDs" "$f"; then echo appid_limit
  elif grep -qiE "is not installed\. (Please download and install the platform|To use with Xcode, first download)" "$f"; then echo platform
  elif grep -qiE "No Accounts|No Account for Team|missing Xcode-Token|could not sign in|login details for account|Unable to log in with account|session has expired" "$f"; then echo account
  elif grep -qiE "requires a development team" "$f"; then echo no_team
  elif grep -qiE "Your team has no devices from which to generate a provisioning profile" "$f"; then echo no_device
  elif grep -qiE "is busy|Preparing the watch for development|Copying shared cache symbols|is preparing" "$f"; then echo busy
  elif grep -qiE "database is locked|two concurrent builds|concurrent builds running" "$f"; then echo db_locked
  elif grep -qiE "Unable to find a destination matching the provided destination specifier|needs to connect to determine its availability|Timed out waiting for" "$f"; then echo destination
  elif grep -qiE "Developer Mode (is )?disabled|enable Developer Mode" "$f"; then echo devmode
  elif grep -qiE "is not prefixed with the parent app's bundle identifier" "$f"; then echo bundle_structure
  elif grep -qiE "errSecInternalComponent|User interaction is not allowed" "$f"; then echo keychain
  elif grep -qiE "No space left on device" "$f"; then echo disk
  elif grep -qiE "No profiles for" "$f"; then echo provisioning
  else echo unknown
  fi
}

explain_build_error() {
  local kind="$1" f="$2" pane
  pane="$(accounts_pane_name)"
  case "$kind" in
    appid_limit) todo "무료 Apple ID는 7일 동안 앱 ID를 10개까지만 만들 수 있어 한도에 걸렸어요.
며칠 뒤 이 명령을 다시 실행해 주세요. (다음부터는 같은 ID를 재사용해서 더 쓰지 않아요)" ;;
    account|no_team) todo "Xcode의 Apple ID 로그인이 필요하거나 만료됐어요.
Xcode → [Settings…] → [$pane] 에서 계정을 선택해 다시 로그인하세요.
그래도 안 되면 계정을 [-]로 지웠다가 [+]로 다시 추가해 보세요.
(새 약관이 있으면 https://developer.apple.com 에 로그인해 동의해야 할 수 있어요)" ;;
    no_device|destination) todo "Xcode가 기기를 찾지 못했어요.
 - 케이블 연결, iPhone 잠금 해제, [신뢰], 개발자 모드가 켜져 있는지 확인하세요." ;;
    devmode) todo "기기의 개발자 모드가 꺼져 있어요.
[설정] → [개인정보 보호 및 보안] → [개발자 모드] 를 켜세요." ;;
    keychain) todo "키체인(암호 보관함) 접근이 막혔어요. 다시 실행하고, 'codesign이 키에 접근하려고 합니다'
창이 뜨면 Mac 로그인 암호를 입력하고 [항상 허용]을 눌러주세요." ;;
    disk) todo "Mac 저장 공간이 부족해요. 10GB 이상 비운 뒤 다시 실행하세요." ;;
    provisioning|bundle_structure) todo "서명용 프로필을 만들지 못했어요. iPhone 연결·잠금 해제 상태와
Xcode의 Apple ID 로그인([Settings…] → [$pane])을 확인한 뒤 다시 실행하세요." ;;
    *) info "마지막 오류 내용:"
       grep -E "(^|[[:space:]])error:" "$f" 2>/dev/null | sort -u | tail -12 | sed 's/^/      /' ;;
  esac
}

# ----------------------------------------------------------------------------
# Xcode 구성요소(iOS·watchOS 플랫폼). Xcode 26부터는 기기용 빌드에도 SDK와 같은 버전의
# 플랫폼(시뮬레이터 런타임)이 설치돼 있어야 한다. 각각 수 GB라서 사람이 로그인·기기 준비를
# 하는 동안 백그라운드로 받는다. xcodebuild -downloadPlatform의 종료 코드는 믿을 수 없어
# 받은 뒤 simctl로 실제 설치 여부를 확인한다. 관리자 암호는 필요 없다.
# ----------------------------------------------------------------------------
PLATFORM_PID=""

# $1: iOS|watchOS, $2: iphoneos|watchos → SDK와 같은 버전의 런타임이 있으면 0
platform_installed() {
  local v
  v="$(xcrun --sdk "$2" --show-sdk-version 2>/dev/null)"
  [ -n "$v" ] || return 1
  xcrun simctl list runtimes 2>/dev/null | grep -E "^$1 ${v}[ .(]" | grep -vq "unavailable"
}

missing_platforms() {
  local m=""
  platform_installed iOS iphoneos || m="iOS"
  platform_installed watchOS watchos || m="$m watchOS"
  printf '%s' "${m# }"
}

download_platform_list() {   # 백그라운드에서 실행된다
  local p
  for p in "$@"; do
    echo "=== xcodebuild -downloadPlatform $p"
    xcodebuild -downloadPlatform "$p" || echo "=== exit $?"
  done
}

start_platform_downloads() {
  step "Xcode 구성요소 확인"
  local missing free_gb
  missing="$(missing_platforms)"
  if [ -z "$missing" ]; then ok "iOS·watchOS 구성요소가 이미 있어요"; return; fi
  free_gb="$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$free_gb" in ''|*[!0-9]*) free_gb=999 ;; esac
  if [ "$free_gb" -lt 25 ]; then
    warn "Mac 저장 공간이 ${free_gb}GB 남았어요. 구성요소에 20GB 이상 필요해서 실패할 수 있어요."
  fi
  info "Xcode에 필요한 구성요소($missing)를 백그라운드로 내려받기 시작할게요."
  info "몇 GB라 10~30분 걸려요. 그동안 다음 단계를 함께 진행해요."
  info "(Xcode에서 'Components/플랫폼'을 내려받으라는 창이 떠도 닫으셔도 돼요)"
  # shellcheck disable=SC2086  # missing은 공백으로 구분된 목록
  ( download_platform_list $missing ) > "$WORK/platform-download.log" 2>&1 &
  PLATFORM_PID=$!
  log "platform download started: $missing (pid $PLATFORM_PID)"
}

finish_platform_downloads() {
  local missing elapsed=0 pct had_download=0
  [ -n "$PLATFORM_PID" ] && had_download=1
  if [ -n "$PLATFORM_PID" ] && kill -0 "$PLATFORM_PID" 2>/dev/null; then
    step "Xcode 구성요소 내려받기 마무리"
    printf '    내려받는 중'
    while kill -0 "$PLATFORM_PID" 2>/dev/null; do
      sleep 5; elapsed=$((elapsed + 5))
      if [ $((elapsed % 60)) -eq 0 ]; then
        pct="$(tail -c 400 "$WORK/platform-download.log" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1)"
        printf ' %d분%s' $((elapsed / 60)) "${pct:+($pct)}"
      else
        printf '.'
      fi
    done
    echo
  fi
  if [ -n "$PLATFORM_PID" ]; then
    wait "$PLATFORM_PID" 2>/dev/null
    PLATFORM_PID=""
    { echo "----- platform download"; cat "$WORK/platform-download.log"; } | redact >> "$LOG_FILE" 2>/dev/null
  fi
  missing="$(missing_platforms)"
  if [ -z "$missing" ]; then
    [ "$had_download" = 1 ] && ok "iOS·watchOS 구성요소 준비 완료"
    return 0
  fi
  # 한 번 더 앞에서(진행 표시와 함께) 시도
  download_platforms_foreground $missing && return 0
  todo "Xcode 구성요소($missing)를 받지 못했어요. Xcode에서 직접 받아주세요:
 Xcode → [Settings…] → [Components] → iOS·watchOS 옆 [Get]
다 받아지면 이 명령을 다시 실행하세요. (회사·학교 네트워크나 VPN에선 실패할 수 있어요)"
  die "Xcode 구성요소가 없어 빌드할 수 없어요."
}

# 빌드 중 '플랫폼 없음' 오류가 났을 때도 쓴다. 0 = 모두 설치됨
download_platforms_foreground() {
  [ "$PLATFORMS_DOWNLOADED" = 1 ] && return 1
  PLATFORMS_DOWNLOADED=1
  local p list="$*"
  [ -n "$list" ] || list="$(missing_platforms)"
  [ -n "$list" ] || return 0
  for p in $list; do
    run_with_progress "$p 구성요소 내려받는 중(수 GB)" "$WORK/download-$p.log" xcodebuild -downloadPlatform "$p" || true
  done
  [ -z "$(missing_platforms)" ]
}

# $1: 스킴, $2: -destination 값, $3: 안내 문구, $4: 로그 이름
signed_build() {
  local out="$WORK/build-$4.log"
  BUILD_ERR=""
  if run_with_progress "$3" "$out" xcodebuild \
      -project "$INSTALL_DIR/$PROJECT_NAME.xcodeproj" -scheme "$1" -configuration Debug \
      -destination "$2" -destination-timeout 120 -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
      CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" BUNDLE_ID_PREFIX="$BUNDLE_PREFIX" build \
    && grep -q '\*\* BUILD SUCCEEDED \*\*' "$out"; then
    return 0
  fi
  BUILD_ERR="$(classify_build_error "$out")"
  cp "$out" "$WORK/last-build.log"
  log "build $4 failed: $BUILD_ERR"
  return 1
}

build_apps() {
  step "앱 빌드·서명 (처음엔 5~15분)"
  BUNDLE_PREFIX="$(config_get bundle_prefix)"
  # 앱 ID는 그것을 등록한 팀 것이다. Apple ID(팀)가 바뀌었으면 기본값부터 다시 시작.
  if [ -n "$BUNDLE_PREFIX" ] && [ "$(config_get bundle_team)" != "$TEAM_ID" ]; then BUNDLE_PREFIX=""; fi
  [ -n "$BUNDLE_PREFIX" ] || BUNDLE_PREFIX="$(config_get user_bundle_prefix)"
  [ -n "$BUNDLE_PREFIX" ] || BUNDLE_PREFIX="$DEFAULT_BUNDLE_PREFIX"
  info "빌드 중 'codesign이 키체인에 접근하려고 합니다' 창이 뜨면
      Mac 로그인 암호를 입력하고 [항상 허용]을 눌러주세요."

  local attempts=0
  BUSY_WAITS=0
  while :; do
    attempts=$((attempts + 1))
    [ $attempts -gt 5 ] && die "여러 번 시도했지만 빌드에 실패했어요."
    info "앱 ID: $BUNDLE_PREFIX.swingwatch"

    # 워치를 먼저: 워치를 대상으로 빌드해야 무료 팀 프로필에 워치가 등록된다.
    [ "$WATCH_READY" = 1 ] && [ "$WATCH_WOKEN" = 0 ] && wake_watch_for_build
    if [ "$WATCH_READY" = 1 ]; then
      if ! signed_build "$WATCH_SCHEME" "platform=watchOS,id=$WATCH_UDID" "워치 앱 빌드 중" watch; then
        if [ "$BUILD_ERR" = busy ]; then
          if [ $BUSY_WAITS -ge 40 ]; then
            # 워치 준비가 20분 넘게 걸리면 iPhone부터 설치하고 워치는 다음 실행으로 미룬다.
            warn "워치 준비가 오래 걸려서 iPhone 앱부터 설치할게요. 워치는 나중에 이 명령을 다시 실행하면 돼요."
            WATCH_READY=0
          else
            wait_device_busy; attempts=$((attempts - 1)); continue
          fi
        fi
        if [ "$WATCH_READY" = 1 ] && [ "$BUILD_ERR" = destination ] && [ "$WATCH_RETRIED" = 0 ]; then
          # 워치가 잠들었을 가능성이 가장 크다 → 한 번 깨우고 다시.
          WATCH_RETRIED=1
          todo "Xcode가 워치를 찾지 못했어요. 워치 화면을 깨워 잠금을 풀고 Mac 가까이 두세요(충전기 위 권장)."
          press_enter
          attempts=$((attempts - 1)); continue
        fi
        [ "$WATCH_READY" = 1 ] && case "$BUILD_ERR" in
          destination|devmode|no_device|provisioning|unknown)
            warn "워치용 빌드에 실패해서 워치는 건너뛰고 iPhone 앱부터 설치할게요."
            explain_build_error "$BUILD_ERR" "$WORK/last-build.log"
            WATCH_READY=0 ;;
          *) handle_build_failure || return 1; continue ;;
        esac
      fi
    fi

    if signed_build "$IOS_SCHEME" "platform=iOS,id=$IPHONE_UDID" "iPhone 앱 빌드 중" ios; then
      break
    fi
    if [ "$BUILD_ERR" = busy ]; then wait_device_busy; attempts=$((attempts - 1)); continue; fi
    handle_build_failure || return 1
  done

  config_set bundle_prefix "$BUNDLE_PREFIX"
  config_set bundle_team "$TEAM_ID"
  APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/$PROJECT_NAME.app"
  WATCH_APP_PATH="$DERIVED/Build/Products/Debug-watchos/$WATCH_SCHEME.app"
  [ -d "$APP_PATH" ] || die "빌드는 끝났는데 앱 파일을 찾지 못했어요: $APP_PATH"
  [ -d "$WATCH_APP_PATH" ] || WATCH_APP_PATH="$APP_PATH/Watch/$WATCH_SCHEME.app"
  ok "빌드·서명 완료"
  if [ "$WATCH_READY" = 1 ] && ! profile_has_device "$WATCH_APP_PATH" "$WATCH_UDID"; then
    warn "워치 앱 서명에 이 워치가 아직 등록되지 않았어요. 워치 설치가 실패할 수 있어요."
  fi
}

# 구성요소 다운로드 등을 기다리는 사이 워치가 잠들었을 수 있다 → 빌드 직전에 깨운다.
WATCH_WOKEN=0; WATCH_RETRIED=0
wake_watch_for_build() {
  WATCH_WOKEN=1
  local start=$SECONDS line
  info "워치 앱을 빌드할게요. 워치 화면을 켜서 잠금을 풀고 Mac 가까이 두세요(충전기 위 권장)."
  while :; do
    line="$(device_details "$WATCH_ID")"
    [ -n "$line" ] && WATCH_TUNNEL="$(printf '%s\n' "$line" | cut -f7)"
    [ "$(watch_state)" = ready ] && return 0
    if [ $((SECONDS - start)) -ge 180 ]; then
      warn "워치에 연결되지 않아 이번엔 iPhone만 설치할게요. 나중에 이 명령을 다시 실행하면 워치도 설치돼요."
      WATCH_READY=0; return 1
    fi
    poll_wait 5
    if wants_skip; then WATCH_READY=0; info "워치는 건너뛸게요."; return 1; fi
  done
}

# 기기(특히 워치)를 처음 개발용으로 준비하는 동안 Xcode는 기기를 "busy"로 표시한다.
# 기다리면 풀린다(워치는 길게는 1시간 이상). 재시동하면 준비가 처음부터 다시 시작되니 권하지 않는다.
BUSY_WAITS=0
wait_device_busy() {
  BUSY_WAITS=$((BUSY_WAITS + 1))
  if [ $BUSY_WAITS -eq 1 ]; then
    info "Xcode가 기기를 개발용으로 준비하는 중이에요(처음 한 번). 워치는 오래 걸릴 수 있어요."
    info "워치 화면을 켜둔 채(충전기 위 권장) 기다려 주세요. 자동으로 다시 시도해요."
  elif [ $((BUSY_WAITS % 4)) -eq 0 ]; then
    info "아직 준비 중이에요… ($((BUSY_WAITS / 2))분째)"
  fi
  [ $BUSY_WAITS -gt 180 ] && die "기기 준비가 90분 넘게 끝나지 않았어요. 워치를 충전기에 올려둔 채 다시 실행해 보세요."
  sleep 30
}

# 실패 원인에 따라 자동 복구를 시도한다. 0 = 다시 빌드, 1 = 포기
handle_build_failure() {
  case "$BUILD_ERR" in
    db_locked)
      # 지난번에 멈춘 빌드가 남아 있다 → 이 설치 폴더의 빌드만 정리하고 다시.
      if [ "${DB_UNLOCKED:-0}" = 0 ]; then
        DB_UNLOCKED=1
        pkill -f -- "-derivedDataPath $DERIVED" 2>/dev/null
        sleep 5
        return 0
      fi ;;
    bundle_taken)
      # 다른 팀이 이미 쓰는 ID → 내 팀 전용 ID(팀 ID 기반이라 매번 같음)로 바꿔 다시.
      local team_prefix
      team_prefix="com.swingwatch.t$(printf '%s' "$TEAM_ID" | tr '[:upper:]' '[:lower:]')"
      if [ "$BUNDLE_PREFIX" != "$team_prefix" ]; then
        BUNDLE_PREFIX="$team_prefix"
        warn "앱 ID가 이미 다른 사람 것이라, 내 전용 ID($BUNDLE_PREFIX)로 바꿔 다시 빌드할게요."
        return 0
      fi ;;
    platform)
      download_platforms_foreground && return 0 ;;
    account)
      explain_build_error account "$WORK/last-build.log"
      press_enter
      return 0 ;;
  esac
  explain_build_error "$BUILD_ERR" "$WORK/last-build.log"
  die "빌드에 실패했어요."
}

profile_has_device() {
  [ -f "$1/embedded.mobileprovision" ] || return 1
  security cms -D -i "$1/embedded.mobileprovision" > "$WORK/profile.plist" 2>/dev/null || return 1
  /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$WORK/profile.plist" 2>/dev/null | grep -qi -- "$2"
}

# ----------------------------------------------------------------------------
# 7. iPhone 설치 + 실행
# ----------------------------------------------------------------------------
# devicectl 실패 분류: 로그와 JSON의 오류 설명을 함께 본다.
classify_devicectl() {
  local text
  text="$(cat "$1" 2>/dev/null) $( [ -s "$2" ] && jxa error "$2")"
  if printf '%s' "$text" | grep -qiE "explicitly trusted|invalid code signature|inadequate entitlements"; then echo untrusted
  elif printf '%s' "$text" | grep -qiE "could not be, unlocked|BSErrorCodeDescription = Locked|DeviceLocked|device is locked"; then echo locked
  elif printf '%s' "$text" | grep -qi "developer mode is disabled"; then echo devmode
  elif printf '%s' "$text" | grep -qiE "maximum number of (installed )?apps"; then echo applimit
  elif printf '%s' "$text" | grep -qiE "ApplicationVerificationFailed|profile"; then echo profile
  elif printf '%s' "$text" | grep -qiE "must be paired|not paired"; then echo unpaired
  elif printf '%s' "$text" | grep -qiE "0xFA0|timed out|connection was invalidated|could not be established|Transport error|RemotePairingError"; then echo transient
  else echo other
  fi
}

# $1: 기기 ID, $2: .app, $3: 시간 제한(초), $4: 이름 → 결과 분류를 INSTALL_ERR에
INSTALL_ERR=""
install_app() {
  INSTALL_ERR=""
  rm -f "$WORK/install-$4.json"
  if run_with_progress "설치 중" "$WORK/install-$4.log" xcrun devicectl device install app \
      --device "$1" --timeout "$3" --json-output "$WORK/install-$4.json" "$2"; then
    return 0
  fi
  INSTALL_ERR="$(classify_devicectl "$WORK/install-$4.log" "$WORK/install-$4.json")"
  log "install $4 failed: $INSTALL_ERR"
  return 1
}

install_iphone() {
  step "iPhone에 설치"
  local tries=0
  while :; do
    tries=$((tries + 1))
    install_app "$IPHONE_ID" "$APP_PATH" 300 iphone && break
    case "$INSTALL_ERR" in
      locked) todo "iPhone 잠금을 풀어주세요. (재시동 직후엔 잠금 해제가 꼭 필요해요)"; press_enter ;;
      devmode) todo "iPhone [설정] → [개인정보 보호 및 보안] → [개발자 모드] 를 켜주세요."; press_enter ;;
      applimit) todo "무료 Apple ID로 한 iPhone에 설치할 수 있는 앱 수(3개)를 넘었어요.
예전에 Xcode로 설치한 다른 앱을 iPhone에서 삭제한 뒤 계속하세요."; press_enter ;;
      transient) sleep 3 ;;
      *) grep -iE "error|fail" "$WORK/install-iphone.log" | tail -5 | sed 's/^/      /'
         die "iPhone에 설치하지 못했어요." ;;
    esac
    if [ $tries -ge 5 ]; then
      grep -iE "error|fail" "$WORK/install-iphone.log" | tail -5 | sed 's/^/      /'
      die "iPhone에 설치하지 못했어요."
    fi
  done
  ok "설치 완료! iPhone 홈 화면에 '스윙워치'가 생겼어요"
}

launch_iphone() {
  step "iPhone에서 실행 확인"
  local bundle="$BUNDLE_PREFIX.swingwatch" kind said="" tries=0 start=$SECONDS
  while :; do
    rm -f "$WORK/launch.json"
    if xcrun devicectl device process launch --device "$IPHONE_ID" --terminate-existing \
        --json-output "$WORK/launch.json" "$bundle" >"$WORK/launch.log" 2>&1; then
      [ -n "$said" ] && echo
      ok "iPhone에서 스윙워치가 열렸어요! 카메라 권한을 물으면 [허용]을 눌러주세요."
      return 0
    fi
    kind="$(classify_devicectl "$WORK/launch.log" "$WORK/launch.json")"
    tries=$((tries + 1))
    log "launch failed: $kind"
    # 설치 직후 첫 실행은 검증 중이라 잠깐 실패할 수 있다 → 한 번은 조용히 재시도.
    if [ "$kind" = untrusted ] && [ $tries -lt 2 ]; then sleep 3; continue; fi
    if [ "$kind" != "$said" ]; then
      [ -n "$said" ] && echo
      case "$kind" in
        untrusted) todo "iPhone이 처음 보는 개발자의 앱이라 실행을 막았어요. 한 번만 허용해 주세요:
 1. iPhone [설정] → [일반] → [VPN 및 기기 관리]
 2. '개발자 앱' 아래 내 Apple ID 이메일을 탭
 3. [\"...\" 신뢰] → [신뢰]   (iPhone이 인터넷에 연결돼 있어야 해요)
허용하면 자동으로 앱을 열어요." ;;
        locked) todo "iPhone 잠금을 풀어주세요." ;;
        devmode) todo "iPhone [설정] → [개인정보 보호 및 보안] → [개발자 모드] 를 켜주세요." ;;
        *) grep -iE "error|fail" "$WORK/launch.log" | tail -4 | sed 's/^/      /'
           warn "자동 실행은 건너뛸게요. iPhone에서 스윙워치를 직접 눌러 열어주세요."
           return 0 ;;
      esac
      printf '    기다리는 중'
      said="$kind"
    fi
    printf '.'
    if [ $((SECONDS - start)) -ge 900 ]; then echo; warn "자동 실행은 건너뛸게요. 신뢰 설정 후 iPhone에서 직접 열어주세요."; return 0; fi
    poll_wait 5
  done
}

# ----------------------------------------------------------------------------
# 8. Apple Watch 설치 — 워치에 직접 설치한다. (무료 계정 빌드는 iPhone Watch 앱의
#    '사용 가능한 앱' 경로로는 설치가 실패하는 경우가 많다.)
# ----------------------------------------------------------------------------
watch_has_app() {
  rm -f "$WORK/wapps.json"
  xcrun devicectl device info apps --device "$WATCH_ID" --bundle-id "$BUNDLE_PREFIX.swingwatch.watchkitapp" \
    --timeout 60 --json-output "$WORK/wapps.json" >"$WORK/wapps.log" 2>&1 || return 1
  local n
  n="$(jxa apps-count "$WORK/wapps.json")"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ]
}

install_watch() {
  step "Apple Watch에 설치"
  if [ "$WATCH_READY" != 1 ]; then
    info "워치 설치는 이번에 건너뛰었어요. 워치 준비가 되면 같은 명령을 다시 실행하세요."
    return
  fi
  local tries=0
  info "워치 화면을 켠 채로 두세요(충전기 위 권장). 1~4분 걸려요."
  while :; do
    tries=$((tries + 1))
    if install_app "$WATCH_ID" "$WATCH_APP_PATH" 240 watch; then break; fi
    case "$INSTALL_ERR" in
      devmode) todo "워치의 개발자 모드가 꺼져 있어요: 워치 [설정] → [개인정보 보호 및 보안] → [개발자 모드]"; press_enter ;;
      locked) todo "워치 화면을 깨워 잠금을 풀어주세요."; press_enter ;;
      applimit) todo "무료 Apple ID로 설치할 수 있는 앱 수를 넘었어요.
워치(또는 iPhone)에서 예전에 설치한 개발용 앱을 지운 뒤 계속하세요."; press_enter ;;
      profile) warn "워치 앱 서명에 이 워치가 아직 없어요. 잠시 뒤 이 명령을 다시 실행하면 워치가 등록돼요."
               WATCH_READY=0; return ;;
      *) warn "워치 연결이 불안정해요. 다시 시도할게요… ($tries/4)"
         [ $tries -eq 2 ] && info "계속 실패하면: 워치를 충전기에 올리고, iPhone [설정] → [Bluetooth]를
      잠시 끄면 워치가 Wi-Fi로 연결돼요(설치 후 다시 켜세요)."
         sleep 10 ;;
    esac
    if [ $tries -ge 4 ]; then
      WATCH_READY=0
      warn "워치에 직접 설치하지 못했어요."
      todo "워치를 충전기에 올려 화면을 켜두고, iPhone [설정] → [Bluetooth]를 잠시 끈 뒤
이 명령을 다시 실행해 보세요(워치가 Wi-Fi로 연결돼요. 설치 후 Bluetooth는 다시 켜세요).
iPhone 앱은 이미 설치돼 있어요."
      return
    fi
  done
  if watch_has_app; then ok "워치에 스윙워치가 설치됐어요!"; else ok "워치에 설치했어요."; fi
  if xcrun devicectl device process launch --device "$WATCH_ID" --terminate-existing \
      "$BUNDLE_PREFIX.swingwatch.watchkitapp" >"$WORK/watch-launch.log" 2>&1; then
    ok "워치에서 스윙워치를 열었어요."
  else
    info "워치에서 스윙워치 아이콘을 한 번 눌러 열어주세요."
  fi
}

# 무료 팀 프로필의 만료 시각을 읽어 알려준다(실패하면 조용히 넘어감).
print_expiry() {
  local prov="$APP_PATH/embedded.mobileprovision" iso epoch m d hm
  [ -f "$prov" ] || return 1
  security cms -D -i "$prov" > "$WORK/app-profile.plist" 2>/dev/null || return 1
  iso="$(plutil -extract ExpirationDate raw -o - "$WORK/app-profile.plist" 2>/dev/null)" || return 1
  epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null)" || return 1
  m="$(date -r "$epoch" '+%m')"; d="$(date -r "$epoch" '+%d')"; hm="$(date -r "$epoch" '+%H:%M')"
  printf '    이번 설치는 %d월 %d일 %s까지 쓸 수 있어요. 그 뒤엔 같은 명령을 다시 실행하세요.\n' \
    "$((10#$m))" "$((10#$d))" "$hm"
  log "profile expires: $iso"
}

# ----------------------------------------------------------------------------
# CI 점검: 서명·기기 없이 빌드하고 결과물 구조만 확인
# ----------------------------------------------------------------------------
ci_build() {
  step "빌드 점검 (CI)"
  BUNDLE_PREFIX="$DEFAULT_BUNDLE_PREFIX"
  run_with_progress "빌드 중" "$WORK/build-ci.log" xcodebuild \
    -project "$INSTALL_DIR/$PROJECT_NAME.xcodeproj" -scheme "$IOS_SCHEME" -configuration Debug \
    -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build \
    || { tail -40 "$WORK/build-ci.log"; die "빌드 실패(CI): $(classify_build_error "$WORK/build-ci.log")"; }
  APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/$PROJECT_NAME.app"
  local w="$APP_PATH/Watch/$WATCH_SCHEME.app" pb=/usr/libexec/PlistBuddy ios_id companion
  [ -d "$w" ] || die "워치 앱이 Watch/ 에 임베드되지 않았어요."
  ios_id="$($pb -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
  companion="$($pb -c 'Print :WKCompanionAppBundleIdentifier' "$w/Info.plist")"
  [ "$ios_id" = "$companion" ] || die "워치 앱의 짝 ID($companion)가 iPhone 앱 ID($ios_id)와 달라요."
  ok "앱 구조 확인: Watch/$WATCH_SCHEME.app, ID $ios_id"
}

# ----------------------------------------------------------------------------
main() {
  printf '\n%s⛳️ 스윙워치 설치 도우미%s\n' "$C_B" "$C_0"
  printf '%s필요한 순간에만 무엇을 누를지 알려드려요. 나머지는 자동으로 진행돼요.%s\n' "$C_DIM" "$C_0"
  printf '%s(언제든 멈추려면 control + C)%s\n' "$C_DIM" "$C_0"

  write_jxa
  prepare_xcode
  fetch_code
  caffeinate -dims -w $$ >/dev/null 2>&1 &   # 설치 중 Mac이 잠들지 않게

  if [ "$CI_MODE" = 1 ]; then
    start_platform_downloads
    finish_platform_downloads
    ci_build
    printf '\n%sCI 점검 완료%s\n' "$C_GRN" "$C_0"
    return 0
  fi

  start_platform_downloads   # 로그인·기기 준비와 동시에 받도록 먼저 시작
  select_team
  select_iphone
  setup_watch
  finish_platform_downloads
  build_apps
  install_iphone
  launch_iphone
  install_watch

  printf '\n%s🎉 설치 끝!%s\n' "$C_B$C_GRN" "$C_0"
  printf '    iPhone을 정면 2~4m에 세우고 [세션 시작]을 누른 뒤 스윙해 보세요.\n'
  [ "$WATCH_READY" = 1 ] && printf '    세션을 시작할 때 워치에서도 스윙워치를 열어두면 손목을 내려도 진동이 와요.\n'
  print_expiry || printf '    무료 Apple ID라 7일 뒤 앱이 안 열리면, 같은 명령을 다시 실행하면 돼요.\n'
  printf '    %s기록: %s%s\n\n' "$C_DIM" "$LOG_FILE" "$C_0"
}

# 테스트에서 함수만 불러쓸 때는 SWINGWATCH_SOURCED=1
if [ "${SWINGWATCH_SOURCED:-0}" != 1 ]; then
  main "$@"
fi
