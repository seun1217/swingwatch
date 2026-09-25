#!/bin/bash
# Scripts/install.sh 자체 점검.
#   1) 부품 테스트: devicectl JSON 파싱(실제 기기 출력 샘플, Xcode 26·27 형식), 기기 선택,
#      빌드/설치 오류 분류, Xcode 계정·팀 찾기
#   2) 흐름 테스트: 가짜 Xcode·iPhone·워치로 설치 전 과정을 모의 실행
#
# macOS에서는 그대로 실행된다(CI). 다른 OS에서는 osascript(JXA) 대역이 PATH에 있어야 한다.
# macOS 기본 bash 3.2 로도 돌아가야 한다:  /bin/bash Scripts/tests/install-selftest.sh

# shellcheck disable=SC2034  # 여기서 정한 변수들은 불러온 install.sh가 쓴다
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FX="$HERE/fixtures"
PASS=0; FAIL=0

check() {   # check "설명" 실제값 기대값
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL %s\n       got:      [%s]\n       expected: [%s]\n' "$1" "$2" "$3"; fi
}
contains() {   # contains "설명" 파일 "찾을 문자열"
  if grep -qF -- "$3" "$2"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL %s (없음: %s)\n' "$1" "$3"; fi
}

SWINGWATCH_SOURCED=1
# shellcheck source=../install.sh
. "$ROOT/Scripts/install.sh"
write_jxa

# ----------------------------------------------------------------------------
echo "== devicectl JSON 파싱"
load() { jxa devices "$FX/$1" > "$WORK/devices.tsv"; }

load devicectl-v3-iphone-watch.json
check "v3: 기기 4대 파싱" "$(grep -c . "$WORK/devices.tsv")" "4"
pick_iphone; check "v3: 유선 연결된 iPhone 선택" "$IPHONE_TRANSPORT/$IPHONE_DEVMODE/$IPHONE_OS" "wired/enabled/26.0"
check "v3: iPhone 준비 상태" "$(iphone_state)" "ready"
pick_watch; check "v3: 워치 발견(개발자 모드 꺼짐)" "$(watch_state)" "devmode"

load devicectl-v3-iphone.json
check "v3: 미페어링 항목도 행으로 나옴" "$(grep -c . "$WORK/devices.tsv")" "4"
pick_iphone; check "v3: 오프라인보다 연결 가능한 iPhone 우선" "$IPHONE_TUNNEL/$IPHONE_TRANSPORT" "disconnected/localNetwork"
check "v3: 'disconnected'는 정상(필요할 때 연결됨)" "$(iphone_state)" "ready"
check "v3: 워치 없음" "$(pick_watch && echo yes || echo no)" "no"

load devicectl-v3-watch-unavailable.json
pick_iphone; check "v3: 버전 문자열 '26.3.1 (a)' 유지" "$IPHONE_OS" "26.3.1 (a)"
pick_watch; check "v3: 워치 UDID 추출" "$(printf '%s' "$WATCH_UDID" | cut -c1-8)" "00008301"

load devicectl-shorebird.json
pick_iphone; check "v2(Xcode 15): iPhone" "$(iphone_state)" "ready"

load devicectl-v5.json
pick_iphone; check "v5(Xcode 27): 시뮬레이터 제외, 실기기 선택" "$IPHONE_OS/$IPHONE_DEVMODE" "27.0/enabled"
pick_watch; check "v5: 워치(개발자 모드 정보 없음 → 미준비)" "$(watch_state)" "devmode"

load devicectl-v5-only.json
pick_iphone; check "v5 새 스키마만: iPhone UDID" "$(printf '%s' "$IPHONE_UDID" | cut -c1-4)" "0000"
check "v5 새 스키마만: 개발자 모드 객체 해석" "$IPHONE_DEVMODE" "enabled"
check "v5 새 스키마만: 연결 상태" "$IPHONE_PAIR/$IPHONE_TUNNEL/$IPHONE_TRANSPORT" "paired/disconnected/localNetwork"
check "v5 새 스키마만: OS 버전" "$IPHONE_OS" "27.0"

: > "$WORK/devices.tsv"
pick_iphone; check "빈 목록: iPhone 없음 상태" "$(iphone_state)" "none"

# ----------------------------------------------------------------------------
echo "== devicectl 오류 분류"
: > "$WORK/empty.log"
check "잠긴 iPhone 실행 실패(JSON)" "$(classify_devicectl "$WORK/empty.log" "$FX/devicectl-launch-locked.json")" "locked"
cat > "$WORK/untrusted.log" <<'EOF'
ERROR: The application failed to launch. (com.apple.dt.CoreDeviceError error 10002 (0x2712))
           NSLocalizedFailureReason = The request was denied by service delegate (SBMainWorkspace) for reason: Security ("Unable to launch com.x because it has an invalid code signature, inadequate entitlements or its profile has not been explicitly trusted by the user").
