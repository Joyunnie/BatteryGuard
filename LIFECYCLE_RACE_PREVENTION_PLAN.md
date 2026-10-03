# BatteryGuard 비동기 제어 경합 재발 방지 계획

작성: 2026-10-03 · 기준: `main` (`9c00130`, PR #41 병합 후) · 갱신: 2026-10-04 · 상태: PR #39·#40·#41 병합 및 자동 검증 완료, 최신 실기기 검증 대기

> 아래 기존 실기기 원자료는 PR #40·#41 이전에 수집되었으므로 최신 코드의 Sleep/Wake 행동을 입증하지 않는다.

## 1. 목적과 현재 코드에서 확인한 원인

목표는 특정 Sleep/Wake 오류 메시지만 지우는 것이 아니라, 이전 비동기 작업이 새로운 안전 의도 뒤에 하드웨어 명령을 실행하거나 측정값·상태·오류를 반영하는 **결함 종류**를 제거하는 것이다. 모든 외부 CLI 장애에서 무인 복구를 보장하지는 않는다. 현재 하드웨어 상태나 소유권을 검증할 수 없으면 충전을 재개하지 않고 사용자가 판단할 수 있는 상태로 남겨야 한다.

현재 `ChargeMode`는 이미 단일 enum이고 `SMCKit`/`BatteryCommandRunner`는 제어 명령을 직렬화한다. 따라서 앱·runner 전면 재작성이나 새 daemon은 필요하지 않다. 빠진 부분은 `ChargeController`의 **작업 소유권과 결과 반영 규칙**이다.

| 확인된 지점 | 현재 동작 | 위험 |
| --- | --- | --- |
| `ChargeController+SleepWake.swift:54-63, 89-122` | 새 Sleep은 `sleepPreparationGeneration`만 증가시키고, 이미 보호 중이면 읽기 전용 검증을 시작한다. | 진행 중인 Wake 복원은 무효화되지 않는다. |
| `ChargeController+SleepWake.swift:234-321, 407-497` | Wake는 `operationGeneration`/`activeOperationID`를 쓰지만 소유 Task를 `activeOperationTask`에 저장하지 않는다. | Wake→재Sleep에서 새 Maintain worker가 Sleep 검증 중 생길 수 있다. |
| `ChargeController+HeatProtection.swift:18-59` | `readFreshSafetyTemperature()`는 `await` 뒤 반환 전에 캐시, `monitor.batteryInfo`, 센서 오류, 표시 온도를 변경한다. | 호출자가 뒤늦게 stale 결과를 버려도 이미 상태가 바뀌었다. |
| `ChargeController.swift:331-346, 499-505`; `ChargeController+SleepWake.swift:304-321` | 모든 명령 오류가 한 `command` 슬롯을 쓰며 임의의 명령 성공은 그 슬롯을 지운다. Wake 성공은 일부 경로에서 이전 오류를 지우지 않는다. | 실제로 해결된 오류가 남거나, 해결되지 않은 오류가 사라진다. |
| `BatteryMonitor.swift:17, 235`; `ChargeController.swift:184-204` | `IsCharging` 누락/파싱 실패가 `false`가 된다. | 충전 활동이 불명인데 UI는 충전 중지가 확인된 것처럼 보일 수 있다. |
| `BatteryHistory.swift:109, 225-266` | store 로딩 중 기록은 원래 시각 없이 보관한 뒤 로드 시각에 재생한다. | 시작 직후 이력 시각이 틀어지고 이벤트가 합쳐질 수 있다. |
| `BatteryHistoryTests.swift:261-278` | 살아 있는 SQLite store 경로를 테스트 종료 시 삭제한다. | 테스트가 통과해도 SQLite가 open file 삭제 경고를 출력한다. |

기존 테스트는 Sleep→Wake, 타임아웃 정리→Wake, Wake 중 종료 등 여러 단방향 시나리오를 다룬다. **Wake 복원 진행 중 새 Sleep**과 stale 온도 읽기의 **캐시·UI 불변성**, Sleep/Wake 성공 뒤 **오류 해제**는 검증하지 않는다. 이전 `AUTOMATIC_RECOVERY_REMEDIATION_PLAN.md`의 bounded status retry와 최종 tuple 재검증은 유지한다. 이 계획은 그 위에 부족한 작업 소유권 경계를 추가한다.

## 2. 설계 불변식

1. 충전 제어를 바꿀 수 있는 작업은 `ChargeController` 안에서 하나의 활성 소유권을 갖는다. Sleep, Wake, Heat Protection, 사용자 명령, 소유권 해제, 종료가 이 규칙을 공유한다. IOKit 요청 ID와 sensor sampling generation은 별도 목적을 유지한다.
2. 새 안전 의도가 이전 작업을 대체하면, 이전 작업의 Swift Task와 backend command를 취소하고 **runner가 정지·정리됐는지 확인한 뒤** 새 mutation을 시작한다. `Task.cancel()`만으로 하드웨어 정지가 증명되지는 않는다.
3. 각 `await` 뒤, 특히 mutation 직전과 검증 결과 반영 직전에 소유권 token, 설정 ownership, 기대 mode, 취소 여부를 확인한다. 상태 반영은 동일 token의 마지막 검증 tuple을 기반으로 한다.
4. 새로운 Sleep 요청이 Wake의 진행을 무효화한 후에는 Wake가 Maintain을 재생성할 수 없다. Sleep은 남은 acknowledgement 기한 안에서 기존 작업 정리와 charging-off tuple을 확인한다. 기한 내 확인이 안 되면 vetoable sleep은 거부하고 forced sleep은 허용하되 불확실한 상태를 명시한다. 무한 대기나 deadline 연장은 없다.
5. Heat Protection의 충전 차단은 일반 Wake/사용자 복원보다 우선한다. 외부 drift와 소유권 release는 자동 Maintain 재적용으로 덮지 않는다. 불명확한 worker, process cleanup 실패, status 실패는 성공으로 처리하지 않는다.
6. 읽기 결과는 먼저 불변값으로 만든다. 현재 소유자가 검증된 후에만 `mode`, 센서 캐시, `BatteryInfo`, LED intent, history, 오류를 반영한다. LED는 기존 generation actor, history는 기존 Core Data 구성을 유지한다.
7. 오류는 발생시킨 작업 또는 관측 조건에 묶인다. 다른 작업의 성공이 안전 오류를 지울 수 없고, 해당 실패 조건이 실제로 해소되면 오류와 UI가 함께 갱신된다.
8. 기본 자동 테스트는 fake backend, 격리 defaults, in-memory store, disabled diagnostics를 사용한다. 저장소 파일 자체를 시험할 때만 독립 임시 store를 쓰고 종료 후 닫는다. 실제 CLI, 로그인 항목, 운영 store는 만지지 않는다.

## 3. 실행 순서와 PR 경계

### PR 1 — 제어 작업 소유권과 Sleep/Wake 역전 경합 (최우선, 병합 차단)

- 현재 `activeOperationID`, `activeOperationTask`, `operationGeneration`, `sleepPreparationGeneration`의 역할을 표로 고정한다. Semantic operation UUID는 진단 연결용으로 유지한다.
- `ChargeController` 내부에 하나의 **control-operation lease**를 둔다. Lease에는 generation, semantic operation ID, kind, owning Task, expected mode/ownership, cancellation/settlement 상태를 둔다. 별도 범용 프레임워크나 actor를 추가하지 않는다. 기존 `runBattery`, Sleep, Wake, shutdown의 시작·대체·완료를 이 경계로 모은다.
- Wake 복원을 반드시 소유 Task로 추적한다. Sleep 시작은 첫 `await` 전에 Wake lease를 무효화하고 Task를 취소한다. backend cancellation/runner quiescence를 기한 안에 확인한 뒤 Sleep 전이를 결정한다. `verifyAlreadyProtected`도 Wake가 여전히 진행 중인지 확인 없이 시작하지 않는다.
- 취소를 무시한 작업이 늦게 끝나면 반환값과 UI commit을 버린다. 이미 실행된 mutation이 있을 수 있으므로 새 소유자가 fresh complete tuple을 읽어 판단한다. runner terminal failure면 추가 명령을 차단하고 수동 복구 상태를 남긴다.
- `shutdown`의 이미 확보한 lifecycle 우선권과 durable ownership commit 경계를 유지한다. Sleep/Heat/Discharge assertion/forced sleep의 기존 정책을 회귀시키지 않는다.
- 먼저 실패하는 deterministic fake-backend 테스트를 작성한다: Wake status read 중 재Sleep, Wake temperature read 중 재Sleep, Wake `applyMaintain` 중 재Sleep, 연속 poweredOn 알림, Sleep↔shutdown, Heat block↔Wake. 명령 순서·최종 tuple·exact worker 수·mode·readiness·오류를 모두 검증한다. 실제 시간에 기대지 않는 latch/continuation을 사용한다.

**승인 조건:** 각 전이에서 최신 소유자만 mutation과 상태 commit을 수행한다. Wake→재Sleep에서 Maintain worker가 Sleep 검증 뒤에 생기지 않는다. Quiescence를 못 증명한 경우 정상/복구 성공으로 표시하지 않는다.

### PR 2 — 온도 읽기와 안전 상태 반영 분리 (병합 차단)

- `readFreshSafetyTemperature()`가 SMC·IOKit의 원자료, 실패, 시각, freshness만 담은 값으로 반환하도록 바꾼다. 함수 안에서 캐시, `monitor.batteryInfo`, `safetyTemperatureSnapshot`, 센서 오류를 변경하지 않는다.
- 현재 control lease 또는 독립 SMC sampler generation을 검사한 뒤 하나의 commit 함수가 결과를 반영한다. Safety decision에는 해당 작업의 fresh sample을 직접 사용하고, 오래된 cache나 다른 작업이 publish한 값으로 충전 재개를 승인하지 않는다.
- 호출처인 초기화, Wake, manual recovery, Heat restore, read-only reconciliation을 순차적으로 바꾼다. 각 호출처가 await 후 설정 ownership, generation, expected mode를 다시 확인한다. 마지막 status tuple과 필요 시 temperature postflight 확인은 유지한다.
- 취소를 무시하는 fake SMC read가 Sleep, shutdown, 소유권 release, Heat 재설정 이후 완료되어도 캐시·UI·오류·`BatteryInfo`와 하드웨어 명령이 변하지 않는 테스트를 추가한다.

**승인 조건:** stale sensor completion은 어떤 공유 상태도 변경하지 않는다. 독립 센서 실패가 있는 동안 Heat 복원은 계속 금지된다.

### PR 3 — 오류의 발생 원인과 해제 조건 명시 (병합 차단)

- `BatteryIssue`에 typed origin과 해당 semantic operation ID 또는 관측 generation을 연결한다. 기존 severity/source 정렬은 유지하되, `command`라는 단일 문자열 슬롯을 모든 작업이 공유하지 않게 한다.
- `record/resolve` API를 두고 Sleep 실패, Wake 실패, 수동 복구, Heat, drift, LED 각각에 해제 조건을 정의한다. Wake 성공은 자신의 Wake 오류만 지우고 UI issue projection을 즉시 갱신한다. 다른 명령의 성공은 이전 안전 오류를 지우지 않는다.
- 같은 증상의 반복은 중복 표시를 만들지 않되 최신 오류 원인과 시각을 보존한다. 진단 event ID/operation ID와 UI issue ID를 혼동하지 않는다. 기존 디스크 진단 schema는 변경할 필요가 없으면 그대로 둔다.
- 실패→verified recovery, 실패→unrelated success, 실패→external drift, 연속 Wake/재Sleep, stale task completion에서 UI issue 목록·우선순위·해제를 검증한다.

**승인 조건:** 성공 후 해결된 오류가 남지 않고, 검증되지 않은 안전 실패가 다른 명령으로 사라지지 않는다.

### PR 4 — 측정값의 `unknown` 보존 (독립 정확도 수정)

- `IsCharging`이 없거나 잘못된 형식이면 `unknown`으로 유지한다. `ChargingActivity` 같은 작은 enum 또는 optional로 모델링하고 `ControlMeasurement`, `BatteryPresentation`, menu/Dashboard/Settings를 같은 projection으로 연결한다.
- 물리적 연결 evidence, 제공 전원, 충전 활동, verified CLI policy를 혼합하지 않는다. IOPS AC는 연결을 확인할 수 있지만 충전 활동을 추정하지 않는다. unknown을 `충전 일시정지`나 `충전 중`으로 확정 표시하지 않는다.
- 누락·잘못된 타입·상충하는 flag/전류·IOPS edge·Top Up/Discharge override의 UI 테스트를 추가한다. 전체 `BatteryInfo` 생성 위치를 컴파일러로 확인해 빠진 화면이 없게 한다.

**승인 조건:** 누락값이 false/0과 같은 그럴듯한 측정값으로 보이지 않는다. verified CLI tuple 판단은 계속 CLI 상태만 사용한다.

### PR 5 — 이력 시각과 테스트 자원 수명 (독립 데이터 수정)

- Core Data load 중 pending record에 **수집 당시 시각**을 저장하고 같은 시각으로 재생한다. 기존 256개 상한과 7일 retention을 유지한다. 필요하면 오래된 중복 sample은 명시적인 기록 정책으로 제거하되 시각을 load 완료 시각으로 바꾸지 않는다.
- fixture store를 닫은 뒤 임시 디렉터리를 삭제하고, 테스트 진단 queue는 flush 후 정리한다. SQLite `vnode unlinked while in use`와 삭제된 `Diagnostics.json` 쓰기 경고가 없도록 한다.
- 가짜 시계로 여러 pending event의 순서·시각·dedupe, load 실패→retry, teardown 후 비동기 write 없음 테스트를 추가한다.

**승인 조건:** 첫 실행 구간의 이력이 실제 수집 시각을 보존하고 테스트 실행에 SQLite integrity 경고가 없다.

## 4. 재발 방지 검증 체계

각 PR의 변경 전 실패 테스트를 먼저 확인하고 변경 후 같은 테스트를 통과시킨다. 특히 상태 머신의 새 `await` 또는 새 control mutation을 추가하는 PR에는 아래 두 방향을 함께 검토한다.

| 이벤트 A 진행 중 이벤트 B | 최소 확인 사항 |
| --- | --- |
| Sleep→Wake, Wake→Sleep, Wake→Wake | 이전 작업 취소·정리, 최신 상태·오류, worker/charging tuple |
| Heat block↔Wake/복원/사용자 명령 | Heat 우선, 독립 센서 freshness, 충전 재개 전 검증 |
| Top Up/Discharge↔Sleep/종료/worker exit | owned process, Maintain 복원 정책, sleep assertion |
| Release↔Wake/종료/앱 재실행 | durable ownership journal, 자동 재소유 금지 |
| status/온도 await↔새 의도/종료 | 늦은 완료의 공유 상태 변경 0회 |
| 정상 회복↔오류 표시 | 자신의 오류만 해제, 남은 문제는 계속 표시 |

Fake backend는 각 `await` 지점에서 멈추고 순서를 바꿀 수 있어야 하며, cancellation을 존중하는 경우와 무시하는 경우를 모두 제공한다. 테스트는 `mode` 하나만 보지 않고 backend operation log, complete CLI tuple, worker liveness, readiness, sleep assertion, sensor cache, `BatteryInfo`, issue list, diagnostics correlation을 확인한다. 실패한 진단 시나리오에는 같은 semantic operation ID와 superseded outcome이 남아야 한다.

자동 검증: 격리된 targeted XCTest → 전체 XCTest의 side-effect 격리 확인 → strict-concurrency warnings-as-errors build-for-testing → Release build → Debug Analyze. `xcodebuild analyze`나 컴파일 성공은 순서 경합의 증명이 아니므로 deterministic interleaving 테스트를 별도 필수 게이트로 둔다. 분석 실행 직후 `test-without-building`을 쓸 때는 테스트 번들이 제거될 수 있으므로 다시 `build-for-testing`한다.

실제 Mac 검증은 별도 승인된 통제 단계에서 수행한다. 시작·종료 상태를 Maintain 80%, non-discharge, exact worker 1개와 PID identity 일치로 기록한다. 빠른 Sleep/Wake/재Sleep, lid close 직후 재open, AC 연결 상태 변화, Heat 보호, 앱 종료를 순서대로 시험하고 각 단계의 원자료와 semantic operation ID를 보존한다. 테스트가 끝나면 의도한 Maintain 상태로 복원하고 확인한다. 하드웨어 검증 전에는 실제 Mac에서 경합이 완전히 해결됐다고 선언하지 않는다.

## 5. 범위와 완료 기준

- 기존 `ChargeMode`, backend protocol, command runner, worker identity 검증, durable ownership journal, notification 기반 모니터링을 재사용한다. 전역 polling 증가, 새로운 daemon/privileged helper, UI 전면 개편, 배포 자동화는 포함하지 않는다.
- PR 1~3은 충전 제어 안전성과 오류 신뢰성 때문에 우선 병합한다. PR 4와 PR 5는 서로 독립적으로 병합할 수 있다. 모든 PR은 직전 `main` 기준의 고유 diff와 자신에게 필요한 회귀 테스트를 갖는다.
- 완료 조건은 “경합 상황에서 최신 소유자만 명령과 상태를 반영한다”, “실패와 회복이 실제 검증 결과대로 UI에 보인다”, “불명확한 하드웨어 상태에서 자동 충전 재개가 없다”, “누락 측정값과 이력 시간이 사실대로 표시된다”, “기본 테스트가 실제 시스템을 변경하지 않고 자원 누수 경고도 남기지 않는다”이다.
- CLI 자체가 지속적으로 응답하지 않거나 worker identity/소유권을 확정할 수 없으면 자동 복구를 중단한다. 이 경우 필요한 사용자 개입은 안전 경계이며 버그로 숨기지 않는다.

병합 거부 조건: timeout이나 retry 횟수만 늘림; `Task.cancel()`만으로 작업 정리를 가정함; `await` 뒤 무효 token의 결과를 publish함; partial tuple 또는 stale worker를 성공으로 인정함; Heat 보호를 우회함; 다른 명령이 안전 오류를 지움; 가짜 백엔드 테스트가 실제 배터리 CLI·로그인 항목·운영 store를 사용함; 역방향 경합 테스트 없이 단순 정상 경로만 통과함.

## 6. 실행 기록 (2026-10-04)

- PR 1의 별도 lease 구조체는 도입하지 않았다. 기존 `operationGeneration`/`activeOperationID`를 mutation 소유권으로 유지하고 Wake에 generation과 소유 Task를 추가했다. 재Sleep은 첫 await 전에 Wake를 취소·무효화하고, backend의 bounded cancellation/charging-off 검증을 거친다. 이는 새 병렬 소유권 체계를 만드는 것보다 기존 runner와 같은 안전 경계를 사용한다. Wake 온도 읽기 중 재Sleep, Maintain 시작 중 재Sleep, 수동 복구 실패 관측 중 재Sleep의 회귀 테스트를 추가했다.
- PR 2는 fresh 온도 읽기를 불변 결과로 만들고, 호출처가 현재 작업·취소·소유권을 검증한 뒤 캐시·`BatteryInfo`·UI 오류를 commit하도록 바꿨다. stale 읽기의 공유 상태 불변성을 테스트한다. 현재 IOKit 읽기가 실패하면 이전 `fallbackInfo`는 표시용으로만 남기고 자동 충전 재개 승인은 거부한다.
- PR 3은 오류를 typed origin, semantic operation ID 또는 관측 generation으로 구분한다. Sleep·Wake·Heat·수동 복구·일반 명령의 성공은 자신의 오류만 해제하며, 완전한 tuple을 검증한 명시적 복구만 제어 실패 전체를 해제한다.
- PR 4는 `IsCharging` 누락/비정상 값을 `nil`로 보존하고 연결 상태와 분리하여 불명으로 표시한다. PR 5는 pending 이력의 수집 시각을 저장하고, SQLite fixture와 진단 queue를 닫거나 flush한 뒤 삭제한다.
- 자동 검증: PR #39에서 전체 XCTest 372개가 통과했고, PR #40·#41 병합 후 374개가 통과했다. strict-concurrency warnings-as-errors build-for-testing, Release build, Debug Analyze도 통과했다. 검증은 fake backend·격리 store·defaults를 사용했고 실제 CLI 명령은 실행하지 않았다. PR #41은 핵심 역방향 경합을 명시적 backend barrier로 전환했다.
- **남은 게이트:** 리뷰 가능한 PR 경계와 PR #39의 병합은 완료됐다. 최신 `main` 기준의 별도 통제된 실제 Mac Sleep/Wake 검증과 종료 상태 복원은 아직 남았다. 자동 테스트 통과만으로 실기기 충전 제어 경합이 완전히 해결됐다고 선언하지 않는다.
