# BatteryGuard 개선 계획

## 0. 2026-08-05 실행 순서와 결과

이 절은 기존 전체 계획을 대체하지 않는다. Phase 1·2 PR 재검토에서 확인된 blocking 항목을 실제 적용한 순서, 검증 조건과 결과를 기록한다.

### 0.1 실행 순서

1. 앱 종료 중 Top Up/Discharge를 취소하고 시작 시 기록한 maintain limit를 복원한다. 복원은 level 일치, discharge 해제와 maintain worker 생존을 모두 확인해야 성공이다.
2. `status_csv` tracker 값만 신뢰하지 않고 PID 파일과 실제 프로세스 명령행을 대조한다. worker가 없거나 stale이거나 둘 이상이면 maintain 상태를 실패로 취급한다.
3. `BatteryCommandRunner.Command`에 `requireProcessGroupExit`와 `allowPersistentProcessGroup` descendant policy를 명시한다. stdout/stderr는 제한된 buffer로 drain하고 parent 종료 후 pipe를 물려받은 자식 때문에 무기한 대기하지 않는다. timeout은 spawn 이전부터 결과 capture까지 monotonic deadline으로 제한하며 정리 대기도 유한하게 유지한다.
4. privileged CLI preflight를 초기화 첫 동작으로 이동한다. production에서는 고정 절대 경로, regular file/directory, symlink 거부, root:wheel owner, group/other write 금지, 실행 권한과 최소 v1.3.4를 확인한다. fixture test만 완화된 별도 policy를 사용한다.
5. readiness를 `initializing -> reconciling -> establishingControl -> ready/failed`의 완전한 async initialization 상태로 바꾼다. backend open, 실제 status, IOKit 측정, fresh temperature와 최초 verified control이 끝나기 전에는 UI 제어를 열지 않는다.
6. `ChargeMode` 하나를 충전 제어 상태의 원본으로 사용한다. Maintain, Top Up, Discharge, Heat Block, transition과 failure를 상호 배타적으로 표현하고 기존 Boolean은 모두 파생값으로 바꾼다.
7. Heat Protection을 상태 머신 전이로 재작성한다. 진입은 long operation과 maintain worker를 정리한 뒤 verified charging-off를 요구한다. 복원은 fresh preflight/postflight temperature를 모두 확인하며 실패 시 다시 charging-off를 적용하고 blocked 상태를 유지한다.
8. MagSafe LED를 generation을 비교하는 actor와 단일 worker task로 바꾼다. solid, blink, restore 요청은 한 작업에서 순서대로 실행하고 오래된 generation의 오류/완료가 최신 intent를 바꾸지 못하게 한다.
9. 종료 복구, dead/duplicate maintain worker, descendant policy, bounded output, preflight, async readiness, Heat Protection postflight re-block와 LED generation 역전 테스트를 추가한다. `BatteryMonitor`, `BatteryHistory`, `UserSettings`의 main-actor 경계를 명시하고 strict-concurrency complete 빌드를 경고 오류화로 통과시킨다.
10. 자동 검증 통과 후에만 실제 하드웨어 체크리스트를 수행한다. 모든 변경 전후에 `status_csv`, PID 파일, 실제 worker 명령행과 `pmset -g batt`를 기록하고 최종 maintain 80을 복원한다.
11. 기존 unrelated history를 force-push로 다시 쓰지 않는다. `baseline/import` PR은 원래 프로젝트 tree를 `main`에 연결하고, Phase 1·2 PR은 그 baseline을 base로 하여 안전 리팩터링 diff만 보여주도록 분리한다.

### 0.2 자동 검증 결과