EOF
check "신뢰 안 된 개발자" "$(classify_devicectl "$WORK/untrusted.log" "$WORK/none.json")" "untrusted"
echo "ERROR: Developer Mode is disabled. (com.apple.dt.CoreDeviceError error 10005)" > "$WORK/dm.log"
check "개발자 모드 꺼짐" "$(classify_devicectl "$WORK/dm.log" "$WORK/none.json")" "devmode"
echo "This device has reached the maximum number of installed apps using a free developer profile: {(...)}" > "$WORK/lim.log"
check "무료 앱 개수 한도" "$(classify_devicectl "$WORK/lim.log" "$WORK/none.json")" "applimit"
echo "ERROR: Timed out while attempting to establish tunnel using negotiated network parameters." > "$WORK/tun.log"
check "워치 연결 불안정(재시도 대상)" "$(classify_devicectl "$WORK/tun.log" "$WORK/none.json")" "transient"

# ----------------------------------------------------------------------------
echo "== 빌드 오류 분류"
cb() { printf '%s\n' "$1" > "$WORK/b.log"; classify_build_error "$WORK/b.log"; }
check "앱 ID 선점" "$(cb 'error: Failed Registering Bundle Identifier: The app identifier "com.seun1217.swingwatch" cannot be registered to your development team because it is not available. Change your bundle identifier to a unique string to try again.')" "bundle_taken"
check "앱 ID 10개 한도" "$(cb 'error: Communication with Apple failed. Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days.')" "appid_limit"
check "플랫폼 구성요소 없음" "$(cb 'error: iOS 26.6 is not installed. Please download and install the platform from Xcode > Settings > Components.')" "platform"
check "계정 없음" "$(cb 'error: No Accounts: Add a new account in Accounts settings.')" "account"
check "팀 계정 없음" "$(cb 'error: No Account for Team "Y8QK9BKTCW". Add a new account in Accounts settings or verify that your accounts have valid credentials.')" "account"
check "기기 미등록" "$(cb 'error: Communication with Apple failed: Your team has no devices from which to generate a provisioning profile.')" "no_device"
check "기기 못 찾음" "$(cb 'xcodebuild: error: Unable to find a destination matching the provided destination specifier:')" "destination"
check "'No profiles for'는 마지막 순위" "$(cb 'error: No profiles for '"'"'com.x'"'"' were found')" "provisioning"
check "알 수 없는 오류" "$(cb 'error: something else')" "unknown"

# ----------------------------------------------------------------------------
echo "== Xcode 계정·팀 찾기"
ACCTS=defaults-accounts-signed-in.txt; TEAMS=defaults-teams-free.txt
defaults() {
  case "$1 $3" in
    "read DVTDeveloperAccountManagerAppleIDLists") [ -n "$ACCTS" ] && cat "$FX/$ACCTS" ;;
    "read IDEProvisioningTeamByIdentifier") [ -n "$TEAMS" ] && cat "$FX/$TEAMS" ;;
    *) return 1 ;;
  esac
}
security() { return 0; }
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
check "무료 팀 1개" "$(xt_pick_team 2>/dev/null)" "Y8QK9BKTCW"
TEAMS=defaults-teams-paid-and-free.txt
check "유료+무료 팀이면 무료 팀 우선" "$(xt_pick_team 2>/dev/null)" "FREE654321"
ACCTS=defaults-accounts-signed-out.txt; TEAMS=defaults-teams-free.txt
xt_pick_team >/dev/null 2>&1; check "로그아웃 상태면 남아 있는 팀 캐시를 쓰지 않음" "$?" "1"
ACCTS=""; TEAMS=""
xt_pick_team >/dev/null 2>&1; check "아직 로그인 전이면 기다림" "$?" "1"
unset -f defaults security

