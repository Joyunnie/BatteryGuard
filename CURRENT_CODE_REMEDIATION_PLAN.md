# BatteryGuard 현재 코드 수정 계획

작성: 2026-10-04 · 기준: `main` `34663c7` (PR #39 병합 후) · 상태: 계획 수립, 구현 전

## 1. 목표와 판단 근거

최근 전체 코드 리뷰를 실제 결함 가능성과 수정 위험으로 다시 평가했다. `main`은 clean하며, 직전 전체 검증에서 XCTest 372개, strict-concurrency build-for-testing, Release build, Debug Analyze가 통과했다. 이 결과는 일반 경로의 회귀 위험을 낮추지만, 아래의 전원 연결 판단 불일치와 테스트 fixture 수명 문제를 반증하지는 않는다. 이 문서는 개인용 Apple Silicon Mac 한 대에서 쓰는 현재 앱을 대상으로 한다.

| 우선순위 | 확인된 코드 상태 | 판단 |
| --- | --- | --- |
| 높음 | `ChargeController+Operations.swift`의 Top Up, `ChargeController.swift`의 명시적 Maintain 복구 허용, `ChargeController+Reconciliation.swift`의 복구 pre/postflight가 `BatteryInfo.isPluggedIn`을 사용한다. `BatteryMonitor.resolvedPowerConnection`은 battery flag와 현재 IOPS를 결합한다. | 사용자 작업의 연결 판단이 UI의 paired observation과 달라질 수 있다. 수정한다. |
| 높음 | 임시 `Diagnostics.json`을 쓰는 일부 테스트가 controller/진단 작업을 종료·flush하기 전에 디렉터리를 삭제한다. 직전 전체 테스트에서 삭제된 파일로의 비동기 쓰기 오류가 관찰됐다. | 테스트 fixture 수명이 실제로 새고 있다. 수정한다. |
| 중간 | Settings 소유권 카드가 `isBatteryControlDisabled == false`이면 실패·수동 복구 상태에서도 “BatteryGuard가 충전 제어 중”이라고 표시한다. | 소유권과 정상 제어를 혼동시키는 문구다. 표시를 보정한다. |
| 검증 후 결정 | `statusCommandTimeout = 2`는 runner의 실행·TERM/KILL·회수를 포함한 총 예산이다. `terminationDeadlines`는 그중 최대 1초를 정리에 예약한다. | 의도된 총 시간 상한이다. 정상 status 지연 분포와 1.2–1.8초 fixture 결과 없이 runner를 바꾸지 않는다. |
| 낮음 | sleep completion 진단은 request ID를 상세 필드에 넣지만 최상위 `operationID`는 비워 둔다. | 관찰성의 작은 결손이다. 함께 수정한다. |
| 선택 | 일부 sleep/wake 테스트가 고정 지연으로 순서를 만든다. | 실기기 결함의 증거는 아니다. 핵심 역방향 경합 테스트만 명시적 barrier로 보강한다. |

## 2. 실행 순서와 PR 경계

### PR 1 — 현재 전원 연결 증거를 제어 작업에 사용

1. `BatteryMonitor`에 **현재 paired battery/IOPS 읽기**를 제어 작업이 사용할 수 있는 작은 API로 제공한다. 반환값은 같은 read의 `BatteryInfo`와 연결 판정이어야 한다. 마지막 IOPS source, 이전 `.stable` 값, `BatteryInfo.isPluggedIn` 단독 값은 현재 연결의 대체 증거로 사용하지 않는다. 기존 presentation settlement와 generation을 우회하거나 monitoring infrastructure를 새로 시작하지 않는다.
2. 새 edge의 settlement가 진행 중이거나 현재 pair가 불완전하면 결과를 `transitioning`/`uncertain`으로 다룬다. 즉시 성공을 추정하지 않는다. 사용자가 다시 시도할 수 있도록 거부 사유는 구체적으로 표시한다.
3. `startTopUp`, `explicitMaintainRecoveryAvailability`, 명시적 Maintain 복구의 fresh preflight 및 postflight를 이 API로 통일한다. Top Up에는 같은 pair의 배터리 충전량도 필요하다. Postflight에서 연결이 불명확하거나 끊기면 기존 안전 rollback과 verified failure 경로를 유지한다.
4. `BatteryInfo`만 즉시 게시하는 Heat Protection 안전 refresh는 기존대로 connection settlement와 분리한다. CLI status tuple 검증, Heat 우선권, 작업 generation 재검증, sleep/wake 정책은 변경하지 않는다.
5. fake monitor에 battery flag와 IOPS source를 독립적으로 주입한다. 최소 테스트: flag unknown + IOPS AC 허용; flag connected + IOPS battery는 기존 `resolvedPowerConnection` 정책에 맞게 판정; 두 소스 모두 연결을 증명하지 못함/읽기 실패/settlement 중에는 작업 거부; 전원 제거가 복구 postflight에 끼어들면 성공 모드로 표시하지 않음. Top Up과 수동 복구 각각 명령 로그와 최종 mode를 검증한다.

**병합 조건:** UI가 연결됐다고 확정하는 동일한 최신 pair에서만 AC 필요 작업을 허용한다. 연결을 확정할 수 없는 경우 새 충전 명령을 발행하지 않는다. 테스트는 실제 CLI를 실행하지 않는다.

### PR 2 — 테스트 자원 수명과 핵심 경합 테스트

1. `ChargeControllerHeatProtectionTests`, `SleepChargingProtectionTests` 등 파일 진단 로그를 쓰는 fixture를 모두 점검한다. 비동기 controller 작업을 끝내거나 취소한 다음 `DiagnosticLog.flushPendingEvents()`를 기다리고 임시 디렉터리를 지운다. `recentEvents()` 조회만으로 submission queue drain을 가정하지 않는다.
2. 삭제 뒤 late submission이 남지 않는지 관련 테스트를 반복 실행한다. 실제 프로덕션 진단 로그는 테스트에서 사용하지 않는다.
3. 현재 고정 sleep에 의존하는 핵심 역방향 경합만 `entered`/`release` barrier가 있는 fake backend로 바꾼다: Wake 중 재Sleep, Sleep cleanup 중 Wake, Heat block 중 Maintain 복원, 종료 중 owned Top Up/Discharge 정리. 각 테스트는 preemption 지점에 실제로 도달했음을 확인한 뒤 새 intent를 보낸다.
4. 최종 `ChargeMode`, 명령 순서, complete status tuple, exact Maintain worker, assertion/오류 상태를 해당 시나리오에 필요한 만큼 검증한다. 모든 `eventually` 사용을 기계적으로 제거하지 않는다.

**병합 조건:** 임시 진단 파일 삭제 뒤 write 오류가 없고, 핵심 interleaving이 스케줄러 속도에 의존하지 않는다.

### PR 3 — Settings의 제어 상태와 sleep 진단 표시

1. `BatteryPresentation`이 persisted ownership, `ChargeMode`, readiness를 입력받아 Settings 소유권 카드에 필요한 문구·색·아이콘을 순수하게 계산하도록 한다. `batteryGuard` 소유권을 보유하더라도 `.failed`, manual recovery, external drift, 전환 중인 상태를 “정상 제어 중”으로 표시하지 않는다. `system` ownership일 때 native Charge Limit가 실제로 켜져 있다고 추정하지 않는다.
2. Settings의 버튼 가능 여부는 기존 controller 안전 조건을 유지한다. 정상, 실패, drift, releasing, monitoring-only의 렌더링 결과를 테스트한다.
3. `handleSystemSleepCompletion`의 진단 이벤트에 해당 request ID를 최상위 `operationID`로 넣고, 같은 sleep request의 lifecycle 이벤트 correlation을 테스트한다. 진단 schema는 변경하지 않는다.
4. `LIFECYCLE_RACE_PREVENTION_PLAN.md`의 PR #39 병합 상태와 현재 하드웨어 검증 범위를 갱신한다. 과거 원자료는 그대로 두고, PR #39 이후 자동 검증과 실기기 검증을 구분한다.

**병합 조건:** Settings가 소유권과 verified control 상태를 혼동하지 않고, 같은 sleep 요청의 진단 이벤트를 operation ID로 연결할 수 있다.

### PR 4 — timeout 계약 측정과 필요한 경우에만 수정

1. 임시 실행 파일이 `status_csv` 호출 후 1.2초, 1.5초, 1.8초에 정상 종료하는 테스트를 추가한다. 현재 2초 설정에서 실제 종료 시점, 반환 종류, 자식·프로세스 그룹 회수를 기록한다. 지연·TERM 무시 fixture도 전체 상한과 cleanup failure를 검증한다.
2. 앱의 기존 진단 기록이나 통제된 read-only 측정으로 실제 `status_csv` 지연 분포를 확인한다. 상태 조회 횟수와 측정 조건을 함께 남긴다. 새 하드웨어 mutation은 측정을 위해 실행하지 않는다.
3. 정상적인 status 호출이 약 1초를 넘어서 잘리는 증거가 있으면 execution budget과 cleanup budget을 별도 이름으로 모델링하고, 각 호출처의 전체 deadline(특히 sleep acknowledgement)을 보존한다. 재시도 횟수나 전체 deadline을 근거 없이 늘리지 않는다.
4. 그런 증거가 없으면 runner 동작은 유지하고 `statusCommandTimeout`의 총 예산 의미를 이름/주석/테스트에서 명확히 한다.

**병합 조건:** 정상 응답 허용 시간과 총 회수 상한이 테스트로 구분되고, timeout 뒤 자식 또는 descendant가 남지 않는다. 결과가 측정 전 가설과 다르면 코드 변경 범위를 축소한다.

## 3. 검증과 중단 기준

- 각 PR에서 해당 fake backend/fixture 테스트를 먼저 실행한다. 전원 연결 테스트는 source read 실패, edge 전환, stale flag 조합을 포함한다.
- 마지막 코드 PR 뒤 전체 XCTest, `SWIFT_STRICT_CONCURRENCY=complete` + `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` build-for-testing, Release build, Debug Analyze를 실행한다. 기본 테스트는 실제 battery CLI·로그인 항목·운영 Core Data store를 건드리지 않는다.
- 실제 Mac에서의 충전 제어·sleep/wake 검증은 자동 테스트와 별도 단계로 기록한다. 시작/종료 CLI tuple, exact worker/PID identity, 충전기 상태, 시각, 진단 operation ID를 보존하고 의도한 Maintain 상태로 복원한다. 하드웨어 검증을 하지 못했다면 완료 기록에 그대로 남긴다.
- 새로운 API가 settlement를 생략해 과거 값을 성공으로 사용하는 경우, 복구 pre/postflight가 stale `BatteryInfo`를 쓰는 경우, 실패 상태를 정상 제어로 표시하는 경우, 또는 timeout 정리 후 descendant가 남는 경우 병합하지 않는다.

## 4. 현재 범위 밖

단일 `ControlOperationLease` 도입, runner/SMCKit의 파일 분할, Core Data queue 이전, 새 snapshot epoch 체계, installer·배포 자동화는 이번 결함의 직접 수정 조건이 아니다. 새 lifecycle 결함이 재현되거나 프로파일링에서 UI stall이 확인될 때 별도 증거와 계획으로 다룬다.