- Debug 테스트: 51개, 실패 0개.
- strict concurrency: `SWIFT_STRICT_CONCURRENCY=complete`와 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`로 build/test 통과.
- 테스트 host는 실제 CLI, 로그인 항목과 운영 Core Data store를 초기화하지 않는다.
- fixture executable만으로 timeout, cancellation, process-group cleanup, persistent descendant와 bounded stdout/stderr를 검증했다.
- production preflight가 고정 경로가 아닌 executable을 hardware command 전에 거부하는 테스트를 추가했다.

### 0.3 실제 하드웨어 체크 기록

시작 기준은 battery CLI v1.3.4, 80%, AC attached, charging disabled, not discharging, maintain 80이었다.

| 검사 | 수행 내용 | 결과 |
|---|---|---|
| production preflight/initialize | root:wheel 755 directory, battery, smc 확인 후 새 Debug 앱 실행 | 통과 |
| 정상 quit | maintain 중 앱 정상 종료 | 동일 worker 생존, maintain 80 유지 |
| Top Up 중 quit | UI에서 Top Up 시작, `charging=enabled` 확인 후 정상 종료 | Top Up 취소, charging disabled, not discharging, maintain 80 복원 |
| Discharge 중 quit | limit를 75로 임시 변경, UI와 `discharging` 확인 후 정상 종료 | discharge 종료, maintain 75 복원 후 UI에서 maintain 80으로 원복 |
| duplicate worker | 초기 실기 실행에서 CLI의 지연된 signal 처리 때문에 3개 worker가 관찰됨 | 검증을 exact-one으로 강화하고 오래된 exact worker만 정리; 재실행 후 항상 한 worker만 확인 |
| Heat Protection 진입 | threshold를 40°C에서 30°C로 임시 변경 | 최초 실행에서 worker가 남는 결함 발견; `disableCharging` 전에 exact maintain worker 정리를 추가한 뒤 worker 0, 보호 UI 확인 |
| Heat Protection 복원 | threshold를 30°C에서 40°C로 복원 | maintain 80 worker 정확히 하나 복원 |
| crash reconciliation | 앱 PID만 SIGKILL, maintain worker 생존 확인 후 재실행 | 기존 worker를 재시작하지 않고 actual state reconciliation 통과 |
| sleep/wake | 현재 개발 세션을 중단하므로 수행하지 않음 | fake backend wake reconciliation 테스트로만 검증; 별도 수동 확인 필요 |
| Terminal drift | 주기적 external drift reconciliation이 후속 범위라 변경 실행하지 않음 | 후속 단계에서 구현 후 수동 확인 필요 |

최종 복원 상태는 80%, AC attached, charging disabled, not discharging, maintain 80, PID 파일과 일치하는 worker 정확히 하나이며 BatteryGuard 앱은 종료된 상태다.

### 0.4 이 실행으로 바뀐 후속 계획

- CLI preflight는 기존 3.6까지 기다리지 않고 모든 hardware command보다 먼저 실행하도록 완료했다. 3.6에는 macOS native Charge Limit 충돌 감지와 사용자 안내만 남는다.
- readiness 최소 gate가 아니라 전체 async initialization을 완료했다. 이후 UI 개선은 `ChargeControllerReadiness`를 파생 표시해야 한다.
- single `ChargeMode`, lifecycle, Heat Protection, Top Up/Discharge와 LED 재작성은 함께 완료됐다. 이후 새 기능은 Boolean 상태를 다시 추가하지 않고 이 상태 머신에 전이를 추가해야 한다.
- monitor/history 정확성, 로컬 순환 진단 로그, native Charge Limit 충돌, periodic Terminal drift reconciliation과 별도 disable-control UX는 아직 후속 범위다.
- hardware checklist의 sleep/wake와 Terminal drift 항목은 해당 후속 구현 뒤 다시 수행한다.

### 0.5 PR #3 완료 감사와 PR #4 범위 (2026-08-06)

PR #3의 실제 diff, 51개 자동 테스트, strict-concurrency 결과와 하드웨어 기록을 본문의 완료 기준과 다시 대조했다.

- 3.1, 3.2, 3.3과 3.5는 PR #3에서 완료됐다.
- 3.4는 startup/quit/crash/wake reconciliation과 안전한 long-operation 정리가 완료됐다. 저빈도 periodic reconciliation, Terminal drift 사용자 표시와 별도 `Disable BatteryGuard Control`은 남아 있다.
- 3.6의 privileged CLI preflight는 초기화보다 먼저 수행하도록 완료됐다. macOS native Charge Limit와의 제어 소유권 안내 및 충돌 처리는 남아 있다.
- 3.7 중 unknown 건강도/온도/전류 optional 보존과 main-actor 경계는 PR #3에서 선행 완료됐다. 저장/fetch 오류 가시성, 이력 상한, heartbeat, 로그인 승인 상태, Bundle 버전, 화면 문구·activation policy와 로컬 순환 진단 로그는 남아 있다.
- 3.8의 안전 관련 회귀 테스트 대부분과 실제 하드웨어 항목 1~7, 10은 PR #3에서 완료됐다. 새 이력/진단 실패 경로 테스트, sleep/wake와 Terminal drift 하드웨어 확인은 남아 있다.

PR #4는 3.7의 남은 모니터링·이력·UI 정확성과 로컬 진단 로그만 다룬다. 제어 상태 머신을 다시 설계하거나 하드웨어 동작을 추가하지 않는다. native Charge Limit 소유권, periodic drift reconciliation, 명시적 제어 해제 UX와 그에 필요한 하드웨어 검증은 각각 다음 PR로 분리한다.

### 0.6 PR #4 구현 및 자동 검증 결과

- 전류의 signed/unsigned IOKit 표현을 정규화하고 비현실적인 값은 unknown으로 처리한다. UI에는 단위, 부호와 충전/방전 방향을 함께 표시한다.
- 이력 store 준비 전 최신 샘플을 보류하고, 15분 heartbeat를 저장하며, Core Data load/save/fetch 실패를 UI와 로컬 진단 로그에 노출한다. 차트 downsampling은 첫/마지막 점을 보존하면서 정확히 200개 이하를 반환한다.
- 로그인 항목은 disabled, enabled, requires approval, unavailable과 unknown을 구분하고 앱이 다시 활성화될 때 실제 시스템 상태를 갱신한다.
- 앱 버전은 Bundle metadata에서 읽고, 주요 화면 문구를 한국어로 정리하며, 일반 창을 모두 닫으면 accessory activation policy로 복귀한다.
- 최근 100건의 command/control/history/sensor/lifecycle 이벤트를 `Application Support/BatteryGuard/Diagnostics.json`에 원자적으로 순환 저장한다. 테스트 host에서는 production logger와 store가 실제 I/O를 시작하지 않는다.
- strict-concurrency complete와 warnings-as-errors 조건에서 59개 테스트가 모두 통과했다. Release build와 Debug analyze도 같은 조건으로 통과했다.
- 이 단계는 하드웨어 명령 의미나 상태 전이를 변경하지 않으므로 실제 배터리 조작 검증은 실행하지 않았다. periodic reconciliation, sleep/wake, Terminal drift와 제어 소유권 후속 PR에서 통제된 하드웨어 체크를 재개한다.

### 0.7 PR #4 리뷰 수정 결과

- Core Data 준비를 고정 sleep으로 추측하지 않고 `loading -> ready/failed` 상태와 async waiter로 노출한다. Dashboard와 테스트는 store 준비 완료를 await한 뒤 fetch한다.
- controller의 semantic operation UUID를 Task-local context로 `SMCKit`과 `BatteryCommandRunner`까지 전달한다. command ID와 event ID는 별도로 유지하고, 같은 제어 작업의 command/status/verified before-after 기록은 하나의 operation ID로 연관된다.
- 오래된 비동기 완료는 조용히 버리지 않고 `superseded` 진단 이벤트로 기록한다. `ChargeMode`와 readiness의 진단 문자열은 `String(describing:)` 대신 명시적이고 안정적인 label을 사용한다.
- 진단 outcome을 typed enum으로 바꾸고 event ID 중복을 제거했다. 이전 로컬 JSON schema는 읽을 때 새 schema로 호환하며, 로그 저장 실패 시 Finder를 열지 않고 Settings에 오류를 표시한다.
- history의 load/save/fetch 오류를 분리해 성공한 작업이 다른 오류를 지우지 않게 했다. production 코드 안의 문자열 기반 failure hook은 최소 Core Data operation seam으로 교체했다.
- 로그인 항목 register/unregister 반환 뒤 실제 status 불일치를 오류로 표시하고, 새 시스템 상태 refresh가 오래된 action 오류를 제거하게 했다.
- activation policy 변경을 한 coordinator에 모아 반환값을 확인한다. regular policy가 거부되면 앱 활성화를 성공처럼 진행하지 않고, 마지막 일반 창이 닫힌 경우에만 accessory policy를 복원한다.
- strict-concurrency complete와 warnings-as-errors 조건에서 전체 70개 테스트가 통과했다. 실제 battery CLI, 로그인 항목과 production Core Data store는 테스트 중 사용하지 않았다.
- 이 시점에는 실제 충전 명령 의미가 바뀌지 않았다고 판단했으나, 아래 0.8 누적 리뷰에서 lifecycle/Heat 안전 결함을 발견해 이 판단과 하드웨어 검증 조건을 수정했다.

### 0.8 PR #1~4 누적 리뷰 수정 결과

PR #4 수정본을 `main`부터 누적으로 다시 검토한 결과, 기존 완료 기록보다 강한 보완이 필요했다. 특히 stale 작업의 보상 명령, Heat 복원 rollback, wake와 정상 종료가 실제 안전 불변식을 끝까지 보장하지 못했다.

- controller가 실행 중인 Swift task를 직접 소유하고 preemption 시 task와 backend를 함께 취소한다. 취소된 Top Up/Discharge 시작 작업은 최신 Heat Protection 전이 뒤에 maintain 보상 명령을 실행하지 않는다.
- Heat 복원 rollback은 새 long operation을 먼저 취소한 뒤 charging-off를 적용한다. 모든 semantic control 명령은 charging, discharge, maintain level과 exact worker 상태의 전체 tuple을 검증한다.
- wake reconciliation은 새 generation으로 기존 작업을 무효화하며, stale 완료가 wake 결과를 덮어쓰지 못한다.
- 정상 종료는 `applicationShouldTerminate`의 delayed reply를 사용한다. verified cleanup이 실패하면 정상 종료를 취소하고 앱을 남겨 실제 상태 확인을 요구한다.
- IOKit charge percent는 0...100이 아니거나 없으면 전체 측정을 사용할 수 없는 것으로 처리한다. 용량, cycle, voltage와 serial은 optional을 유지하고, IOKit/SMC 온도는 finite 및 보수적인 물리 범위를 통과해야 안전 판단에 사용한다.
- history는 저장된 preference가 아니라 controller의 마지막 verified effective limit를 기록한다. 센서 실패는 진단 로그에서 명시적인 failure outcome으로 저장한다.
- worker command는 경로와 mode의 exact token을 요구하고 SIGKILL 직전에 identity를 다시 조회한다. fixture policy는 실제 사용자 PID 파일을 사용하지 않는다.
- strict concurrency와 warnings-as-errors를 Xcode target 설정에 저장했다. 상태 모델 타입은 `ChargeState.swift`로 분리해 controller의 책임 경계를 조금 줄였다.
- 전체 자동 테스트는 83개로 증가했고 실제 battery CLI, 로그인 항목, production Core Data store를 사용하지 않는다. 실제 하드웨어 동작은 변경됐으므로 PR #4 merge 전 Top Up/Discharge, Heat rollback, wake와 정상 종료 수동 검증이 다시 필요하다.

이 수정으로 후속 순서 자체는 바뀌지 않는다. 다음 PR은 checkpoint 7의 periodic reconciliation과 Terminal drift 감지/표시를 구현한다. 다만 이전의 “PR #3에서 lifecycle/Heat/wake 완료” 표기는 이 누적 보완까지 포함해야 정확하다.

### 0.9 PR #5 periodic reconciliation 구현 결과

- 최초 초기화가 끝난 뒤 60초 저빈도 timer와 앱 활성화 시점에 실제 CLI status를 읽는다. 이 경로는 관찰만 수행하며 외부에서 바꾼 상태를 자동으로 덮어쓰지 않는다.
- 마지막 verified expectation과 charging, discharging, maintain level 및 exact worker 상태의 전체 tuple을 비교한다. 불일치는 단일 `ChargeMode.externalDrift` 상태로 표현하고 실제 관찰 상태를 UI와 진단 로그에 표시한다.
- drift 중에는 Charge Limit, Top Up과 Discharge 제어를 잠근다. status 조회 실패나 모순된 tuple은 이전 상태를 확정 상태처럼 유지하지 않고 unknown으로 표시한다.
- 외부 상태가 다시 expectation과 일치하면 다음 reconciliation에서 drift를 해제한다. reconciliation 도중 wake나 더 최신 제어 전이가 시작되면 generation과 expectation을 다시 비교해 오래된 조회 결과를 폐기한다.
- 외부에서 시작된 charge/discharge 또는 확인 불가능한 상태에서는 정상 종료를 거부하되 controller를 종료 상태로 만들지 않아 상태 수정 후 다시 종료할 수 있다. verified external maintain은 그대로 보존하고 charging-off는 차단 상태로 정리한다.
- fake backend로 periodic/app-activation trigger, maintain/discharge/status-failure drift, 자동 복귀, stale 결과와 종료 거부/재시도를 검증한다. 전체 자동 테스트 89개가 통과했고 실제 CLI와 배터리 상태는 변경하지 않았다.
- 저장된 strict-concurrency complete 및 warnings-as-errors 설정으로 Debug test, Release build와 Debug analyze가 모두 통과했다.
- sleep/wake와 Terminal drift 실제 하드웨어 검증은 명시적 승인 전까지 보류한다.

#### PR #5 리뷰 보완

- Maintain 일치는 charging 상태가 known이고 정확한 worker가 살아 있을 때만 인정한다. Top Up/Discharge는 전체 CLI tuple뿐 아니라 BatteryGuard가 소유한 long-running process의 생존까지 함께 검증한다.
- 소유 process가 사라졌지만 같은 의미의 외부 charge/discharge가 남아 있으면 자동 Maintain으로 덮어쓰지 않고 external drift로 전환한다. 안전한 charging-disabled 상태에서만 기존 Maintain 자동 복구를 시도한다.
- 종료 시 external drift의 마지막 주기 조회값을 신뢰하지 않고 즉시 status와 process ownership을 다시 읽는다. 그 사이 외부 charge/discharge가 시작됐거나 조회가 실패하면 controller를 해체하지 않은 채 종료를 거부하여 수정 후 재시도할 수 있다.
- drift UI는 BatteryGuard의 기대 상태, 실제 관찰 상태와 Terminal 복구 목표를 함께 표시하고 Menu Bar, Dashboard, Settings에서 read-only `다시 확인`을 제공한다. drift 중 Charge Limit 표시는 실제 외부 limit가 아니라 복구해야 할 기대 limit를 유지한다.
- 일시적인 non-blocking failure는 이전 기대 tuple이 다시 확인되면 복구한다. safety-blocking failure는 충전 비활성 tuple이 검증된 경우에만 `heatBlocked`로 복구한다.
- reconciliation timer의 최소 간격을 1초로 제한하고 tolerance를 부여했다. production 기본값은 60초를 유지한다.
- unknown charging, unknown/duplicate worker, Top Up/Discharge process ownership 상실, Heat Protection drift 복구, failed-state 복구, 종료 직전 상태 변화와 status 조회 실패를 추가 검증한다. reconciliation 진단 기록은 직접 await하여 고정 sleep 없이 중복 방지를 검증한다. 전체 자동 테스트는 98개다.
- 저장된 strict-concurrency complete 및 warnings-as-errors 설정으로 전체 테스트, Release build와 Debug analyze를 다시 검증한다. 실제 sleep/wake와 Terminal drift 하드웨어 검증은 명시적 승인 전까지 보류한다.

이 구현으로 계획 순서는 바뀌지 않는다. checkpoint 7의 코드와 자동 검증은 PR #5에서 완료하고 실기 검증만 남긴다. 다음 구현은 checkpoint 8의 macOS native Charge Limit 제어 소유권 안내와 명시적 `Disable BatteryGuard Control` UX다.

### 0.10 PR #1~5 누적 리뷰 보완 결과

PR #5까지의 전체 누적 diff를 다시 검토해 기존 단계의 완료 조건을 다음과 같이 강화했다.

- process 조회는 전체 `ps` 출력에 의존하지 않고 battery 경로 후보 PID만 조회한 뒤 각 명령행을 exact token으로 재검증한다. PID 파일은 symlink/FIFO를 따르지 않고 현재 사용자 소유의 작은 regular file만 제한적으로 읽는다.
- Maintain 검증은 charging/discharging/limit뿐 아니라 worker가 같은 target으로 실행 중인지 확인한다. worker target 불일치, truncated status 출력, stale PID 정리 실패와 보상 Maintain 실패를 성공처럼 숨기지 않는다.
- runner는 cancellation 동안 새 command를 거부하는 barrier를 제공한다. long-running command는 명시적 descendant policy, 제한된 stderr capture와 12시간 상한을 가지며 timeout watchdog이 외부 polling 없이도 process group을 정리한다.
- battery command보다 SMC executable trust 검사를 먼저 끝낸다. production SMC가 없거나 신뢰 조건을 통과하지 못하면 어떤 battery hardware command도 시작하지 않는다.
- Top Up/Discharge 시작 실패 후 verified Maintain 보상까지 실패하면 controls-blocked failure로 전환한다. 종료는 cancellation 뒤 fresh status로 정책을 다시 결정하고 verified cleanup이 성공한 뒤에만 timer/monitor/observer를 해체한다. 실패 시 controller를 살아 있고 재시도 가능한 상태로 둔다.
- IOKit 측정이 일시적으로 없어도 SMC 온도와 owned-process liveness를 독립적으로 감시한다. 두 센서가 모두 없으면 Heat Protection은 fail-closed로 동작한다. wake 중 external drift는 자동 Maintain으로 덮어쓰지 않고 read-only 상태 재검증으로 보존한다.
- Settings의 Heat Protection과 LED toggle은 preference를 직접 변경하지 않고 controller intent를 통과한다. drift 표시는 battery measurement 유무와 무관하게 세 화면에서 같은 component로 노출한다.
- XCTest host의 shared monitor/history/settings/diagnostics는 production timer, store, defaults와 login item을 사용하지 않는다. worker target, decoy process, output truncation, autonomous long timeout, cancellation barrier, SMC preflight 순서, 보상 실패, wake drift와 retryable shutdown 회귀를 추가했다.
- strict-concurrency complete 및 warnings-as-errors 조건에서 106개 테스트가 모두 통과했다. Release build와 Debug analyze도 통과했고 실제 battery CLI나 하드웨어 제어 명령은 실행하지 않았다.

이 보완은 checkpoint 1~7의 안전 계약을 강화하지만 checkpoint 8 이후의 순서는 바꾸지 않는다. `ChargeController` 책임 분리는 새 안전 동작과 섞지 않고 후속 maintainability 작업으로 남긴다. 다음 PR #6은 checkpoint 8만 구현한다.

### 0.11 PR #6 제어 소유권 구현 및 자동 검증 결과

- `ChargeMode.controlDisabled`와 `ReconciledChargeExpectation.controlReleased`를 추가해 monitoring-only 상태를 임시 Boolean이 아닌 기존 상태 머신에 포함했다. Charge Limit, Top Up, Discharge와 Heat Protection은 이 상태에서 잠긴다.
- 명시적 `BatteryGuard 제어 끄기`는 owned long operation과 exact Maintain worker를 정리하고 `battery maintain stop`을 실행한다. 명령 직후 charging enabled, not discharging, worker stopped 전체 tuple이 확인되어야 preference를 완료 상태로 저장한다.
- 해제 의도는 hardware mutation 전에 crash-durable ownership journal의 `releasing` 상태로 저장한다. 명령 도중 앱이 종료되거나 crash하면 다음 시작은 Maintain을 자동 재적용하지 않고 해제 transaction을 다시 실행하고 strict tuple을 검증한다. 실패하면 `releasing`을 유지한 채 명시적 재시도를 제공한다. periodic/wake의 read-only reconciliation은 pending을 완료 상태로 승격하지 않는다.
- monitoring-only 상태의 이후 검증은 charging 값이 known이고 discharge/worker/BatteryGuard-owned long process가 없는지를 확인한다. macOS native Charge Limit가 목표에서 charging을 멈출 수 있으므로 charging disabled만으로 충돌이나 drift라고 단정하지 않는다. 반대로 공개 API 없이 native 설정 활성 여부를 정확히 감지한다고 주장하지 않는다.
- 다시 BatteryGuard 제어를 켤 때는 macOS Charge Limit를 먼저 끄라는 확인을 거친 뒤 verified Maintain을 설정하고, 성공 후에만 BatteryGuard ownership을 저장한다. 제어 해제 시 Heat Protection과 MagSafe LED 제어도 끄고 LED 자동 동작을 복원한다.
- Settings에 현재 소유자, 양방향 전환, destructive confirmation, macOS Battery Settings 링크와 동시 사용 금지 안내를 추가했다. Apple 공식 문서 기준 native Charge Limit는 macOS Tahoe 26.4 이상 Apple Silicon Mac에서 제공된다: https://support.apple.com/102338
- release tuple 실패, preference migration/pending crash window, 초기화, enable/disable 실패, native charging pause 호환, periodic drift, wake, shutdown과 retry를 fake backend/fixture로 검증했다. strict-concurrency complete 및 warnings-as-errors 조건에서 전체 116개 테스트, Release build와 Debug analyze가 통과했다.
- 실제 CLI와 macOS Charge Limit를 바꾸는 하드웨어 검증은 명시적 승인 없이 실행하지 않았다.

### 0.12 PR #2~6 누적 리뷰 보완과 PR #7 범위

PR #2부터 PR #6까지의 전체 diff를 다시 검토해 제어 소유권을 단순 preference가 아니라 복구 가능한 transaction으로 강화했다.

- ownership을 `batteryGuard`, `releasing`, `system`의 세 상태로 저장하고 production에서는 Application Support의 별도 JSON journal을 file/directory `fsync`와 atomic rename으로 기록한다. journal을 읽거나 저장할 수 없으면 backend를 열기 전에 초기화를 차단한다.
- pending release는 시작 시와 명시적 retry에서 실제 release 명령과 strict status 검증을 다시 수행한다. periodic/wake reconciliation은 `controlReleasing`을 별도로 유지하며 compatible status만으로 `controlReleased`를 만들지 않는다.
- ownership journal이 `system` 또는 `batteryGuard`로 commit된 뒤의 task cancellation은 완료 결과를 이전 상태로 뒤집지 않는다. 종료 중에도 persisted ownership을 우선해 release/preserve 정책을 선택하고 Heat Protection, LED와 sleep side effect를 한 finalizer에서 정리한다.
- 해제 transition이 시작되는 즉시 persisted ownership으로 모든 BatteryGuard-owned 제어와 자동 Heat Protection 재진입을 잠근다. monitoring-only UI에서는 Heat Protection과 LED toggle도 비활성화한다.
- runner timeout의 NaN, infinity와 overflow를 안전하게 변환한다. battery script의 PATH에서 user-writable `/usr/local/bin`을 제거하고 validated CLI directory와 고정 system directory만 사용한다.
- raw IOKit debug dump를 제거해 battery serial을 stdout에 노출하지 않는다. macOS Battery Settings deep link 실패와 제어 해제 시 LED side effect를 UI에 명시한다.
- release restart/periodic/wake, durable commit 뒤 shutdown cancellation, exact release command, ownership persistence failure, safe PATH와 nonfinite timeout 회귀 테스트를 추가했다. strict-concurrency complete 및 warnings-as-errors 조건에서 전체 123개 테스트와 Debug analyze가 통과했다. 실제 battery/SMC 명령은 실행하지 않았다.

이 보완으로 checkpoint 8의 코드·자동 검증 조건은 강화됐지만 실제 하드웨어 gate는 바뀌지 않는다. 승인된 Mac에서 BatteryGuard → native → BatteryGuard 왕복, sleep/wake와 Terminal drift를 검증해야 한다.

PR #7은 동작을 추가하지 않는 maintainability 단계다. 1,800줄을 넘은 `ChargeController`에서 순수 reconciliation policy를 별도 타입으로 추출하고, durable ownership journal을 `UserSettings`에서 별도 파일로 분리한다. actor/state ownership과 접근 제어를 넓히는 extension 분할은 하지 않으며, 기존 fixture 테스트를 그대로 통과시키고 policy 경계 테스트를 추가한다. 거대한 단일 테스트 파일의 물리적 분리는 project churn을 제한하기 위해 이 경계가 안정된 뒤 별도 후속 작업으로 남긴다.

checkpoint 8까지의 기능 구현은 완료됐다. 남은 필수 작업은 승인된 실제 하드웨어 checklist이고, 다음 코드 작업은 checkpoint 9의 책임 분리다.

### 0.13 PR #7 책임 경계 분리 결과

- `BatteryControlOwnership`과 crash-durable POSIX journal 구현을 `UserSettings.swift`에서 `BatteryControlOwnership.swift`로 옮겼다. `UserSettings`는 journal의 위치 결정, 초기 load/migration, ownership transition과 persistence error를 계속 소유하지만 POSIX 파일 I/O 세부사항은 소유하지 않는다.
- reconciliation의 full-tuple 일치 판정과 observed mode 해석을 I/O 없는 `ChargeReconciliationPolicy`로 추출했다. expectation의 UI state 매핑은 `ChargeState`에 남기고, `ChargeController`는 status/process ownership을 읽고 published state와 task generation을 관리하는 orchestration에 집중한다.
- 여러 파일의 extension이 controller private 상태에 접근하도록 access level을 넓히지 않았다. PR #7 리뷰 보완에서 optional process ownership을 명시적 `notRequired`/`active`/`inactive` 관측으로 교체해 미관측 상태가 released control 성공으로 통과하지 못하게 했다. UI mode/문구 매핑은 `ChargeState`로 옮기고 charge-limit constraint와 policy 테스트도 독립 파일로 분리했으며, 모든 expectation tuple, worker 실패 상태와 mode 매핑을 직접 검증한다.
- strict-concurrency complete 및 warnings-as-errors 조건에서 전체 135개 테스트, Release build와 Debug analyze가 통과했다. 파일 이동과 순수 policy 추출뿐이며 실제 battery/SMC 명령과 제어 의미는 변경하지 않았다.

PR #7 이후에도 `ChargeController`는 lifecycle, Heat Protection, 사용자 intent와 LED orchestration을 함께 가진 큰 타입이다. 추가 분리는 실제 하드웨어 checklist가 통과한 뒤 각 subsystem의 명시적 input/output 계약을 먼저 정의해 별도 PR로 진행한다. 단일 테스트 파일의 물리적 분리도 그때 production 경계와 같은 단위로 수행한다.

### 0.14 PR #8 실기 검증과 Discharge 계약 수정 결과 (2026-08-07)

승인된 Release 앱으로 자동 검증 뒤 실제 battery CLI v1.3.4와 하드웨어를 점검했다. 최초 Discharge 실행은 실제로 시작됐지만 앱이 정상 상태를 실패로 오판했다. 앱은 `charging=disabled, discharging=true`를 요구했으나, CLI는 `CHTE=00`으로 충전을 허용한 뒤 `CHIE=08`로 강제 방전을 켜며 실제 안정 상태는 `charging=enabled, discharging=true`였다. 직접 실행한 CLI를 250ms 간격으로 원시 SMC 키와 `status_csv`까지 계측해 timeout 문제가 아니라 잘못된 상태 계약임을 확인했다.

- `BatteryControlStatus.isVerifiedDischarging`에 CLI의 실제 full tuple인 charging enabled, discharging true, Maintain worker stopped를 정의했다. `SMCKit.startDischarge`, periodic reconciliation과 observed-mode 해석이 모두 이 한 계약을 사용한다.
- 테스트용 backend에서 long-running ownership과 discharge 상태를 분리했다. Top Up을 discharge로 가장하던 Boolean fixture를 제거하고, Discharge 프로세스가 시작된 뒤 `enabled,discharging`이 나타나는 회귀 테스트를 추가했다.
- strict-concurrency complete 및 warnings-as-errors 조건에서 전체 136개 테스트가 통과했다. Release build와 Debug analyze도 통과했다.

| 검사 | 수행 내용 | 결과 |
|---|---|---|
| startup reconciliation | ownership journal과 기존 Maintain 80 상태에서 Release 앱 실행 | 0600 journal, exact worker와 full tuple 일치 |
| Charge Limit | UI에서 80→85→80 변경 | 각 target의 exact worker 확인 후 80 복원 |
| Top Up | UI 시작과 취소 | owned `battery charge 100`, 취소 뒤 exact Maintain 80 복원 |
| Discharge | 81%에서 80% 목표로 시작과 취소 | 수정 전 오판 재현; 수정 Release에서 `CHIE=08`, `CHTE=00`, owned `battery discharge 80`과 UI `방전 중` 확인 후 Maintain 80 복원 |
| Heat Protection | threshold 40→35→40°C | 진입 시 worker 0과 verified charging-off, 복원 시 exact Maintain 80 확인; 설정도 원복 |
| 정상 종료 | Maintain 중 메뉴의 종료 사용 | 앱만 종료되고 persistent Maintain 80 유지 |
| crash/restart | 정확한 앱 PID만 SIGKILL 후 재실행 | worker를 중복 생성하지 않고 durable ownership과 actual tuple reconciliation 통과 |
| sleep/wake | Amphetamine의 수동 무제한 세션을 잠시 종료하고 software sleep 수행 | 31초 Sleep, DarkWake와 FullWake 로그 확인; 앱과 Maintain 유지 후 동일한 무제한 세션 복원 |
| Terminal drift | 외부 `battery charging on` 실행 | 앱이 상태를 덮어쓰지 않고 60초 reconciliation에서 charging mismatch와 stale worker PID를 `externalDrift`로 기록 |
| drift 복구 | stale PID identity 확인 후 정확한 PID만 제거하고 앱 재시작 | startup reconciliation이 새 PID와 pidfile이 일치하는 Maintain 80을 복원 |
| 제어 소유권 왕복 | Settings에서 BatteryGuard→system→BatteryGuard 전환 | 해제 시 `system` journal, charging enabled, worker 0; 재활성화 시 `batteryGuard` journal과 exact Maintain 80 복원 |

실기 검증에서 외부 CLI의 “Killing old maintain process” 로그 뒤에도 Bash worker가 살아 있고 PID 파일만 사라지는 동작도 확인했다. 따라서 CLI 로그나 프로세스 존재만으로 Maintain을 인정하지 않고 PID 파일, exact command line과 full status tuple을 함께 확인하는 기존 정책은 유지한다.

최종 복원 상태는 82%, AC attached, charging disabled, not discharging, maintain 80이며 PID 파일과 exact worker PID가 일치한다. ownership journal은 `batteryGuard`, Heat Protection은 원래 설정인 활성/40°C, MagSafe LED 제어는 원래 설정인 비활성 상태다.

이 수정은 단계 순서를 바꾸지 않는다. checkpoint 1~8의 자동·실기 안전 gate는 PR #8로 완료됐다. 다음 코드 작업은 계획대로 subsystem 계약을 먼저 정의하는 `ChargeController` 책임 분리다.

### 0.15 PR #2~8 병합 전 누적 리뷰 보완 (2026-08-07)

PR #2~8 누적 리뷰에서 병합을 막는 종료·프로세스·온도 안전 경로를 PR #8에서 추가 보완한다.

- CLI preflight나 ownership journal 검사처럼 backend가 사용 가능해지기 전에 초기화가 실패한 경우, 종료는 backend를 다시 호출하지 않고 로컬 task·timer·observer만 정리한다. backend open 이후 실패에는 기존 verified hardware cleanup 계약을 유지한다.
- Top Up/Discharge 종료에서는 long-running cancellation과 verified Maintain/charging-off 복구가 성공한 뒤에만 sleep assertion을 해제한다. 정리 실패 시 assertion과 retry 가능한 controller 상태를 유지한다.
- MagSafe LED 자동 복원은 verified battery cleanup 뒤의 best-effort peripheral cleanup으로 분리한다. LED 오류는 진단과 UI 오류로 남기지만 안전하게 복원된 배터리 상태와 앱 종료를 되돌리지 않는다.
- cached SMC 온도는 모든 Heat Protection 진입 경로에서 동일한 15초 freshness 규칙을 사용한다. Heat Protection 재활성화도 stale cache를 정상 온도로 재사용하지 않고 unavailable로 처리해 fail closed 한다.
- Maintain worker 종료 대상은 PID, exact command와 프로세스 시작 시각으로 묶고 각 `SIGTERM`/`SIGKILL` 직전에 시작 identity를 다시 읽는다. PID가 재사용되거나 identity 확인이 불완전하면 신호를 보내지 않는다.
- `BatteryMonitor` sleep assertion 경계를 주입 가능하게 만들어 자동 테스트가 실제 시스템 assertion을 만들지 않으면서 보유·해제 순서를 검증한다.

이 보완은 checkpoint 순서를 바꾸지 않는다. PR #8 병합 뒤 다음 PR #9는 controller subsystem의 명시적 input/output 계약을 먼저 정의하고, 그 경계대로 production code와 단일 테스트 파일을 나누는 maintainability 단계다.

### 0.16 PR #9 controller subsystem 계약 분리 (2026-08-07)

PR #2~8 병합 뒤 동작을 바꾸지 않는 maintainability 단계로 lifecycle과 temperature freshness 경계를 `ChargeController` 밖에 정의한다.

- durable `BatteryControlOwnership`, current mode와 effective limit을 묶은 `ChargeShutdownContext`를 shutdown planning의 명시적 입력으로, `ChargeShutdownPolicy` 또는 typed `ChargeShutdownPlanningError`를 출력으로 둔다. requested policy와 fresh full tuple 기반 최종 policy를 고르는 로직을 I/O 없는 `ChargeShutdownPlanner`로 이동한다.
- SMC sample 값과 측정 시각을 `SafetyTemperatureCache` 한 값 타입으로 묶는다. future sample, expired sample, nonfinite max age를 모두 unavailable로 처리하며 `ChargeController`는 유효한 측정의 record/clear와 freshness 조회만 orchestration한다.
- 3,600줄 단일 테스트 파일에서 `ChargeControllerSafetyTests`와 shared `TestSupport`를 독립 파일로 분리한다. pure lifecycle과 temperature 계약은 각각 `ChargeLifecyclePolicyTests`, `SafetyTemperatureCacheTests`에서 직접 검증한다.
- actor ownership, hardware command 순서, UI-visible state와 기존 테스트 의미는 변경하지 않는다. 다음 책임 분리는 새 순수 계약이 안정된 뒤 Heat Protection decision과 long-running lifecycle을 각각 독립 PR에서 다룬다.

PR #9 혹독 리뷰에서 Boolean ownership 입력이 durable enum과 경쟁하고, verified planning이 `restoreMaintain`에 기록된 limit을 fallback limit으로 덮을 수 있는 계약 오류를 발견했다. context 입력을 `BatteryControlOwnership` 하나로 정규화하고 recorded limit을 끝까지 보존했다. planning error는 문자열 대신 typed `BatteryControlStatus`를 보유한다. `SafetyTemperatureCache`도 nonfinite·물리적으로 불가능한 온도와 잘못된 timestamp를 자체적으로 거부하도록 강화했다. 모든 transition family, ownership 우선순위, full-tuple fallback, invalid/stale/future temperature 경계를 별도 pure-policy 테스트로 검증한다.

최종 자동 검증은 strict-concurrency complete와 warnings-as-errors에서 151개 테스트, Release build와 Debug analyze가 모두 통과했다. 이 PR은 실제 CLI나 하드웨어를 실행하지 않는다.

### 0.17 PR #10 Heat Protection decision 분리 (2026-08-07)

PR #9의 순수 subsystem 계약 위에서 Heat Protection의 temperature/ownership/mode/cooldown 판단을 I/O 없는 `HeatProtectionPolicy`로 분리한다.

- 입력은 validated temperature 또는 unavailable, threshold, battery-info availability, 단일 `ChargeMode`, effective limit, durable `BatteryControlOwnership`, retry timestamp와 현재 시각이다.
- 출력은 normalized temperature와 `none`, `enter(previous:)`, `restore(previous:)` 중 하나인 단일 action이다. controller는 sensor error 표시와 backend transition 실행만 담당한다.
- BatteryGuard ownership이 아니면 hardware action을 만들지 않고, invalid/unavailable temperature는 BatteryGuard ownership에서 fail closed 한다. 2°C restore hysteresis, restore 중 재과열 re-block, failed-state retry cooldown과 battery-info requirement를 기존 계약 그대로 유지한다.
- pure policy 테스트에서 invalid/unavailable sample, ownership, restorable mode, hysteresis, cooldown, in-flight restore와 release drift 경계를 검증한다. 실제 CLI와 하드웨어는 실행하지 않는다.

### 0.18 PR #2~10 누적 리뷰 보완과 PR #11 범위 (2026-08-07)

PR #2부터 #10까지의 현재 tree를 다시 검토해 failure 의미와 장기 작업 관측 수명을 강화한다.

- `failed(previous:message:controlsBlocked:)`의 Boolean은 Heat Protection 실패, 이전 상태로 read-only 복구 가능한 실패와 하드웨어 상태가 불명인 실패를 서로 바꿔 해석할 수 있었다. 이를 `recoverPrevious`, `heatProtection`, `manualIntervention`의 typed disposition으로 교체한다.
- 오직 Heat Protection disposition만 온도 policy의 자동 retry/restore와 charging-disabled reconciliation 대상이다. Top Up/Discharge 보상 실패, wake/quit cleanup 실패와 초기화 실패는 온도 샘플이 자동으로 Maintain/Top Up/Discharge를 재시작하지 못한다.
- long-running process 생존 확인 task는 check generation과 controller operation generation을 함께 검증한다. shutdown, preemption 또는 새 operation 뒤에 끝난 stale probe는 mode를 바꾸거나 recovery를 시작하지 못한다.
- strict-concurrency complete와 warnings-as-errors에서 161개 테스트, Release build와 Debug analyze가 통과했다. 실제 CLI와 하드웨어는 실행하지 않았다.

이 보완은 기존 순서를 바꾸지 않는다. PR #11은 Top Up/Discharge 장기 작업의 순수 decision 계약을 별도 타입으로 추출한다. process liveness와 fresh status를 입력으로 받아 `none`, verified completion, safe Maintain recovery 또는 external drift를 구분하고, controller에는 task 소유권, backend I/O와 published state 적용만 남긴다. 시작/중지 명령 자체와 `BatteryCommandRunner`의 process ownership은 옮기지 않는다.

### 0.19 PR #11 long-running lifecycle decision 분리 (2026-08-07)

- `LongRunningChargeSession`과 `LongRunningChargePolicy`를 추가해 Top Up/Discharge의 target 진행, 측정 불가 시 liveness 확인, verified cleanup 요청, unexpected exit 후 safe Maintain recovery 또는 external drift 결정을 I/O 없는 계약으로 분리했다.
- controller는 owned-process probe, fresh status read, operation/probe generation, backend 명령과 published mode 적용을 계속 소유한다. target 도달은 성공이 아니라 `finishAndRestoreMaintain` 요청이며, cancel과 verified Maintain이 끝난 뒤에만 mode를 완료 상태로 바꾼다.
- unexpected Discharge exit에서는 verified Maintain 복구가 성공하기 전까지 sleep assertion을 유지한다. external drift 동안에도 유지하고, read-only reconciliation이 full Maintain tuple을 확인한 뒤에만 해제한다.
- PR #11 혹독 리뷰에서 죽은 expectation API와 완료를 과장한 action 이름을 제거하고, charging-disabled 외의 모든 관측을 자동 덮어쓰지 않는 drift로 고정했다.
- strict-concurrency complete와 warnings-as-errors에서 전체 170개 테스트, Release build와 Debug analyze가 통과했다. 실제 CLI와 하드웨어는 실행하지 않았다.

이 단계로 계획된 controller pure-decision 분리는 완료됐다. 추가 파일 분리는 구체적인 안전 결함이나 독립 테스트 경계가 확인될 때만 진행하며, 줄 수 감소만을 위한 service/extension 분할은 하지 않는다.

### 0.20 PR #11 커밋 상태와 잔여 작업 감사 (2026-08-07)

PR #11의 production 변경은 `e3fec3f`까지 커밋되어 로컬과 원격이 일치하고, PR #9 → #10 → #11의 stacked diff는 모두 충돌 없이 열려 있다. 체크포인트 1~15의 기능, 안전 계약, 자동 테스트와 승인된 하드웨어 검증은 완료됐다. 따라서 아래 작업은 기존 핵심 계획의 미완료 기능이 아니라 병합 절차와 확인된 후속 유지보수다.

#### What already exists

- PR #9는 shutdown planning과 temperature freshness, PR #10은 Heat Protection, PR #11은 Top Up/Discharge 장기 작업 결정을 순수 policy와 독립 테스트 경계로 분리한다. 이 경계를 다시 service/extension 계층으로 복제하지 않는다.
- controller는 hardware I/O, Swift task 소유권, operation/probe generation과 published state 적용을 계속 소유한다.
- strict-concurrency complete와 warnings-as-errors에서 170개 테스트, Release build와 Debug analyze가 통과했다.
- PR #8에서 Top Up, Discharge, Heat, quit/crash, sleep/wake, Terminal drift와 control ownership 실제 하드웨어 검증을 완료했다.

#### 남은 작업 순서

```text
PR #9 merge
    -> PR #10 base를 main으로 변경하고 diff/검증 후 merge
        -> PR #11 base를 main으로 변경하고 diff/검증 후 merge
            -> main에서 strict tests + Release + analyze
                -> PR #12 SMC sample task lifetime [구현·혹독 리뷰 보완 완료, merge 대기]
                    -> PR #13 test topology cleanup [구현·혹독 리뷰 보완 완료, merge 대기]
                        -> [사용자 승인 시] 영향 범위만 수동 hardware 재검증