# 실제 macOS의 defaults 출력 형식으로도 확인(설명서가 아니라 진짜 출력을 파싱하는지).
if [ "$(uname -s)" = Darwin ]; then
  echo "== 실제 macOS defaults 로 팀 찾기"
  XT_DOMAIN="com.swingwatch.selftest.$$"
  cat > "$WORK/prefs.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DVTDeveloperAccountManagerAppleIDLists</key>
  <dict>
    <key>IDE.Identifiers.Prod</key>
    <array><dict><key>identifier</key><string>2B3CF5A0-7D60-45CA-A716-26D75CF3F6B3</string></dict></array>
  </dict>
  <key>IDEProvisioningTeamByIdentifier</key>
  <dict>
    <key>2B3CF5A0-7D60-45CA-A716-26D75CF3F6B3</key>
    <array>
      <dict>
        <key>isFreeProvisioningTeam</key><false/>
        <key>teamID</key><string>PAID123456</string>
        <key>teamName</key><string>Some Company, Inc.</string>
        <key>teamType</key><string>Company/Organization</string>
      </dict>
      <dict>
        <key>isFreeProvisioningTeam</key><true/>
        <key>teamID</key><string>FREE654321</string>
        <key>teamName</key><string>홍길동 (Personal Team)</string>
        <key>teamType</key><string>Personal Team</string>
      </dict>
    </array>
  </dict>
</dict>
</plist>
PLIST
  defaults import "$XT_DOMAIN" "$WORK/prefs.plist"
  security() { return 0; }
  check "실제 defaults: 무료 팀 선택" "$(xt_pick_team 2>/dev/null)" "FREE654321"
  check "실제 defaults: 로그인 계정 인식" "$(xt_account_signed_in; echo $?)" "0"
  defaults delete "$XT_DOMAIN" >/dev/null 2>&1
  unset -f security
  XT_DOMAIN="com.apple.dt.Xcode"
fi

# ----------------------------------------------------------------------------
echo "== 흐름 모의 실행 (가짜 Xcode·iPhone·워치)"
T="$WORK/flow"; mkdir -p "$T"
FAKE_XCODE="$T/Xcode.app"
mkdir -p "$FAKE_XCODE/Contents/Developer/usr/bin"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_XCODE/Contents/Developer/usr/bin/xcodebuild"
chmod +x "$FAKE_XCODE/Contents/Developer/usr/bin/xcodebuild"
git init -q --bare "$T/remote.git"
git -C "$ROOT" push -q "$T/remote.git" HEAD:refs/heads/main 2>/dev/null \
  || { echo "  (git push to fake remote failed)"; FAIL=$((FAIL + 1)); }

# 가짜 명령들 — 함수가 같은 이름의 실제 명령보다 먼저 실행된다.
uname() { echo Darwin; }
sw_vers() { echo 26.6; }
xcode-select() { echo "/Library/Developer/CommandLineTools"; }
mdfind() { :; }
open() { echo "open $*" >> "$T/calls.log"; }
caffeinate() { :; }
sudo() { echo "sudo $*" >> "$T/calls.log"; }
security() { return 1; }
have_tty() { return 1; }
poll_wait() { POLL_REPLY=""; }
sleep() { :; }
defaults() {
  case "$1 $3" in
    "read DVTDeveloperAccountManagerAppleIDLists") cat "$FX/defaults-accounts-signed-in.txt" ;;
    "read IDEProvisioningTeamByIdentifier") cat "$FX/defaults-teams-free.txt" ;;
    *) return 1 ;;
  esac
}
xcodebuild() {
  echo "xcodebuild $*" >> "$T/calls.log"
  case "$1" in
    -version) printf 'Xcode 26.6\nBuild version 17F113\n'; return 0 ;;
    -license|-checkFirstLaunchStatus) return 0 ;;
  esac
  local scheme="" dd="" prefix="" a prev=""
  for a in "$@"; do
    case "$prev" in -scheme) scheme="$a" ;; -derivedDataPath) dd="$a" ;; esac
    case "$a" in BUNDLE_ID_PREFIX=*) prefix="${a#BUNDLE_ID_PREFIX=}" ;; esac
    prev="$a"
  done
  if [ "${FAKE_TAKEN:-0}" = 1 ] && [ "$prefix" = "com.seun1217" ]; then
    echo 'error: Failed Registering Bundle Identifier: The app identifier "com.seun1217.swingwatch" cannot be registered to your development team because it is not available.'
    echo '** BUILD FAILED **'; return 65
  fi
  if [ "$scheme" = SwingWatchWatch ]; then
    mkdir -p "$dd/Build/Products/Debug-watchos/SwingWatchWatch.app"
  else
    mkdir -p "$dd/Build/Products/Debug-iphoneos/SwingWatch.app/Watch/SwingWatchWatch.app"
  fi
  echo '** BUILD SUCCEEDED **'
}
xcrun() {
  echo "xcrun $*" >> "$T/calls.log"
  local json="" a prev=""
  for a in "$@"; do [ "$prev" = "--json-output" ] && json="$a"; prev="$a"; done
  case "$*" in
    "--sdk iphoneos --show-sdk-version"|"--sdk watchos --show-sdk-version") echo 26.5 ;;
    "devicectl list devices"*) cp "$FX/flow-devices.json" "$json" ;;
    "devicectl device info details"*) return 1 ;;
    "devicectl device info ddiServices"*) return 0 ;;
    "devicectl manage pair"*) return 0 ;;
    "devicectl device install app"*) echo "App installed:"; return 0 ;;
    "devicectl device info apps"*) echo '{"result":{"apps":[{"bundleIdentifier":"x"}]}}' > "$json" ;;
    "devicectl device process launch"*)
      LAUNCHES=$(( $(cat "$T/launches" 2>/dev/null || echo 0) + 1 )); echo "$LAUNCHES" > "$T/launches"
      # iPhone 첫 두 번은 '신뢰 안 됨'(사용자가 설정에서 신뢰할 때까지), 그다음 성공
      if [ "$LAUNCHES" -le 2 ]; then
        echo 'ERROR: Unable to launch x because it has an invalid code signature, inadequate entitlements or its profile has not been explicitly trusted by the user.' >&2
        return 1
      fi ;;
    *) echo "unexpected xcrun $*" >> "$T/calls.log"; return 1 ;;
  esac
}

