#!/usr/bin/env bash
# SwingWatch 프로젝트 생성 스크립트 (macOS 전용)
# 1) XcodeGen으로 SwingWatch.xcodeproj 생성
# 2) Xcode 26 이상이면 워치 앱 임베드 위치를 PlugIns로 패치
#    (XcodeGen이 만드는 "Embed Watch Content"(Watch/ 디렉터리) 방식은
#     Xcode 26의 빌드 검증에서 거부된다 — yonaskolb/XcodeGen#1613)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen이 없습니다. Homebrew로 설치합니다..."
  brew install xcodegen
fi

xcodegen generate

PBXPROJ="SwingWatch.xcodeproj/project.pbxproj"
XCODE_MAJOR="$(xcodebuild -version 2>/dev/null | awk 'NR==1 { print int($2) }')"

if [ -n "${XCODE_MAJOR}" ] && [ "${XCODE_MAJOR}" -ge 26 ]; then
  if grep -q 'dstPath = "\$(CONTENTS_FOLDER_PATH)/Watch";' "${PBXPROJ}"; then
    /usr/bin/sed -i '' \
      -e 's|dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";|dstPath = "";|' \
      -e 's|dstSubfolderSpec = 16;|dstSubfolderSpec = 13;|' \
      "${PBXPROJ}"
    echo "Xcode ${XCODE_MAJOR} 감지: 워치 앱 임베드 위치를 PlugIns로 패치했습니다."
  fi
else
  echo "Xcode ${XCODE_MAJOR:-?} 감지: 기본(Embed Watch Content) 방식을 그대로 사용합니다."
fi

echo
echo "완료! 다음 명령으로 여세요:  open SwingWatch.xcodeproj"
echo "Xcode에서 SwingWatch / SwingWatchWatch 타깃의 서명 팀을 선택한 뒤 빌드하면 됩니다."