```

1. **Stacked PR 병합 `[완료]`:** PR #9를 먼저 병합했다. 그 뒤 PR #10과 PR #11의 base를 각각 `main`으로 바꾸고 고유 diff를 확인한 후 순서대로 병합했다. merge commit을 재작성하거나 force-push하지 않았다.
2. **병합 후 자동 gate `[완료]`:** 갱신된 `main`에서 전체 170개 strict-concurrency tests, Release build와 Debug analyze를 다시 실행해 통과했다.
3. **PR #12 — SMC temperature sampling task lifetime `[구현·혹독 리뷰 보완 완료, merge 대기]`:** `isSamplingSMCTemperature` Boolean 대신 controller가 sample task와 generation을 소유한다. shutdown, failed initialization, sleep/wake와 Heat Protection disable/re-enable에서 오래된 sample을 취소하고, 모든 await 뒤 generation·readiness·ownership을 다시 확인한 경우에만 cache나 mode를 변경한다. 지연된 sample이 shutdown/wake/new intent/control release 뒤 상태를 바꾸지 못하는 회귀 테스트를 같은 PR에 넣었다.
4. **PR #13 — test topology cleanup `[구현·혹독 리뷰 보완 완료, merge 대기]`:** production 동작을 바꾸지 않고 `BatteryGuardTests.swift`와 `ChargeControllerSafetyTests.swift`를 기존 subsystem 경계별 파일로 나눴다. test target membership, 174개 test 이름과 test method body를 보존하고 controller test helper는 한 XCTestCase에만 유지했다.
5. **승인 기반 수동 검증:** PR #12가 실제 온도 sampling lifecycle을 변경하므로 자동 gate 통과 뒤 Heat enable/disable, sleep/wake와 최종 Maintain 복원을 실제 Mac에서 다시 확인할 가치가 있다. 사용자의 명시적 승인 없이는 실행하지 않는다. 검증만 통과하면 별도 code PR을 만들지 않고 기록만 남기며, 결함이 발견된 경우에만 원인별 독립 bug-fix PR을 연다.
6. **종료 조건:** PR #13 뒤에는 구체적인 안전 결함, 재현 가능한 버그 또는 새 독립 테스트 경계가 없으면 추가 controller 분리를 중단한다.

#### 독립 PR 분할과 의존성

| 작업 | 범위 | 의존성 | 병합 조건 |
|---|---|---|---|
| 기존 PR #9 | lifecycle/temperature pure policy | `main` | 현재 diff와 151+ tests 확인 |
| 기존 PR #10 | typed failure + Heat policy + probe hardening | PR #9 | base 변경 후 PR #10 고유 diff만 남음 |
| 기존 PR #11 | long-running policy/recovery | PR #10 | base 변경 후 PR #11 고유 diff만 남음 |
| 새 PR #12 | SMC sample task ownership과 회귀 테스트 | PR #11 merge 후 `main` | stale sample이 최신 lifecycle을 변경하지 않음 |
| 새 PR #13 | test file physical split only | PR #12 | production diff 0, test count/assertion 보존 |
| 조건부 bug-fix PR | 승인된 hardware 검증에서 발견된 한 원인 | PR #12 | 재현·수정·복원 상태 기록 |

모든 작업이 `ChargeController` 또는 같은 controller safety test target을 순서대로 건드리므로 **sequential implementation, no parallelization opportunity**다. 별도 worktree에서 PR #12와 #13을 동시에 진행하면 test 이동과 신규 회귀 테스트가 충돌하므로 이득이 없다.

#### Failure modes와 검증

| 경로 | 현실적인 실패 | 자동 검증 | 사용자 영향/처리 |
|---|---|---|---|
| stacked base 변경 | 앞 PR 변경이 중복되거나 PR 고유 commit이 빠짐 | base 변경 전후 `git log`와 `git diff` 비교 | 잘못된 merge를 중단하고 base만 수정 |
| merge 후 main | stacked 조합에서만 compile/test 실패 | strict tests, Release, analyze | 후속 PR 중단, 최초 실패 commit 추적 |
| SMC sample cancellation | 오래된 온도 완료가 wake/shutdown/new Heat intent를 덮음 | delayed fake backend와 generation test | cache/state mutation 거부, 다음 fresh sample 사용 |
| test physical split | test target 누락으로 실행 test 수 감소 | 실행 test 수 170 이상 및 기존 test 이름 대조 | 누락된 target membership 복원 |
| 수동 hardware 검증 | Heat 또는 wake 뒤 Maintain 복원 실패 | 전후 `status_csv`, worker identity와 `pmset` 기록 | 앱 종료보다 verified safe recovery 우선 |

silent failure이면서 테스트와 오류 처리가 모두 없는 새 경로는 발견되지 않았다. SMC sample task는 현재 generation 소유권이 없지만 후속 PR #12와 그 회귀 테스트로 명시적으로 닫는다.

#### NOT in scope

- 배포, CI, notarization, auto-update와 installer: 개인용 단일 Mac 앱에 필요한 안전 개선이 아니다.
- 줄 수 감소만을 위한 추가 `ChargeController` service/extension 분리: 새로운 계약이나 결함 없이 access control과 stale-task 위험만 늘린다.
- PR #9~#11을 하나로 squash하거나 history를 force-push로 재작성: review 가능한 독립 경계를 잃는다.
- 승인 없는 실제 battery/SMC 명령 실행: 기본 검증은 fixture와 fake backend만 사용한다.
- View 100% coverage와 무관한 UI 재설계: 현재 잔여 위험과 관계없다.

#### Implementation Tasks

- [x] **T1 (P1)** — PR #9 → #10 → #11을 순서대로 병합하고 각 base 변경 뒤 고유 diff를 확인한다.
- [x] **T2 (P1)** — 갱신된 `main`에서 strict tests, Release build와 Debug analyze를 실행한다.
- [x] **T3 (P2)** — PR #12에서 SMC sample task를 generation 기반으로 소유·취소하고 stale completion 테스트를 추가한다.
- [x] **T4 (P3)** — PR #13에서 두 대형 테스트 파일을 subsystem별로 물리 분리하고 test count를 보존한다.
- [x] **T5 (approval-gated)** — PR #12 영향 범위의 Heat/sleep-wake/Maintain 수동 검증을 수행하고 최종 복원 상태를 기록한다.

### 0.21 PR #12 SMC sample task lifetime 결과 (2026-08-07)

- background SMC read를 controller-owned `Task`와 generation으로 교체했다. completion은 generation, cancellation, readiness, shutdown, Heat intent와 durable battery-control ownership을 모두 다시 확인한 뒤에만 temperature cache나 mode를 변경한다.
- failed initialization, shutdown, sleep/wake, Heat disable/re-enable와 control release가 sample task를 취소하고 generation을 무효화한다. 취소를 무시하는 fake read로 shutdown, wake, Heat re-enable와 ownership release 뒤 stale completion을 검증한다.
- 혹독 리뷰에서 batteryInfo가 없는 Heat re-enable이 fresh sample을 기다리는 동안 실제 charging-off를 늦추는 fail-open 회귀를 발견했다. 먼저 verified Heat block을 완료하고 해당 enable generation에 한해서만 fresh sample을 시작하도록 수정했다. 일반 Heat transition에는 추가 read를 만들지 않는다.
- PR #2~#13 누적 혹독 리뷰에서 foreground temperature preflight와 long-running 취소가 cancellation을 무시하고 늦게 반환할 때 최신 Heat/shutdown 전이 뒤 stale hardware mutation을 실행할 수 있는 P1 결함을 발견했다. 모든 관련 await 경계에서 cancellation과 operation generation을 다시 검증하고, Heat 전환 중 기능 해제는 진행 중 전이를 선점하며, 선점된 Top Up/Discharge 정리는 Maintain을 적용하지 못하게 했다.
- strict-concurrency complete와 warnings-as-errors에서 전체 178개 테스트, Release build와 Debug analyze가 통과했다. 실제 battery/SMC 명령은 실행하지 않았다.

PR #12의 구현·리뷰 보완·누적 리뷰 수정과 push는 완료됐다. PR #13은 최신 PR #12 위에 재적층했으며 production diff 없이 두 대형 테스트 파일을 subsystem 경계로 나눈다.

### 0.22 PR #13 test topology cleanup 결과 (2026-08-07)

- `BatteryGuardTests.swift`의 기존 XCTestCase들을 subsystem 이름의 파일로 옮기고, `ChargeControllerSafetyTests.swift`의 test methods를 initialization, Heat Protection, reconciliation, lifecycle, ownership와 temperature sampling extension 파일로 나눴다.
- controller test fixture와 `eventually` helper는 `ChargeControllerSafetyTestCase.swift` 한 곳에만 남겼다. helper 접근 범위는 test module 내부로만 넓어졌고 production API와 동작은 변경하지 않았다.
- Xcode test target에 모든 새 파일을 명시적으로 등록했다. 최신 PR #12 head와 비교해 178개 test 이름에 missing, added, duplicate가 없고, 이동한 BatteryGuard/ChargeController test method body가 동일함을 확인했다.
- 혹독 리뷰에서 원본 header를 모든 새 파일에 복사해 불필요한 framework dependency가 남은 점을 수정해 각 파일의 import를 실제 사용 범위로 축소했다.
- strict-concurrency complete와 warnings-as-errors에서 전체 178개 테스트가 통과했다. production source diff와 실제 battery/SMC 명령 실행은 0이다.

PR #12와 #13은 순서대로 `main`에 병합됐고, 갱신된 `main`에서 178개 strict tests, Release build와 Debug analyze가 통과했다.

### 0.23 PR #12 영향 범위 실기 재검증 결과 (2026-08-07)

사용자 승인 뒤 갱신된 `main`의 Release 앱 한 인스턴스로 실제 battery CLI v1.3.4와 하드웨어를 재검증했다.

- 시작 상태는 82%, AC attached, charging disabled, not discharging, Maintain 80이었다. PID 파일은 exact `/bin/bash /usr/local/co.palokaj.battery/battery maintain_synchronous 80` worker를 가리켰고 ownership journal은 `batteryGuard`, lastLimit 80이었다.
- 실제 온도 35.4°C에서 Heat threshold를 40→34°C로 낮추자 UI가 `열 보호 작동 중`으로 전이하고 exact worker와 PID 파일이 제거됐다. status는 charging disabled/not discharging을 유지했다.
- Heat Protection을 끄자 exact Maintain 80 worker가 다시 생성됐다. 다시 활성화한 뒤 threshold를 34→40°C로 되돌리자 hysteresis를 통과해 Maintain 80이 자동 복원됐다. 최종 설정은 원래 값인 Heat 활성/40°C다.
- Amphetamine 무제한 세션을 종료한 뒤 software sleep을 수행했다. `pmset`은 14:38:03 Sleep 진입과 14:38:23 Deep Idle wake를 기록했다. wake 직후 진단 로그가 full tuple과 동일한 worker PID를 포함한 Maintain 80 재검증 성공을 기록했다.
- Amphetamine 무제한 세션을 복원했다. 최종 상태는 82%, AC attached, charging disabled, not discharging, exact Maintain 80 worker 1개, PID 파일 일치, ownership `batteryGuard`, Heat 활성/40°C, MagSafe LED 제어 비활성이다.
- 모든 전이가 verified safe state로 끝나 별도 실패 복구는 필요하지 않았다. 실제 검사 중 하드웨어 상태가 불명확해지는 경로는 발생하지 않았다.

계획된 코드 작업과 승인 기반 하드웨어 gate는 모두 완료됐다. 이후 작업은 실제 결함이나 새로운 요구가 생길 때 별도 범위로 시작한다.

### 0.24 PR #14 sleep charging protection 결과 (2026-08-07)

- IOKit callback에서 절대 monotonic deadline을 즉시 시작하고, 응답은 별도 MainActor hop 없이 thread-safe responder가 완료한다. 같은 deadline에서 2초 응답 여유를 뺀 잔여 시간을 Top Up/Discharge 취소, bounded/capped worker probe, `charging off`와 전체 tuple 검증에 전파한다. 중복 sleep 요청은 한 작업을 공유하며 timeout 뒤에도 안전 정리는 계속된다.
- Wake는 온도 제어보다 먼저 실제 tuple을 읽어 Terminal drift를 보존하고, BatteryGuard가 검증한 sleep-protected 상태에서만 Maintain을 복원한다. 중단된 Top Up/Discharge는 자동 재개하지 않는다. 자발적 sleep은 drift/불확실 상태에서 reject하고, shutdown은 첫 await 전에 lifecycle을 소유하며 진행 중인 sleep negotiation/forced transition에서는 충전 비활성을 유지한다.
- 전역 Boolean `SleepDisabled`의 소유권을 증명할 수 없으므로 charge-to-limit sleep inhibition과 watchdog은 제거했다. 기능 기본값은 실제 lid-close 검증 전까지 비활성이다. 강제 sleep은 macOS가 veto를 허용하지 않아 준비 실패를 되돌릴 수 없다는 제한을 UI에 명시했다.
- strict-concurrency complete와 warnings-as-errors에서 전체 204개 테스트, Release build와 Debug analyze가 통과했다. 실제 battery/SMC 명령과 lid-close 하드웨어 검증은 실행하지 않았다.

### 0.25 PR #15 누적 안전 보완 실기 검증 결과 (2026-08-07)

사용자 승인 뒤 `/Applications/BatteryGuard.app`의 PR #15 Release 빌드와 실제 battery CLI v1.3.4로 체크포인트 17의 sleep/Discharge 경계를 검증했다.

- lid close에서 기존 Maintain 80 worker를 종료하고 charging disabled를 검증한 뒤 `Clamshell Sleep`에 진입했다. lid wake 직후 새 exact Maintain 80 worker가 생성됐다.
- 열린 덮개에서 `Idle Sleep`, `pmset sleepnow`의 non-vetoable `Software Sleep`, DarkWake와 Maintenance Sleep을 확인했다. 각 full wake 뒤 charging disabled/not discharging/Maintain 80과 exact worker가 복원됐다.
- forced sleep negotiation에서 worker 종료를 감지해 앱을 정상 종료했다. 앱과 worker가 없는 약 51분 동안 charging disabled와 80%가 유지됐고, 재실행 뒤 Maintain 80이 복원됐다.
- 실제 Discharge 전에 BatteryGuard와 CLI `caffeinate` sleep assertion이 모두 생성됐다. Discharge 중단 뒤 두 assertion이 해제되고 exact Maintain 75 worker가 복원됐다.
- Debug 빌드에서 `IOPMAssertionCreateWithName` 한 호출만 실패로 반환했다. Discharge/caffeinate가 시작되지 않고 기존 Maintain 75 worker와 hardware tuple이 그대로 유지됐다. debugger attach 중 UI 정지는 검증 장치의 영향이며 detach 뒤 정상 복구됐다.
- 최종 상태는 80%, AC attached, charging disabled, not discharging, exact Maintain 80 worker 1개, PID 파일 일치, ownership `batteryGuard`/lastLimit 80, Heat 활성/40°C, Sleep Protection `pauseOnSleep`이다. 기존 Amphetamine 무제한 세션도 원래 설정으로 복원했다.

하드웨어 안전 전이는 모두 통과했다. 검증 중 100개짜리 diagnostics ring에서 5초 간격의 성공 SMC command가 장시간 sleep 중 중요한 `prepare battery for system sleep` 이벤트를 밀어내는 결함을 발견했다. `control`/`lifecycle`과 실패 이벤트, long-running 문맥, 성공 command 순서로 retention priority를 적용하고 count/byte limit 모두 가장 오래된 최저 우선순위 이벤트부터 제거하도록 수정했다. 실제 유실 패턴을 고정한 회귀 테스트를 포함해 strict-concurrency complete와 warnings-as-errors에서 전체 228개 테스트, Release build와 Debug analyze가 통과했다.

## 1. 프로젝트 전제

BatteryGuard는 공개 배포 제품이 아니라 실제 사용자 한 명이 자신의 Apple Silicon Mac에서 사용하는 로컬 macOS 앱이다. 따라서 공개 배포, 다중 사용자 지원, 범용 하드웨어 지원보다 실제 배터리 제어의 안전성, 정확성, 장애 복구와 장기 유지보수를 우선한다.

이 계획은 80% 충전 제한뿐 아니라 Maintain, Top Up, Discharge, Heat Protection 같은 고급 제어 기능을 계속 사용한다는 전제다.

- 고급 제어가 필요하면 BatteryGuard를 충전 제어의 단일 소유자로 두고 macOS 기본 Charge Limit와 동시에 사용하지 않는다.
- 단순히 80% 충전 제한만 필요하면 macOS 기본 Charge Limit를 사용하고 BatteryGuard를 모니터링과 이력 조회 중심으로 축소하는 편이 낫다.
- 두 제어 방식을 동시에 활성화하지 않는다. 충전 제어 소유권 변경은 명시적인 제품 결정으로 취급한다.

## 2. 핵심 설계 원칙

```text
UI intent -> @MainActor ChargeController -> BatteryCommandRunner actor -> battery CLI
                  ^                              |