run_flow() {   # $1: 출력 파일
  rm -f "$T/launches" "$T/calls.log"
  (
    DEVELOPER_DIR="$FAKE_XCODE/Contents/Developer"
    REPO_URL="$T/remote.git"; BRANCH=main
    INSTALL_DIR="$T/SwingWatch"; STATE_DIR="$INSTALL_DIR/.install"
    main
  ) > "$1" 2>&1
  echo "$?"
}

FAKE_TAKEN=0 SWINGWATCH_SKIP_WATCH=0
check "흐름 1: 정상 설치 종료 코드" "$(run_flow "$T/flow1.out")" "0"
contains "흐름 1: 설치 완료 메시지" "$T/flow1.out" "설치 끝"
contains "흐름 1: 워치 먼저 빌드(워치 등록)" "$T/calls.log" "-scheme SwingWatchWatch -configuration Debug -destination platform=watchOS,id=00008301-000B22222222202E"
contains "흐름 1: iPhone 빌드는 하드웨어 UDID로" "$T/calls.log" "-destination platform=iOS,id=00008110-000A11111111801E"
contains "흐름 1: 기기 등록 허용 플래그" "$T/calls.log" "-allowProvisioningUpdates -allowProvisioningDeviceRegistration"
contains "흐름 1: 찾은 팀으로 서명" "$T/calls.log" "DEVELOPMENT_TEAM=Y8QK9BKTCW"
contains "흐름 1: 신뢰 안내 표시" "$T/flow1.out" "VPN 및 기기 관리"
contains "흐름 1: 워치에 직접 설치" "$T/calls.log" "devicectl device install app --device 66666666-7777-8888-9999-AAAAAAAAAAAA"
contains "흐름 1: 워치 설치 확인" "$T/flow1.out" "워치에 스윙워치가 설치됐어요"
check "흐름 1: 설정 저장(팀)" "$(sed -n 's/^team=//p' "$T/SwingWatch/.install/config")" "Y8QK9BKTCW"
check "흐름 1: sudo 호출 없음" "$(grep -c '^sudo' "$T/calls.log")" "0"

# 두 번째 실행(7일 뒤 재설치 상황): 기존 폴더 업데이트 경로
check "흐름 2: 재실행도 정상 종료" "$(run_flow "$T/flow2.out")" "0"
contains "흐름 2: 기존 코드 업데이트" "$T/flow2.out" "최신 코드로 업데이트했어요"

# 앱 ID가 선점된 경우: 팀 전용 ID로 바꿔 다시 빌드, 워치 건너뛰기
rm -rf "$T/SwingWatch"
FAKE_TAKEN=1 SWINGWATCH_SKIP_WATCH=1
check "흐름 3: 앱 ID 선점 시에도 설치 완료" "$(run_flow "$T/flow3.out")" "0"
contains "흐름 3: 전용 ID로 전환 안내" "$T/flow3.out" "com.swingwatch.ty8qk9bktcw"
check "흐름 3: 바뀐 ID 저장" "$(sed -n 's/^bundle_prefix=//p' "$T/SwingWatch/.install/config")" "com.swingwatch.ty8qk9bktcw"
check "흐름 3: 워치 빌드 안 함" "$(grep -c 'scheme SwingWatchWatch' "$T/calls.log")" "0"
FAKE_TAKEN=0 SWINGWATCH_SKIP_WATCH=0

echo
echo "통과 $PASS, 실패 $FAIL"
if [ "$FAIL" -ne 0 ]; then
  for f in "$T"/flow*.out; do [ -f "$f" ] && { echo "----- $f"; cat "$f"; }; done
  exit 1
fi
