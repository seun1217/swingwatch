# 스윙워치 (SwingWatch)

iPhone을 세워 두고 연습하면, **카메라가 계속 스윙을 지켜보다가 스윙이 하나 끝날 때마다 Apple Watch로 점수와 피드백(햅틱 + 화면)을 보내주는** 골프 연습 앱입니다.

레슨 없이 혼자 연습장에서 공을 칠 때 "방금 스윙이 어땠는지"를 손목에서 바로 확인하는 것이 목표입니다.

```
 iPhone (삼각대)                                Apple Watch
┌────────────────────────────┐                ┌───────────────┐
│ 카메라 연속 촬영 (60fps 우선) │                │   진동 알림    │
│  → Vision 인체 포즈 추정     │   스윙 종료     │   점수 92 · A  │
│  → 스윙 자동 감지 (상태 기계) │  ──────────▶  │  "템포 3.1:1   │
│  → 템포/스웨이/회전 분석     │  WatchConnect  │   아주 좋아요"  │
│  → 점수·피드백 생성          │                │               │
│  → 세션 영상 녹화 + 기록 저장 │  ◀──────────  │ 세션 시작/종료  │
└────────────────────────────┘    원격 제어    └───────────────┘
```

## 주요 기능

- **연속 촬영 & 자동 스윙 감지** — 버튼을 누를 필요 없이 어드레스 → 백스윙 → 톱 → 다운스윙 → 임팩트 → 피니시를 상태 기계로 자동 인식합니다. 왜글(연습 흔들기)은 걸러냅니다.
- **스윙마다 워치 피드백** — 점수(40~100)·등급(A~D)·핵심 코칭 한 줄이 워치에 도착하고, 점수대에 따라 다른 햅틱이 울립니다. 세션 중 골프 워크아웃을 자동 실행해 **손목을 내리고 있어도** 피드백을 받습니다.
- **음성 안내** — 화면을 안 봐도 되도록 스윙 직후 "87점. 템포가 빨라요" 식으로 읽어줍니다(끌 수 있음).
- **세션 영상 녹화** — 세션 전체를 한 파일로 녹화하고, 각 스윙의 구간(오프셋)을 기록해 두어 기록 화면에서 해당 스윙 구간부터 다시 볼 수 있습니다.
- **스윙 기록** — 세션별 목록, 스윙별 상세 지표, 평균 점수를 JSON으로 보관합니다.
- **워치에서 원격 제어** — 폰을 삼각대에 꽂아둔 채 워치에서 세션 시작/종료.

## 분석 지표

모든 길이는 "몸통 길이(목~골반)" 배수로 정규화되어 촬영 거리와 무관합니다. 기준값은 `SwingWatch/Analysis/SwingTuning.swift`와 `FeedbackEngine.swift`에서 조정할 수 있습니다.

| 지표 | 계산 방법 | 권장 기준 |
|---|---|---|
| 템포 | 백스윙 시간 : 다운스윙 시간 | 2.2~3.8 : 1 (이상적 3:1) |
| 머리 스웨이 | 임팩트까지 머리(코)의 좌우 이동 최대치 | 몸통의 22% 이하 |
| 골반 스웨이 | 백스윙 중 골반이 옆으로 밀린 최대치 | 몸통의 25% 이하 |
| 어깨 회전 | 백스윙 중 어깨 투영 폭 감소율 (정면 뷰 전용) | 38% 이상 감소 |
| 몸 일어남 | 임팩트 시 골반 높이 상승 (early extension 근사) | 몸통의 10% 이하 |
| 핸드 스피드 | 다운스윙 최대 손 속도 (상대 비교용) | — |

가장 감점이 큰 문제 하나를 골라 한국어 코칭 문구로 보여줍니다. 문제가 없으면 칭찬이 나옵니다.

## 요구 사항

- macOS + **Xcode 16 이상** (Xcode 26 대응 포함, 아래 참고)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen` (bootstrap 스크립트가 없으면 자동 설치)
- iPhone (iOS 17+), Apple Watch (watchOS 10+)
- Apple Developer 계정(무료 개인 팀으로 충분)

## 시작하기

```bash
git clone <이 저장소>
cd swingwatch
./Scripts/bootstrap.sh     # xcodeproj 생성 (+ Xcode 26이면 워치 임베드 자동 패치)
open SwingWatch.xcodeproj
```

1. **서명 설정**: `SwingWatch`, `SwingWatchWatch` 두 타깃 모두 Signing & Capabilities에서 팀을 선택하세요.
   - 번들 ID를 바꾸려면: iOS 타깃 ID 변경 후, 워치 타깃 ID는 반드시 `<iOS ID>.watchkitapp` 형태로 맞추고, `SwingWatchWatch/Info.plist`의 `WKCompanionAppBundleIdentifier`도 iOS ID로 함께 바꿔야 합니다.
2. **iPhone에 설치**: `SwingWatch` 스킴 + 내 iPhone 선택 후 실행. 워치 앱은 함께 설치됩니다(안 되면 iPhone의 Watch 앱 > 일반 > 앱 설치에서 스윙워치 설치).
3. **워치 권한**: 워치 앱 첫 세션 시작 시 워크아웃(헬스) 권한을 허용하면 손목을 내려도 햅틱이 옵니다.

### Xcode 26 참고

XcodeGen(2.46 기준)이 생성하는 "Embed Watch Content" 빌드 페이즈는 Xcode 26의 검증 규칙(워치 앱을 `PlugIns/`에 임베드)과 달라 설치가 실패합니다. `Scripts/bootstrap.sh`가 Xcode 버전을 감지해 자동으로 패치하므로 **항상 bootstrap 스크립트로 프로젝트를 생성하세요.** 수동으로 하려면:

```bash
/usr/bin/sed -i '' \
  -e 's|dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";|dstPath = "";|' \
  -e 's|dstSubfolderSpec = 16;|dstSubfolderSpec = 13;|' \
  SwingWatch.xcodeproj/project.pbxproj