IOKit readings ---+                    result + verified CLI status
```

- IOKit은 배터리 잔량, 온도, 전류 등 측정값의 원본이다.
- 검증된 CLI 상태는 실제 충전 제어 상태의 원본이다.
- UI 상태는 IOKit 측정값과 검증된 CLI 상태에서 파생한다.
- 충전 상태는 여러 독립 Boolean이 아니라 하나의 상호 배타적 상태로 표현한다.
- 모든 하드웨어 제어 명령은 하나의 명령 실행기를 통과한다.
- 프로세스를 시작한 사실을 명령 성공으로 취급하지 않는다.
- 하드웨어 안전과 직접 관련 없는 추상화는 실제 필요가 생기기 전까지 추가하지 않는다.
- 기존 View, IOKit 모니터링과 이력 코드는 재사용하고, 위험한 프로세스 실행과 상태 관리 내부를 점진적으로 교체한다.
- 앱 전체를 한 번에 다시 작성하지 않는다. 각 단계는 독립적으로 되돌릴 수 있는 작은 커밋으로 만든다.

## 3. 단계별 구현 계획

### 3.1 즉시 위험한 동작 봉합과 안전한 테스트 기반 `[PR #3 완료]`

대규모 리팩터링보다 먼저 현재 코드가 실제 배터리에 잘못된 명령을 전달할 수 있는 경로를 차단한다.

#### 수정 내용

- 저장된 충전 제한값과 온도 임계값을 앱 시작 시 유효 범위로 보정한다.
- 설정을 저장할 때뿐 아니라 읽을 때와 명령으로 변환할 때도 값을 검증한다.
- 명령 실행 중 관련 버튼과 슬라이더의 중복 조작을 차단한다.
- 빠른 슬라이더 변경은 마지막 요청만 실행하도록 합친다.
- Heat Protection 활성화 중 Top Up, Discharge, maintain 변경이나 슬라이더 조작이 보호 상태를 우회하지 못하게 한다.
- 충전 차단 명령이 성공하고 실제 상태가 확인된 뒤에만 `heatProtectionTriggered`에 해당하는 상태로 진입한다.
- Heat Protection을 끌 때 이전에 유효했던 충전 상태로 명시적으로 복원한다.
- LED 기능을 끄거나 외부 전원이 분리되면 자동 LED 상태로 복원한다.
- 명령 이름 문자열을 광범위하게 찾는 `pkill -f` 방식을 제거한다.
- 명령 실패를 무시하지 않고 최소한 UI 오류와 로컬 진단 로그로 남긴다.
- 누락된 온도, 건강도, 전류 값을 `0`, `100%` 같은 정상적인 측정값으로 위장하지 않는다.
- `ChargeController`가 주입된 `ChargeBackend`를 사용하게 하고 테스트는 가짜 backend만 사용한다.
- 이력 테스트는 인메모리 Core Data store를 사용한다. 별도 구현이 실제로 필요해지기 전에는 `BatteryHistoryStore` 프로토콜을 추가하지 않는다.
- 로그인 항목은 작은 래퍼로 격리하고 기본 테스트에서 실제 `SMAppService`를 변경하지 않는다.
- 앱이 XCTest host로 시작될 때 실제 CLI, SMC, 로그인 항목과 운영 이력을 초기화하지 않는다.

#### 이유

구조 개선 작업 중에도 앱은 실제 하드웨어를 계속 제어할 수 있다. 테스트 구조나 코드 정리보다 현재의 잘못된 충전 전환과 거짓 성공 표시를 먼저 막아야 한다.

#### 완료 기준

- 빠르게 같은 버튼을 여러 번 눌러도 명령이 겹치지 않는다.
- Heat Protection 상태에서는 다른 기능이 충전을 재개하지 못한다.
- 명령 실패 후 UI가 성공한 것처럼 표시되지 않는다.
- 잘못된 저장값이 실제 CLI 인자로 전달되지 않는다.
- LED 제어를 해제하면 자동 동작으로 복원된다.
- 기본 테스트 전체를 실행해도 실제 충전 상태, 로그인 항목과 사용자 이력이 변하지 않는다.
- 성공, 실패, timeout, 취소와 오래된 완료를 fake backend 또는 fixture executable로 재현할 수 있다.

#### 3.1에 통합된 테스트 경계

1인용 앱에 불필요한 서비스 계층을 만들지 않는다. 1단계에서 다음 경계만 도입했고 이후 단계의 안전한 리팩터링 기반으로 계속 사용한다.

```swift
protocol ChargeBackend
BatteryHistory(inMemory: true)
```

로그인 항목 동작을 테스트할 필요가 있으면 `SMAppService`를 감싸는 작은 래퍼를 추가한다. Clock, LED, 설정 저장소 등을 처음부터 모두 프로토콜로 만들지 않는다.

#### 수정 내용

- `ChargeController.shared`가 실제 CLI를 직접 호출하지 않고 주입된 `ChargeBackend`를 사용하게 한다.
- 테스트에서는 가짜 `ChargeBackend`로 명령 성공, 실패, 지연, timeout과 취소를 제어한다.
- 이력 테스트는 인메모리 저장소나 인메모리 Core Data store를 사용한다.
- 기본 자동 테스트에서 실제 `battery` CLI를 실행하지 않는다.
- 기본 자동 테스트에서 실제 로그인 항목을 등록하거나 해제하지 않는다.
- 기본 자동 테스트에서 운영 Core Data store를 읽거나 수정하지 않는다.
- 실제 하드웨어 테스트는 별도 수동 체크리스트 또는 명시적으로 opt-in한 테스트로 분리한다.
- 단순히 실행 중 크래시가 발생하지 않는지만 확인하는 테스트는 상태, 결과 또는 부작용을 검증하도록 교체한다.

#### 이유

현재 테스트는 시스템 상태와 실제 배터리 제어에 영향을 줄 수 있어 반복 실행하기 어렵다. 안전한 테스트 기반이 없으면 이후 명령 실행기와 상태 모델을 신뢰성 있게 리팩터링할 수 없다.

#### 완료 기준

- 기본 테스트 전체를 실행해도 실제 충전 상태, 로그인 항목과 사용자 이력이 변하지 않는다.
- 성공뿐 아니라 실패, timeout과 취소 상태를 가짜 backend로 재현할 수 있다.
- 테스트 순서와 현재 Mac의 배터리 상태가 결과에 영향을 주지 않는다.

### 3.2 `BatteryCommandRunner`로 CLI 실행 통합 `[PR #3 완료]`

모든 CLI 실행을 하나의 actor에 모아 명령 수명주기와 동시성을 통제한다.

#### 책임

- 단발성 명령 실행과 장기 실행 명령의 시작을 하나의 FIFO 큐에서 직렬화한다.
- 장기 실행 프로세스가 동작 중이어도 상태 조회는 허용하되, 새 프로세스의 시작 순서는 실행기가 통제한다.
- 프로세스 종료까지 기다린다.
- exit code, stdout과 stderr를 수집하고 출력 크기를 제한한다.
- wall clock 변경의 영향을 받지 않는 monotonic clock으로 명령별 실제 제한시간을 적용한다.
- 각 명령을 독립 process group으로 시작한다.
- timeout 또는 취소 시 process group 전체에 정상 종료를 요청하고, 정해진 시간 안에 종료되지 않으면 group 전체를 강제 종료한다.
- Task 취소를 하위 프로세스 취소로 전달한다.
- 실행 중인 프로세스와 명령 ID를 추적한다.
- 취소나 정리 실패 시 실행기를 terminal failure 상태로 전환해 이후 명령을 거부한다.
- 호출자에게 단순 Boolean이 아니라 구체적인 결과를 반환한다.

```swift
struct BatteryCommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let termination: TerminationReason
}
```

`BatteryCommandRunner`는 프로세스 사실만 반환한다. `SMCKit`의 의미 단위 명령은 제어 명령 시작부터 결과 검사와 후속 status 검증까지 하나의 operation gate 안에서 실행한다. `BatteryControlStatus`가 기대 상태와 일치하지 않으면 실패시키며, 장기 실행 명령의 시작 검증이 실패하면 시작한 process group을 반드시 정리한다. 프로세스 계층이 CLI 출력 형식이나 충전 정책을 알게 만들지 않는다.

초기화가 완료되기 전에 사용자가 제어 명령을 시작할 수 있으면 초기 maintain과 사용자 요청이 경쟁한다. 따라서 원래 lifecycle 단계에서 다룰 readiness gate의 최소 부분을 이 단계로 당긴다.

- 초기 CLI 상태 조회와 최초 maintain 검증이 끝날 때까지 제어 UI를 비활성화한다.
- 초기화 실패를 별도 readiness 상태로 보존하고 성공한 것처럼 제어를 열지 않는다.
- 일반 종료에서는 persistent maintain을 중단하지 않는다.
- 현재 CLI가 중단 결과를 신뢰성 있게 관찰할 수 없는 `stopMaintain` API는 노출하지 않는다. 명시적인 `Disable BatteryGuard Control`은 3.4에서 검증 가능한 상태 정의와 함께 구현한다.

#### 명령 성공 규칙

- 프로세스 생성 성공은 명령 성공이 아니다.
- exit code가 성공이어도 기대 상태가 확인되지 않으면 제어 명령은 성공이 아니다.
- maintain 제한 변경은 최초 실행뿐 아니라 매번 변경 후 확인한다.
- timeout, Task 취소, 비정상 종료와 상태 검증 실패를 서로 다른 오류로 보존한다.
- maintain처럼 stdout을 버리는 명령도 실패 진단용 stderr는 보존한다.

#### 이유

현재 방식처럼 프로세스를 시작한 즉시 성공으로 처리하면 UI 상태, Heat Protection과 종료 처리가 모두 추측에 의존한다. 신뢰할 수 있는 명령 결과가 나머지 상태 설계의 기반이다.

#### 완료 기준

- 모든 배터리 CLI 호출이 명령 실행기를 통과한다.
- 오류 메시지와 stderr가 사라지지 않는다.
- timeout 후 고아 프로세스가 남지 않는다.
- timeout과 취소 후 명령이 만든 자식 프로세스도 남지 않는다.
- 단발성 명령과 장기 실행 시작의 FIFO 순서가 보장된다.
- 제어 명령과 후속 status 검증 사이에 다른 제어 명령이 끼어들지 않는다.
- 장기 실행 시작 후 status 조회 또는 파싱이 실패하면 시작한 process group이 정리된다.
- 초기화와 최초 maintain 검증이 끝나기 전에는 사용자 제어가 실행되지 않는다.
- UI는 상태 검증이 끝난 뒤에만 성공 상태로 전환된다.
- 명령 실행기 테스트는 임시 fixture executable만 사용한다.

#### 이후 단계에 미치는 영향

- 3.3의 단일 상태 모델 도입 순서와 범위는 바뀌지 않는다. readiness는 충전 모드의 대체물이 아니라 초기화 경계다.
- 3.4의 시작/종료 정책 중 초기화 readiness gate만 선행 구현한다. launch/wake/crash reconciliation과 명시적인 제어 해제 기능은 그대로 3.4에서 구현한다.
- process group, 원자적 검증, stderr와 출력 상한 관련 자동 테스트는 3.8에서 기다리지 않고 이 단계의 회귀 테스트로 당긴다. 3.8은 전체 상태 전이와 실제 하드웨어 검증을 계속 담당한다.

### 3.3 단일 충전 상태 모델 도입 `[PR #3 완료]`

여러 Boolean이 독립적으로 움직이는 현재 구조를 하나의 명시적인 상태로 교체한다. 별도의 Redux, 이벤트 버스나 범용 reducer 프레임워크는 도입하지 않는다.

```swift
enum ChargeMode: Equatable {
    case idle
    case maintaining(limit: Int)
    case toppingUp
    case discharging(target: Int)
    case heatBlocked(previous: RestorableMode)
    case transitioning(OperationID)
    case failed(ChargeError)
}
```

#### 상태 규칙

- 한 번에 하나의 충전 모드만 활성화한다.
- 모든 상태 변경은 명시적인 전이 함수를 통과한다.
- UI용 Boolean은 상태에서 계산하며 별도로 저장하지 않는다.
- 각 비동기 작업에 operation ID 또는 generation을 부여한다.
- 오래된 비동기 완료는 더 새로운 사용자 요청의 상태를 덮어쓸 수 없다.
- `ChargeController`, `BatteryMonitor`, `UserSettings`처럼 UI가 소유하는 공유 observable 상태의 main-actor 격리를 명시한다.
- `BatteryHistory`는 Core Data context의 queue 경계를 지키고, Swift strict-concurrency 검사에서 새 경고를 만들지 않도록 호출 경계를 정리한다.
- 명령 실행 중 새로운 요청을 거부할지, 취소할지, 합칠지를 기능별로 명시한다.
- 실패 시 무조건 `idle`로 숨기지 않고 원인과 마지막 확인 상태를 보존한다.
- 앱이 기대한 상태와 CLI가 보고한 상태가 다르면 실제 확인 상태를 우선하고 drift를 기록한다.

#### 이유

현재 발생 가능한 모순 상태 대부분은 명령 자체보다 독립적으로 저장된 Boolean에서 나온다. 단일 상태 모델은 불가능한 상태를 표현하기 어렵게 만들고 기능 충돌을 중앙에서 통제한다.

#### 완료 기준

- 충전 제어 상태의 원본이 하나뿐이다.
- Maintain, Top Up, Discharge와 Heat Protection이 동시에 활성 상태로 표현될 수 없다.
- 오래된 명령 완료가 최신 상태를 변경하지 않는다.
- 모든 허용 전이와 거부 전이에 단위 테스트가 있다.
- 상태 계층의 actor 격리가 코드에 표현되고 strict-concurrency 경고를 다음 단계로 새로 전파하지 않는다.

### 3.4 시작, 종료, 크래시와 절전 정책 구현 `[PR #6 구현, PR #8 실기 검증 완료]`

앱의 메모리 상태가 아니라 실제 CLI와 배터리 상태를 기준으로 복구한다.

#### 권장 소유권 정책

- 지속적인 maintain 동작은 CLI가 소유한다.
- BatteryGuard는 이를 제어하고 관찰하는 UI와 정책 계층이다.
- 일반적인 앱 종료는 `maintainStop`을 자동 실행하지 않는다.
- 충전 제어를 완전히 중단하려면 별도의 명시적인 `Disable BatteryGuard Control` 동작을 제공한다.
- 앱 종료 중에는 새로운 명령을 받지 않고 실행 중인 단발성 작업만 안전하게 정리한다.

#### 상태 조정 시점

- 앱 시작
- 시스템 wake
- 모든 제어 명령 완료
- 온도 보호 상태 전환
- 설정값 변경
- 일정한 저빈도 주기 또는 앱 활성화 시점

#### 복구 정책

| 상황 | 필요한 동작 |
|---|---|
| 앱이 maintain 중 크래시 | 재실행 시 CLI 상태를 읽고 실제 maintain 상태를 표시한다. |
| Top Up 중 크래시 | 재실행 시 실제 상태를 확인하고 정의된 안전 상태로 복귀한다. |
| Discharge 중 크래시 | 실행 상태와 현재 잔량을 확인한 뒤 계속할지 중단할지 정책에 따라 처리한다. |
| 명령 실행 중 sleep | wake 후 이전 완료 콜백을 신뢰하지 않고 상태와 온도를 다시 확인한다. |
| Terminal에서 CLI 변경 | 다음 reconciliation에서 drift를 감지하고 UI를 실제 상태로 조정한다. |
| 온도 센서 읽기 실패 | 0°C로 취급하지 않고 보호 상태가 불명확함을 표시하며 자동 충전 결정을 피한다. |
| CLI status 조회 실패 | 마지막 상태를 확정 상태처럼 보여주지 않고 stale 또는 unknown 상태로 표시한다. |

#### 이유

사용자가 한 명이어도 앱 크래시, 강제 종료, sleep/wake와 Terminal을 통한 외부 변경은 발생한다. 이 정책이 없으면 앱 UI가 실제 충전 상태와 쉽게 어긋난다.

#### 완료 기준

- 앱 재실행 후 현재 CLI 상태가 UI에 반영된다.
- 일반 종료 후 maintain 동작이 의도치 않게 중단되지 않는다.
- wake 후 온도와 제어 상태를 다시 확인한다.
- 외부 CLI 변경을 영구적으로 덮어쓰거나 무시하지 않는다.
- 상태를 확인할 수 없을 때 UI가 확정적인 성공 상태를 표시하지 않는다.

### 3.5 Heat Protection, Top Up과 Discharge 재구현 `[PR #3 구현, PR #4 누적 리뷰 보완 완료]`

각 기능을 독립 Boolean과 임시 명령 조합이 아니라 단일 상태 모델 위의 전이로 구현한다.

#### Heat Protection

1. 유효한 온도 측정값이 임계값을 초과한다.
2. 복원 가능한 현재 상태를 보관한다.
3. 충전 차단 명령을 실행한다.
4. 실제 충전 차단 상태를 확인한다.
5. 확인에 성공한 뒤 `heatBlocked` 상태로 진입한다.
6. 온도가 복귀 임계값 아래로 내려갈 때까지 hysteresis를 적용한다.
7. 온도와 CLI 상태를 다시 확인한 뒤 이전의 유효한 상태를 복원한다.

추가 규칙:

- 온도 센서가 실패하면 보호 기능이 정상 작동 중인 것처럼 표시하지 않는다.
- Heat Protection이 활성화된 동안 Top Up, Discharge와 maintain 변경이 충전 차단을 우회하지 못한다.
- 사용자가 Heat Protection을 끌 때 자동 복원 여부와 대상 상태를 명시적으로 결정한다.
- 차단 또는 복원 명령 실패를 로컬 로그와 UI에 표시한다.

#### Top Up

- Maintain과 Discharge를 동시에 실행하지 않는다.
- 시작 전 Heat Protection과 센서 상태를 확인한다.
- 취소 또는 목표 도달 후 복귀할 maintain 상태를 시작 시점에 기록한다.
- 종료 후 실제 상태를 확인하고 원래 maintain 설정으로 복원한다.

#### Discharge

- Maintain과 Top Up을 동시에 실행하지 않는다.
- 유효한 목표 잔량만 허용한다.
- 취소, 목표 도달, 외부 전원 변경과 앱 재실행의 복귀 정책을 명시한다.
- 실패 시 현재 실제 상태를 확인하고 사용자가 복구 동작을 선택할 수 있게 한다.

#### 이유

기능을 각각 따로 수정하면 다른 기능이 보호 상태를 다시 무효화할 수 있다. 공통 상태 전이 규칙 위에서 함께 구현해야 안전 조건을 보장할 수 있다.

#### 완료 기준

- 모든 기능 조합에 허용 또는 거부 규칙이 있다.
- Heat Protection을 우회하는 경로가 없다.
- 취소, timeout과 명령 실패 후 복귀 상태가 테스트된다.
- 기능 종료 후 실제 상태 검증이 수행된다.

### 3.6 외부 CLI 사전 검사와 macOS 기본 기능 충돌 방지 `[PR #6 구현 완료, native 상태 자동 감지는 제한 명시]`

자동 설치기나 거대한 업데이트 시스템은 만들지 않는다. 다만 root 권한으로 동작할 수 있는 외부 실행 파일을 단순히 존재 여부만으로 신뢰하지 않는다.

#### 최소 사전 검사

- 예상된 절대 경로에 있는지 확인한다.
- 실행 가능한 일반 파일인지 확인한다.
- symlink인 경우 예상된 안전한 대상을 가리키는지 확인한다.
- owner와 group이 예상과 일치하는지 확인한다.
- 일반 사용자가 실행 파일을 수정할 수 없는 권한인지 확인한다.
- 지원하는 최소 CLI 버전 이상인지 확인한다.
- 앱이 사용하는 명령과 status 형식을 지원하는지 확인한다.
- 검사 실패 시 하드웨어 제어 기능을 비활성화하고 구체적인 수동 복구 방법을 안내한다.

#### 설치와 업데이트 정책

- 앱이 root 권한 설치를 자동으로 수행하지 않는다.
- unpinned `curl | bash` 명령을 실행하거나 권장하지 않는다.
- 한 명의 사용자를 위해 checksum 다운로드 시스템이나 자동 업데이트 프레임워크를 만들지 않는다.
- 사용자가 수동으로 CLI를 변경한 뒤 앱을 다시 시작하면 preflight를 재실행한다.

#### macOS 기본 Charge Limit 충돌

- BatteryGuard가 고급 제어를 소유하는 경우 macOS 기본 Charge Limit를 함께 사용하지 않는다는 전제를 UI나 로컬 문서에 표시한다.
- 가능한 범위에서 충돌 가능성을 감지하고 경고한다.
- 두 시스템 중 어느 쪽이 제어를 소유할지 사용자가 명시적으로 선택하도록 한다.
- 단순 80% 제한만 필요한 경우 BatteryGuard 제어 기능을 끄고 native 기능 사용을 권장한다.

#### 이유

실행 파일 변조나 버전 불일치는 같은 사용자의 Mac과 배터리에 직접 영향을 준다. 반면 자동 설치와 배포 시스템은 1인용 앱의 유지보수 비용만 늘린다.

#### 완료 기준

- 부적절한 owner, 권한, symlink 또는 버전의 CLI를 실행하지 않는다.
- preflight 실패가 충전 명령 실패와 구분되어 표시된다.
- 두 충전 제어 시스템을 동시에 사용하는 위험이 사용자에게 명확하다.

### 3.7 모니터링, 이력과 UI 정확성 개선 `[PR #4 구현 및 누적 리뷰 보완 완료]`

안전성과 제어 상태가 안정된 뒤 측정, 저장과 표시의 정확성을 정리한다.

#### 수정 내용

- 알 수 없는 배터리 건강도를 100%로 표시하지 않고 optional 또는 unknown으로 표현한다.
- amperage의 단위, 부호와 충전/방전 방향 변환을 실제 IOKit 값 기준으로 검증한다.
- 온도, 전류와 건강도 데이터에 값 없음 상태를 유지한다.
- Core Data 저장과 fetch 오류를 무시하지 않고 진단 로그에 기록한다.
- downsampling 계산이 최대 포인트 수를 실제로 보장하도록 수정한다.
- 값이 변하지 않는 구간을 차트와 이력에서 어떻게 표현할지 결정하고 필요하면 저빈도 heartbeat를 저장한다.
- 로그인 항목의 `.requiresApproval` 상태를 단순히 비활성으로 표시하지 않는다.
- 앱 버전은 하드코딩하지 않고 Bundle metadata에서 읽는다.
- 혼합 언어는 실제 사용에 불편한 화면부터 일관되게 정리하되 전체 localization 시스템은 만들지 않는다.
- 앱 activation policy와 메뉴 상태가 화면 전환 후 올바르게 복원되는지 확인한다.

#### 로컬 진단 로그

최근 50~100건 정도의 순환 로그를 로컬에 유지한다.

- timestamp
- operation ID
- 요청한 기능과 인자
- 프로세스 exit code와 종료 이유
- timeout 또는 취소 여부
- stderr 요약
- 명령 전후에 확인된 CLI 상태
- reconciliation에서 발견한 drift
- 온도 보호 전이와 센서 실패

클라우드 텔레메트리나 원격 수집은 추가하지 않는다.

#### 이유

유일한 사용자가 문제를 겪었을 때 원인을 직접 확인할 수 있어야 한다. 측정값과 UI가 그럴듯한 거짓 값을 표시하면 하드웨어 제어 판단까지 잘못될 수 있다.

#### 완료 기준

- unknown 데이터가 정상 수치로 표시되지 않는다.
- 저장 실패가 조용히 사라지지 않는다.
- 차트 데이터 수가 설정된 상한을 넘지 않는다.
- UI 버전과 로그인 항목 상태가 시스템의 실제 상태를 반영한다.
- 최근 명령과 실패 원인을 로컬에서 확인할 수 있다.

### 3.8 자동 테스트와 실제 하드웨어 검증 `[PR #8 실기 검증, PR #11 자동 회귀 검증 완료]`

자동 테스트와 실제 하드웨어 검증을 명확히 분리한다.

#### 자동 단위 테스트

- 모든 허용 상태 전이
- 모든 거부 상태 전이
- 명령 성공과 상태 확인 성공
- 명령 성공 후 상태 확인 실패
- 프로세스 비정상 exit
- stderr 포함 오류
- timeout과 강제 종료
- Task 취소
- 오래된 operation 완료 무시
- 빠른 슬라이더 변경 합치기
- launch reconciliation
- wake reconciliation
- 외부 CLI 변경에 의한 drift
- Heat Protection 진입, 유지, 복원과 센서 실패
- Top Up과 Discharge의 완료, 취소와 실패 복귀
- 잘못된 설정값 보정

#### 명령 실행기 통합 테스트

- 임시 fixture executable을 사용한다.
- 성공, 실패, stderr 출력, 장시간 대기, signal 무시와 비정상 종료를 fixture로 재현한다.
- 실제 `battery` CLI를 사용하지 않는다.

#### 이력 테스트

- 인메모리 store만 사용한다.
- 저장 실패, fetch 실패, 데이터 없음과 downsampling 경계를 검증한다.
- 운영 이력 파일을 수정하지 않는다.

#### 수동 하드웨어 체크리스트

1. 시작 전 실제 `battery status`와 앱 상태를 기록한다.
2. maintain 제한을 안전한 범위 안에서 변경하고 실제 상태를 확인한다.
3. Top Up을 시작하고 취소한 뒤 원래 maintain 상태로 복원되는지 확인한다.
4. Discharge를 시작하고 취소한 뒤 실제 상태를 확인한다.
5. 안전하게 재현 가능한 방식으로 Heat Protection의 진입과 복원을 확인한다.
6. 앱을 정상 종료하고 persistent maintain 상태를 확인한다.
7. 앱을 강제 종료한 뒤 재실행하여 reconciliation을 확인한다.
8. sleep/wake 후 온도와 제어 상태 재확인을 확인한다.
9. Terminal에서 CLI 상태를 변경하고 앱이 drift를 감지하는지 확인한다.
10. 테스트 종료 후 사용자가 의도한 maintain 상태로 복원하고 최종 status를 기록한다.

실제 하드웨어 체크는 자동 테스트의 기본 실행 경로에 포함하지 않으며 사용자의 명시적 승인 없이 실행하지 않는다.

#### 이유

가짜 backend 테스트는 상태 로직을 안전하게 검증하지만 실제 CLI, 권한과 하드웨어 통합까지 보장하지는 않는다. 반대로 실제 하드웨어 테스트를 자동화하면 일상적인 테스트 실행이 위험해진다.

#### 완료 기준

- 기본 자동 테스트는 시스템과 하드웨어 상태를 변경하지 않는다.
- 모든 안전 관련 상태 전이와 실패 경로에 자동 테스트가 있다.
- 수동 하드웨어 체크 결과와 최종 복원 상태가 기록된다.

## 4. 실패 모드별 요구사항

| 실패 모드 | 오류 처리 | 테스트 | 사용자 표시 |
|---|---|---|---|
| CLI 프로세스 생성 실패 | 명령 실패로 반환 | fixture test | 실행 파일 또는 권한 오류 |
| CLI 비정상 종료 | exit code와 stderr 보존 | fixture test | 명령 실패와 stderr 요약 |
| CLI timeout | 해당 프로세스 종료 후 상태 재조회 | fixture test | timeout과 확인된 현재 상태 |
| 상태 확인 실패 | 성공 상태로 전환하지 않음 | backend test | 상태 확인 불가 또는 stale |
| 오래된 명령 완료 | operation ID 비교 후 무시 | state test | 불필요; 진단 로그만 기록 |
| startup 상태 불일치 | 실제 CLI 상태로 reconciliation | state test | 실제 상태 표시와 필요 시 경고 |
| sleep 중 상태 변경 | wake 시 온도와 CLI 재조회 | lifecycle test | 확인 중 상태 후 실제 상태 표시 |
| lid-close 중 maintain worker 정지 | sleep acknowledgement 전 Top Up/Discharge 취소, charging-off tuple 검증 | sleep lifecycle test | 잠자기 보호 상태와 실패 원인 |
| 외부 CLI 변경 | drift 감지 후 실제 상태 반영 | state test | 필요 시 외부 변경 안내 |
| 온도 센서 실패 | 자동 보호 결정을 중단하거나 제한 | heat test | Heat Protection degraded 경고 |
| Core Data 저장 실패 | 오류 기록, 앱 제어는 계속 | in-memory test | 필요 시 이력 저장 실패 표시 |
| CLI preflight 실패 | 모든 제어 명령 차단 | preflight test | 구체적인 수동 복구 안내 |

테스트도 없고 오류 처리도 없으며 사용자에게 조용히 숨겨지는 실패 경로는 완료된 것으로 간주하지 않는다.

## 5. 기존 코드 재사용 방침

- SwiftUI 화면 구조는 안전 상태를 올바르게 표시할 수 있는 범위에서 재사용한다.
- `BatteryMonitor`의 IOKit 측정 코드는 단위, optional 처리와 lifecycle을 보완하며 재사용한다.
- `BatteryHistory`의 기존 모델은 운영 store와 테스트 store를 분리하고 오류 처리를 추가해 재사용한다.
- `SMCKit`의 프로세스 실행 코드는 공개 API 호환이 도움이 되는 부분만 남기고 내부 실행을 `BatteryCommandRunner`로 교체한다.
- `ChargeController`는 UI와 상태 orchestration 역할을 유지하지만 직접 프로세스를 실행하지 않게 한다.
- `UserSettings`는 읽기와 쓰기 양쪽에서 유효값을 보장하도록 보완한다.
- 기존 기능을 단순히 새 이름의 서비스로 복제하지 않는다.

## 6. 명시적으로 범위에서 제외하는 작업

- GitHub Actions: 한 대의 개인 Mac에서 로컬 검증으로 충분하다.
- 브랜치 보호와 공개 저장소 관리 자동화: 개인 개발 흐름에 실질적인 안전 이득이 작다.
- 공개 배포용 LICENSE와 README 정비: 배포 계획이 생길 때 처리한다.
- Developer ID, notarization과 App Store 대응: 로컬 실행만 대상으로 한다.
- 전체 localization: 필요한 화면의 문구 일관성만 개선한다.
- Intel Mac 지원: 현재 사용하는 Apple Silicon Mac을 우선한다.
- 자동 업데이트: 앱과 CLI 모두 수동 업데이트로 충분하다.
- 자동 root 설치기: 위험과 유지보수 비용이 이득보다 크다.
- 완전한 아이콘과 마케팅 자산: 기능 안전과 무관하다.
- 엔터프라이즈식 다층 서비스 구조: 테스트에 필요한 최소 경계만 둔다.
- View를 포함한 100% 테스트 커버리지: 안전 경로와 실패 처리의 완전성을 우선한다.
- 클라우드 텔레메트리와 원격 로그: 로컬 진단 로그만 유지한다.
- 대규모 성능 최적화: 현재 규모에서는 프로세스 실행과 차트 상한 외에 우선할 병목이 없다.

## 7. 구현 체크포인트

각 단계는 기존 사용자 변경을 섞지 않은 독립 커밋으로 저장한다.

1. `[PR #3 완료]` 즉시 안전 가드, 가짜 backend, 안전한 테스트 저장소
2. `[PR #3 완료]` `BatteryCommandRunner`, descendant policy, 전체 timeout과 원자적 상태 검증
3. `[PR #3 완료]` privileged CLI preflight, 완전한 async readiness와 단일 `ChargeMode`
4. `[PR #3 완료]` lifecycle, Heat Protection, Top Up/Discharge와 generation 기반 LED
5. `[PR #3 구현, PR #8 실기 검증 완료]` 안전 실패 경로 자동 테스트와 통제된 Top Up/Discharge/Heat/quit/crash/sleep-wake 하드웨어 검증
6. `[PR #4 누적 리뷰 보완, PR #8 실기 재검증 완료]` 모니터링 단위·optional 검증, verified-limit 이력, 명시적 readiness/오류/상한/heartbeat, 로그인 승인 상태, Bundle 버전, 검증된 activation policy, correlated 로컬 순환 진단 로그, stale task/Heat rollback/wake/정상 종료 안전성 보완
7. `[PR #5 구현·누적 리뷰 보완, PR #8 실기 검증 완료]` target이 일치하는 exact worker와 process ownership을 포함한 read-only periodic/app-activation reconciliation, 종료 직전 fresh 검증, 재시도 가능한 종료 cleanup과 기대/실제 Terminal drift 복구 UI
8. `[PR #6 구현 및 자동 검증, PR #8 실기 검증 완료]` macOS native Charge Limit 제어 소유권 안내, crash-safe release intent와 명시적 `Disable BatteryGuard Control` UX
9. `[PR #7 구현 및 자동 검증 완료]` 동작 변경 없이 durable ownership journal과 순수 reconciliation policy를 각각 독립 파일/타입으로 분리하고 policy 경계 테스트 추가
10. `[PR #8 완료]` 실제 CLI 계약에 맞춘 Discharge 검증 수정, 전체 자동 검증과 승인된 하드웨어 checklist
11. `[PR #8 완료]` 초기 preflight 실패 종료, sleep assertion 수명, LED best-effort cleanup, temperature cache freshness와 PID start identity 재검증
12. `[PR #9 구현]` shutdown planning과 temperature freshness 계약 분리, 동일 경계에 맞춘 controller/policy 테스트 파일 분할
13. `[PR #10 구현]` Heat Protection decision을 pure policy로 분리하고 ownership·hysteresis·cooldown·fail-closed 경계 테스트 추가
14. `[PR #10 누적 리뷰 보완]` failure Boolean을 typed disposition으로 교체하고 stale long-running probe가 shutdown/new operation 뒤 상태를 바꾸지 못하게 generation 검증
15. `[PR #11 구현·혹독 리뷰 보완]` Top Up/Discharge long-running decision을 pure policy로 분리하고 target/liveness/recovery/drift 및 sleep assertion 수명 테스트 추가
16. `[완료: PR #14]` IOKit sleep acknowledgement 전 verified charging-off와 wake 시 Maintain 복원 추가. 전역 Boolean인 `SleepDisabled`는 외부 소유권을 증명할 수 없어 charge-to-limit sleep inhibition/lease/watchdog 설계는 hostile review 후 제거
17. `[구현·자동·실기 검증 및 진단 보존 보완 완료]` 누적 hostile review 보완: Discharge assertion 선획득, drift/manual failure를 보존하는 Heat 전이, 신규·분실 journal의 monitoring-only 기본값과 일회성 legacy migration, injectable IOKit transport 계약 테스트, process-group cleanup을 포함한 absolute deadline, typed issue/safety-temperature UI, backend capability 분리, exact CLI v1.3.4 및 실행 파일 identity 재검증, priority-aware bounded diagnostics, ownership directory hardening, history queue/extrema 보존, Release Hardened Runtime

핵심 단계가 `ChargeController`, CLI 실행과 상태 모델을 공유하므로 기본 구현은 순차적으로 진행한다. 모니터링과 이력 개선 중 상태 제어와 겹치지 않는 부분만 명령 실행기와 상태 모델이 안정된 뒤 별도로 진행할 수 있다.

## 8. 안전한 기본 검증 명령

```sh
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug build-for-testing
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Release build
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug analyze
```

- 실제 CLI, 로그인 항목과 운영 store가 격리되기 전에는 기존 전체 테스트를 실행하지 않는다.
- 실제 하드웨어 테스트는 사용자의 명시적 승인 후 수동으로 실행한다.
- 각 수동 검증 전후에 실제 status를 기록하고 테스트 종료 시 의도한 maintain 상태로 복원한다.
- 17번의 실제 Mac 검증에서 lid close, vetoable idle sleep, forced sleep, wake, sleep negotiation 중 Quit, Discharge assertion 실패/복구를 완료했다. 검증에서 발견한 diagnostics 우선순위 결함과 회귀 테스트도 완료했다.

## 9. 변경 거절 기준

다음 중 하나라도 해당하면 변경을 완료로 보거나 병합하지 않는다.

- 기본 테스트가 실제 배터리 CLI를 실행한다.
- 기본 테스트가 실제 로그인 항목이나 운영 Core Data store를 변경한다.
- 프로세스 종료와 exit code를 확인하기 전에 성공으로 처리한다.
- 제어 명령 후 실제 CLI 상태를 검증하지 않는다.
- 여러 독립 Boolean이 충전 제어 상태의 경쟁하는 원본으로 남아 있다.
- Heat Protection을 Top Up, Discharge, maintain 변경 또는 슬라이더가 우회할 수 있다.
- startup, quit, crash, sleep/wake와 외부 CLI 변경 동작이 정의되지 않는다.
- 뚜껑 닫힘 전에 충전 비활성 상태를 검증하지 않거나, external drift를 sleep/wake 과정에서 덮어쓴다.
- timeout 후 프로세스가 남을 수 있다.
- 오래된 비동기 완료가 최신 사용자 요청을 덮어쓸 수 있다.
- 온도나 건강도 측정 실패를 정상적인 숫자로 표시한다.
- privileged executable을 존재 여부만으로 신뢰한다.
- root 설치를 위해 unpinned `curl | bash`를 실행하거나 권장한다.
- 실패 경로 테스트 없이 성공 경로만 검증한다.
- 명령 또는 저장 실패가 조용히 무시되거나 성공으로 표시된다.
- macOS 기본 Charge Limit와 BatteryGuard의 제어 소유권이 불명확하다.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | not run | 개인용 앱 전제와 제품 범위는 기존 계획에서 이미 확정 |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | not run | 이번 작업은 기존 hostile reviews의 결과를 계획에 반영 |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | clean | 2 issues: SMC sample task lifetime, test topology debt; both scheduled independently |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | not needed | 새 UI 범위 없음 |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | not needed | 개인용 로컬 프로젝트이며 test topology만 후속 범위 |

**VERDICT:** ENG CLEARED — 핵심 계획은 완료됐고, stacked merge 뒤 PR #12와 PR #13만 순차 진행한다.

NO UNRESOLVED DECISIONS
