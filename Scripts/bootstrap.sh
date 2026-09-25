#!/usr/bin/env bash
# SwingWatch 프로젝트 생성 스크립트 (macOS 전용)
# project.yml을 고쳤을 때 XcodeGen으로 SwingWatch.xcodeproj를 다시 만든다.
# (보통은 GitHub Actions의 generate-project 워크플로가 대신 해 준다)
#
# 워치 앱은 XcodeGen 기본값인 Watch/ 에 임베드된다. 이것이 Xcode(Swift Build)의
# 표준 위치이며, PlugIns/ 로 옮기면 iPhone Watch 앱의 '사용 가능한 앱'에
# 나타나지 않는 사례가 있어 패치하지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen이 없습니다. Homebrew로 설치합니다..."
  brew install xcodegen
fi

xcodegen generate

echo
echo "완료! 다음 명령으로 여세요:  open SwingWatch.xcodeproj"