```

## 연습장에서 쓰는 법

1. iPhone을 삼각대 등으로 세우고 **정면(페이스온)에서 2~4m** 거리를 권장합니다. 전신(발끝~머리)이 프레임에 들어와야 합니다.
   - 후방(다운더라인) 촬영도 동작하지만 어깨 회전 지표는 정면에서만 측정됩니다.
2. 폰 화면 또는 워치에서 **세션 시작**.
3. 평소처럼 스윙하면 끝. 스윙이 끝날 때마다 워치가 울리고 점수·피드백이 뜹니다.
4. 끝나면 **세션 종료**. 기록 화면(시계 아이콘)에서 스윙별 지표와 해당 구간 영상을 확인하세요.

> 배터리/발열: 연속 촬영 + 포즈 추정은 부하가 큽니다. 긴 연습은 보조 배터리와 그늘을 추천합니다.

## 프로젝트 구조

```
project.yml                     # XcodeGen 정의 (iOS 앱 / watchOS 앱 / 유닛 테스트)
Scripts/bootstrap.sh            # 프로젝트 생성 + Xcode 26 워치 임베드 패치
Shared/SwingFeedback.swift      # 폰↔워치 공용 모델·메시지 규약
SwingWatch/                     # iOS 앱
  App/                          #   앱 진입점, SessionCoordinator(파이프라인 허브), Info.plist
  Camera/CameraManager.swift    #   AVCaptureSession, 60fps 우선, 세로 회전/미러링
  Pose/                         #   PoseFrame 모델, Vision 포즈 추정
  Analysis/                     #   ★ 스윙 감지 상태 기계, 지표 계산, 점수/한국어 피드백
  Recording/SessionRecorder.swift #  세션 영상 AVAssetWriter 녹화
  Storage/                      #   스윙 기록 JSON 저장
  Connectivity/                 #   WatchConnectivity(폰 쪽)
  Speech/                       #   음성 안내
  Views/                        #   카메라 프리뷰, 스켈레톤 오버레이, HUD, 기록 화면
SwingWatchWatch/                # watchOS 앱
  WatchConnectivityManager.swift#   피드백 수신 + 햅틱 + 원격 제어
  WorkoutManager.swift          #   세션 중 골프 워크아웃 유지(손목 내려도 수신)
  Views/WatchRootView.swift     #   현재 피드백 / 기록 / 설정 3페이지
Tests/SwingLogicTests.swift     # 합성 포즈 시퀀스로 감지·분석·피드백 검증
```

### 동작 원리 (요약)

1. `CameraManager`가 세로로 회전된 프레임을 계속 공급하고, 세션 중에는 `SessionRecorder`가 같은 프레임을 영상 파일로 기록합니다.
2. `PoseEstimator`(Vision `VNDetectHumanBodyPoseRequest`)가 프레임당 관절 좌표를 뽑습니다. 처리 속도가 밀리면 프레임을 건너뛰어 실시간성을 유지합니다.
3. `SwingDetector`가 **손(양 손목 중점) 높이**를 몸통 길이로 정규화한 신호로 어드레스→백스윙→톱→다운스윙→임팩트→피니시를 판정합니다.
4. 스윙이 완성되면 `SwingAnalyzer`가 지표를 계산하고 `FeedbackEngine`이 점수·문구를 만듭니다.
5. 결과는 화면 배너 + 음성 + `WatchConnectivity`(실시간 실패 시 큐 전송 폴백) + JSON 기록으로 배달됩니다.

## 테스트

```bash
./Scripts/bootstrap.sh
xcodebuild test -project SwingWatch.xcodeproj -scheme SwingWatch \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

합성 스틱 피겨 시퀀스로 "풀스윙 1회 = 정확히 1회 감지", "왜글 무시", 지표 범위, 템포 피드백 문구를 검증합니다. GitHub Actions(`.github/workflows/build.yml`)에서도 같은 빌드·테스트가 돕니다.

## 한계와 다음 단계

- 2D 단일 카메라 포즈 추정이라 **클럽·볼은 추적하지 않으며**, 지표는 코칭 참고용 근사치입니다. 역광·어두운 곳에선 정확도가 떨어집니다.
- 스윙 감지는 풀스윙 기준으로 튜닝되어 있습니다(치핑/퍼팅은 감지되지 않을 수 있음).
- 아이디어: 클럽 헤드 경로 추적, 스윙 구간 자동 클립 내보내기, 세션 요약 리포트, 심박 기반 루틴 코칭, 지표 추세 그래프.

## 라이선스

[LICENSE](LICENSE) 참고.
