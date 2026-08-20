# BatteryGuard Sleep Charging Recovery Plan

## 1. 문제 정의

2026-08-20 조사 시점에 macOS와 IOKit은 충전기 연결을 정상적으로 감지하고 있었다.

- `pmset`: AC Power
- `AppleSmartBattery`: `ExternalConnected=Yes`, `ExternalChargeCapable=Yes`
- 현재 CLI 상태: `charging=disabled`, `discharging=false`, Maintain target `80`, Maintain worker `stopped`

앱이 충전기를 감지하지 못한 것이 아니라, 잠자기 준비 중 BatteryGuard가 만든 충전 제어 상태가 복구되지 않은 것이 근본 원인이다.

확인된 실패 순서는 다음과 같다.

1. BatteryGuard가 Maintain 80 worker를 정상적으로 시작했다.
2. 약 1.3초 뒤 잠자기 준비가 시작되어 worker를 중지하고 `battery charging off`를 실행했다.
3. 명령 직후 단 한 번 수행한 `status_csv` 검증이 일시적인 `discharging=true`를 관측했다.
4. controller가 상태를 `.failed(..., .manualIntervention)`으로 확정했다.
5. 실제 하드웨어 상태는 이후 `discharging=false`로 안정화됐지만 Maintain worker는 이미 종료된 상태였다.
6. 주기적·활성화 reconciliation은 의도적으로 read-only이므로 Maintain을 다시 시작하지 않았다.
7. UI는 물리적 전원 연결과 충전 제어 실패를 충분히 분리해서 보여주지 않아 사용자가 이를 “충전기 미감지”로 인식했다.

`discharging` bit가 왜 그 순간에만 true였는지는 당시 저수준 원자료가 남아 있지 않아 확정할 수 없다. 그러나 한 번의 과도 관측을 영구 실패로 확정하고 이후 복구할 수 없게 만든 application-level 결함은 코드와 diagnostics로 확인됐다. 이 계획은 특정 저수준 원인에 의존하지 않고 그 종류의 과도 상태 전체를 제한된 방식으로 흡수한다.

따라서 장기 해결의 핵심은 단순 재시도나 polling 주기 단축이 아니라 다음 세 경계를 바로잡는 것이다.

- 명령 완료와 하드웨어 상태 안정화 완료를 구분한다.
- 거부 가능한 idle sleep과 거부할 수 없는 forced sleep을 구분한다.
- read-only 재확인과 실제 하드웨어 복구를 구분한다.

## 2. 목표

1. 잠자기 준비 명령 직후의 짧은 과도 상태를 영구 실패로 오판하지 않는다.
2. 잠자기 승인 기한 안에서만 상태 안정화를 기다리고, 기한을 넘기거나 상태가 불명확하면 fail-closed 한다.
3. 강제 잠자기 실패를 idle sleep 실패와 동일하게 처리하지 않는다.
4. 성공적으로 보호된 잠자기에서 깨어나면 기존 Maintain 상태를 검증 후 복원한다.
5. 불확실한 하드웨어 실패는 자동으로 충전을 재개하지 않고 명시적인 사용자 복구만 허용한다.
6. UI에서 `전원 연결 여부`, `실제 충전 여부`, `BatteryGuard 제어 상태`를 서로 다른 사실로 표시한다.
7. 같은 종류의 실패가 다시 발생하면 원인과 모든 관측 상태를 하나의 operation ID로 재구성할 수 있게 한다.

## 3. 비목표

- macOS native Charge Limit과 BatteryGuard가 동시에 충전 제어를 소유하도록 만들지 않는다.
- 실패를 숨기기 위해 주기적 reconciliation이 자동으로 Maintain을 덮어쓰게 하지 않는다.
- 잠자기 준비 중 같은 mutation 명령을 반복 실행하지 않는다.
- UI refresh 주기나 전역 polling 빈도를 높이지 않는다.
- 별도의 daemon, privileged helper, 새로운 journal 또는 두 번째 backend 계층을 추가하지 않는다.
- 개인용 로컬 앱 범위를 넘어선 CI, 공증, App Store, Intel 지원 또는 배포 자동화를 추가하지 않는다.

## 4. 유지해야 할 안전 불변식

- CLI 명령 종료는 성공이 아니다. 완전한 control tuple과 worker 상태가 확인돼야 성공이다.
- 잠자기 보호 성공 조건은 정확히 `charging=disabled`, `discharging=false`, Maintain worker `stopped`이다.
- status 출력이 잘렸거나 파싱되지 않거나 worker가 stale/duplicate/unknown이면 성공으로 간주하지 않는다.
- 하나의 잠자기 준비 operation은 하나의 mutation만 수행한다. 이후 시도는 모두 read-only 검증이다.
- 모든 command, status read, controller transition, diagnostic은 동일한 semantic operation ID를 사용한다.
- absolute monotonic deadline을 한 번 계산하고 command와 모든 후속 검증이 같은 기한을 공유한다.
- deadline, cancellation 또는 더 새로운 generation 이후에는 추가 명령이나 상태 변경을 하지 않는다.
- 불확실한 실패에서는 자동 Maintain 복원을 금지한다. Heat Protection의 기존 자동 복구 권한도 침범하지 않는다.
- Discharge에서 잠자기로 전환할 때 sleep assertion은 충전 비활성 tuple이 검증된 뒤에만 해제한다.
- 주기적 및 앱 활성화 reconciliation은 계속 read-only로 유지한다.

## 5. 설계 변경

### 5.1 Backend에 bounded status settlement 도입

`SMCKit.prepareForSystemSleep`의 마지막 단일 status read를 제한된 read-only settlement로 교체한다. 같은 verifier를 이미 `.sleepProtected` 또는 `.heatBlocked`인 상태의 재검증에도 사용해 두 번째 IOKit 요청에서 one-shot 오판이 재발하지 않게 한다.

권장 흐름:

1. 기존처럼 runner 취소, semantic gate 획득, 사전 상태 기록, exact Maintain worker 종료, `charging off`를 각각 한 번 수행한다.
2. 즉시 완전한 status tuple을 읽는다.
3. 일치하지 않으면 mutation을 반복하지 않고 100ms, 250ms, 500ms, 1s backoff 뒤 다시 읽는다.
4. 어느 시점이든 완전한 disabled tuple이 확인되면 성공한다.
5. 전체 과정은 controller가 넘긴 absolute deadline에서 acknowledgement reserve를 제외한 동일 기한을 사용한다.
6. 다음 delay 또는 status command가 남은 기한을 넘기면 즉시 typed deadline failure로 종료한다.
7. cancellation, truncated output, process cleanup failure, worker ambiguity는 기존처럼 즉시 실패한다. 단순 tuple mismatch만 제한적으로 재검증한다.

구현은 `SMCKit` 내부의 작은 `verifyChargingDisabledUntilSettled(deadline:)` helper로 제한한다. 최초 mutation 경로와 mutation 없는 `verifyAlreadyProtected` 경로가 이를 공유한다. 테스트를 위해 monotonic `now`와 `sleep`만 주입 가능하게 하고 새로운 범용 scheduler나 service는 만들지 않는다.

결과에는 최소한 다음 정보가 포함되어야 한다.

- 마지막으로 관측한 `BatteryControlStatus`
- 각 관측의 operation 시작 대비 elapsed time
- 시도 횟수
- 종료 이유: verified, persistent mismatch, deadline, cancellation, read failure

이 정보는 UI 상태의 별도 source가 아니라 진단과 typed error를 위한 자료로만 사용한다.

### 5.2 시스템 잠자기 요청을 typed event로 전달

현재 `willSleep(deadline)` 콜백을 다음 의미를 담는 typed request로 바꾼다.

- `vetoableIdleSleep`: 준비 실패 시 IOKit 요청을 reject할 수 있음
- `forcedSystemSleep`: 뚜껑 닫기 등으로 reject할 수 없으며 준비 결과와 무관하게 acknowledgement는 allow해야 함

`systemWillNotSleep`과 `systemHasPoweredOn`도 하나의 무의미한 `didWake`로 합치지 않고 각각 typed completion event로 전달한다.

- `systemWillNotSleep`: idle sleep 협상이 취소됨
- `systemHasPoweredOn`: 실제 sleep 이후 깨어남

observer는 IOKit token을 정확히 한 번 해결하고, timeout 정책은 기존대로 vetoable이면 reject, forced이면 allow를 유지한다. Timeout, invalidation, observer stop은 acknowledgement를 해결하는 것에 그치지 않고 owning preparation Task를 취소해야 한다. Controller는 request kind와 generation을 함께 검증해 늦게 끝난 준비 작업이 새 wake 또는 새 sleep 요청을 덮어쓰지 못하게 한다.

각 IOKit request/token은 독립된 request ID와 generation을 갖는다. `canSystemSleep`과 뒤따를 수 있는 `systemWillSleep`을 동일 request라고 가정하지 않는다. 중복 mutation은 이벤트 순서 추정이 아니라 현재의 verified `.sleepProtected` 상태와 mutation 없는 재검증으로 방지한다. Semantic operation UUID는 diagnostics correlation용이고 numeric generation은 stale completion 차단용이므로 서로 대체하지 않는다.

### 5.3 Controller sleep 전이를 하나의 상태 머신으로 정리

별도 Boolean을 추가하지 않고 기존 `ChargeMode`와 typed transition/failure disposition에 잠자기 전이를 표현한다.

- 준비 시작: `.transitioning(.preparingForSleep(previous: ...))`
- 완전한 disabled tuple 검증 성공: `.sleepProtected(previous: ..., charge: ...)`
- 검증 불확실 또는 deadline 실패: 이전 모드와 원인을 보존한 `.failed(..., .manualIntervention)`

기존 `sleepChargingOffWasRequested`가 상태 결정의 독립 source로 남지 않게 제거하거나 `ChargeMode`에서 계산되는 값으로 축소한다. shutdown 정책 역시 Boolean이 아니라 typed sleep transition과 검증된 mode에서 계산한다.

UI가 오류 문자열을 해석해 복구 명령을 고르지 않도록 failure disposition도 typed recovery context를 운반하게 한다. 수동 복구 context는 failure origin, `none` 또는 `restoreMaintain(limit:)` target, 마지막으로 fresh read한 observed state를 포함한다. 이 값은 자동 실행 권한이 아니라 사용자가 누를 수 있는 검증된 복구 동작만 결정한다. 기존 `.heatProtection`만 Heat 자동 retry/restore 권한을 유지한다.

Forced sleep 준비가 불확실하게 실패한 뒤 wake에서 fresh status를 읽어도 `.manualIntervention` disposition과 recovery target은 유지한다. 관측값을 갱신하기 위해 mode를 `.externalDrift`로 교체하지 않는다. Observed state는 typed failure context에 갱신하며 charge state의 두 번째 source로 쓰지 않는다.

상황별 정책은 다음과 같다.

| 상황 | 처리 |
|---|---|
| Vetoable sleep + 검증 성공 | sleep 허용, `.sleepProtected` 유지 |
| Vetoable sleep + 실패 | sleep 거부, 실패 상태와 관측 tuple 표시, 자동 mutation 금지 |
| Vetoable sleep 취소 + 이미 검증 성공 | controller가 시작한 전이가 확실하므로 기존 wake 복원 경로로 Maintain을 검증 복원 |
| Forced sleep + 검증 성공 | sleep 허용, 잠든 동안 disabled 유지, wake에서 검증 복원 |
| Forced sleep + 불확실한 실패 | sleep은 허용하되 `.manualIntervention` 유지; wake에서 fresh status를 읽어 현황만 갱신하고 자동 충전 재개 금지 |
| Wake + `.sleepProtected` | fresh battery/temperature 및 exact status 확인 후 기존 Maintain 복원 |
| Wake + ownership이 system/monitoring-only | 어떤 mutation도 수행하지 않음 |

`systemWillSleep`이 `canSystemSleep`에 이어 들어와도 별도 request로 처리하되, 이미 검증된 `.sleepProtected` 상태는 mutation 없이 bounded 재검증만 한다.

### 5.4 명시적인 “Maintain 복원” 복구 동작 추가

현재 “다시 확인”은 read-only라서 `charging disabled + worker stopped` 상태를 고칠 수 없다. UI에 두 동작을 명확히 분리한다.

- `상태 다시 읽기`: 항상 read-only
- `Maintain 80% 복원`: 실제 hardware mutation을 수행하는 명시적 복구

복구 버튼은 다음 precondition을 모두 fresh read로 확인한 뒤에만 활성화한다.

- BatteryGuard ownership이 durable journal에서 `batteryGuard`
- native Charge Limit과의 소유권 선택이 이미 확인됨
- app initialization/readiness 완료
- 활성 Top Up/Discharge 또는 외부 long-running process 없음
- expected limit이 유효함
- Heat Protection 사용 시 fresh IOKit + independent SMC preflight가 모두 성공하고 안전 온도임
- 현재 status가 parse 가능하고 worker identity가 명확함

복구는 기존 `applyMaintain(level:)` transaction을 재사용하며 새 command path를 만들지 않는다. 명령 후 exact Maintain worker/target/charging/discharging tuple을 검증하고, fresh temperature postflight까지 성공해야 `.maintaining`으로 전환한다. 실패 시 `.manualIntervention`을 유지한다.

### 5.5 UI truthfulness 개선

기존 Dashboard의 전원 행과 recovery card는 재사용한다. Menu bar의 headline과 recovery card를 중심으로 다음 정보를 하나의 모호한 “충전 상태”로 표현하지 않게 한다.

- 전원: `연결됨` / `연결 안 됨` / `확인 불가` — IOKit 기준
- 배터리 전류: `충전 중` / `방전 중` / `0에 가까움` / `확인 불가` — 측정값 기준
- 제어: `Maintain 80% 정상` / `잠자기 보호로 일시 중지` / `외부 drift` / `복구 필요` — verified CLI 기준

이번 장애와 같은 경우에는 `전원 연결됨 · 충전 제어 복구 필요`를 우선 표시한다. “충전기 미연결” 또는 단순 “충전 일시정지”로 축약하지 않는다. 별도 timestamp UI는 실제 stale-display 문제가 hardware validation에서 재현될 때만 추가한다.

`BatteryMonitor`에는 이미 IOPowerSource/Darwin notification, 100ms~2s transition settlement, 저빈도 watchdog이 있으므로 이 계획에서 다시 작성하거나 polling을 늘리지 않는다. Hardware validation에서 실제 notification 누락이 별도로 입증될 때만 그 경계를 독립 결함으로 다룬다.

### 5.6 진단을 재현 가능한 transaction 기록으로 변경

잠자기 준비 lifecycle event에 다음 typed field를 남긴다.

- semantic operation ID와 request generation
- sleep request kind
- monotonic 시작/종료 및 acknowledgement deadline
- mutation command 결과
- 모든 settlement status tuple과 elapsed time
- 최종 acknowledgement decision
- wake/cancel event 및 복구 결과

원시 IOKit dictionary, battery identifier 또는 무제한 CLI 출력은 기록하지 않는다. lifecycle/safety/control 실패 이벤트는 즉시 flush하고, 앱 종료 flush barrier 이전에 제출 순서를 보장한다.

`BatteryControlStatus` 자체를 persistence model로 만들지 않는다. Optional Codable `SleepSettlementDiagnostic` DTO를 사용하고 `decodeIfPresent`로 기존 `[DiagnosticEvent]` 파일을 그대로 읽는다. 기존 로컬 형식의 reload/migration test를 추가하며, 호환 불가능한 representation 변경이 생기기 전에는 별도 schema-version envelope를 도입하지 않는다. 단순 문자열 조합을 UI나 복구 정책의 입력으로 사용하지 않는다.

## 6. 테스트 계획

### 6.1 Pure policy 및 backend tests

- 첫 status가 완전 일치하면 추가 sleep/read 없이 성공한다.
- `disabled + discharging=true + worker stopped` 뒤 `disabled + discharging=false + worker stopped`가 오면 성공한다.
- 이미 보호된 상태의 mutation 없는 재검증도 같은 transient sequence를 흡수한다.
- mismatch가 계속되면 bounded attempts 후 실패하며 mutation command는 정확히 한 번이다.
- charging enabled, stale/duplicate/unknown worker, truncated/invalid status는 성공하지 않는다.
- deadline 직전에는 새 sleep/read를 시작하지 않는다.
- cancellation은 즉시 전파되고 이후 read/mutation이 없다.
- 새 generation 뒤 이전 settlement 완료가 controller state를 바꾸지 않는다.
- 각 관측이 하나의 semantic operation ID로 진단에 연결된다.

시간 관련 테스트는 실제 수백 ms를 기다리지 않고 injected monotonic clock/sleeper를 사용한다.

### 6.2 SystemPowerObserver contract tests

- vetoable 요청 실패는 정확히 한 번 reject된다.
- forced 요청 실패는 준비 작업을 실행한 뒤 정확히 한 번 allow된다.
- timeout도 vetoable/forced 정책을 각각 유지한다.
- timeout, invalidation, observer stop은 owning preparation Task를 취소하고 late completion을 무시한다.
- `systemWillNotSleep`과 `systemHasPoweredOn`이 서로 다른 completion event로 전달된다.
- 중복 token, observer stop, app shutdown 중 pending token이 이중 해결되지 않는다.
- `canSystemSleep -> systemWillSleep` 연속 이벤트가 두 번 mutation하지 않는다.

### 6.3 Controller lifecycle tests

- transient discharge bit가 안정화되면 `.sleepProtected`가 되고 wake에서 Maintain 80이 복원된다.
- persistent mismatch는 `.manualIntervention`으로 남고 자동 Maintain이 실행되지 않는다.
- forced sleep 실패 후 wake는 fresh read만 수행하고 typed manual failure/target을 유지하며 자동 mutation하지 않는다.
- 취소된 vetoable sleep에서 이미 검증된 disabled 상태는 Maintain으로 한 번만 복원된다.
- wake restore의 temperature preflight/postflight 실패는 charging을 재개하지 않는다.
- Discharge에서 전환 시 검증 성공 전 sleep assertion이 해제되지 않는다.
- shutdown과 sleep/wake가 겹쳐도 최신 generation 하나만 hardware를 소유한다.
- acknowledgement timeout 또는 shutdown 취소 후 late backend completion이 mode나 hardware를 변경하지 않는다.
- monitoring-only/system ownership에서는 모든 sleep/wake 경로가 mutation-free다.
- 명시적 Maintain 복구는 모든 precondition과 complete postcondition을 검증한다.

### 6.4 UI tests

- AC 연결 + CLI disabled/drift가 `전원 연결됨 · 충전 제어 복구 필요`로 표시된다.
- unavailable 값이 0mA, 0%, 100% 같은 정상 측정값으로 표시되지 않는다.
- read-only 버튼과 mutation 복구 버튼의 label, help text, disabled reason이 구분된다.
- 복구 진행 중 중복 클릭과 상충 control이 차단된다.

## 7. PR 분리와 실행 순서

### PR 1 — `fix/sleep-status-settlement`

범위:

- `SMCKit.prepareForSystemSleep`에 bounded read-only settlement 추가
- 이미 보호된 상태가 사용하는 mutation 없는 bounded verifier 추가
- typed settlement result/error 및 operation-correlated diagnostics 추가
- deterministic clock/status-sequence tests 추가

이 PR만 병합해도 이번 장애의 직접 원인인 one-shot verification 오판을 막아야 한다. Controller 변경은 이미 보호된 상태에서 같은 backend verifier를 호출하는 한 줄짜리 경계 변경으로 제한하며, UI와 ownership 정책은 바꾸지 않는다.

PR 1은 각 status command와 terminal settlement event가 동일 operation ID로 연결되게 한다. Sleep request kind와 generation을 포함하는 optional persisted DTO는 그 값이 실제로 도입되는 PR 2에서 추가해 중복 migration을 피한다.

병합 거부 조건:

- mutation을 재시도함
- 전체 deadline을 매 attempt마다 연장함
- partial tuple 또는 ambiguous worker를 성공으로 처리함
- cancellation 이후 command/read가 실행됨
- 실제 시간에 의존하는 flaky test만 존재함

### PR 2 — `fix/typed-system-sleep-lifecycle`

범위:

- typed sleep request/completion event 도입
- vetoable/forced acknowledgement 및 controller 전이 분리
- timeout/invalidation/stop 시 owning preparation Task 취소
- `sleepChargingOffWasRequested` 독립 상태 제거
- failure origin, recovery target, latest observed state를 가진 typed manual recovery context 추가
- wake/cancel/forced-failure generation tests 추가

병합 거부 조건:

- forced sleep 실패를 reject 가능하다고 가정함
- 불확실한 실패 뒤 자동 Maintain을 실행함
- timeout/invalidation 뒤 preparation Task가 계속 실행됨
- shutdown policy가 다시 Boolean과 mode 두 source에 의존함
- 같은 sleep sequence에서 mutation이 중복 실행됨

### PR 3 — `fix/explicit-charge-recovery-ui`

범위:

- read-only 재확인과 explicit Maintain 복구 분리
- physical power, current flow, control state를 분리 표시
- 복구 precondition, complete tuple 검증, Heat safety gate 및 UI tests 추가

병합 거부 조건:

- 버튼이 fresh status/temperature 확인 전에 mutation함
- 실패를 성공 또는 단순 “일시정지”로 표시함
- periodic/app-activation reconciliation이 mutation을 시작함

### PR 4 — controlled hardware validation and plan closure

코드 변경 없이 실제 Mac에서 opt-in 검증 결과만 기록한다. 사용자의 명시적 승인 후 수행하며 시작/종료 상태를 Maintain 80, non-discharge, exact worker 하나로 복원한다.

PR은 순서대로 병합한다. 각 PR은 직전 PR이 병합된 최신 `main`에서 분기하고, refactor나 unrelated cleanup을 섞지 않는다.

## 8. 자동 검증 게이트

각 코드 PR에서 우선 변경 경로의 targeted tests를 실행한 뒤 다음 safe gates를 실행한다.

```sh
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug test
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug build-for-testing SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Release build
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug analyze
```

- test host는 fake backend, isolated defaults, in-memory history, disabled diagnostics만 사용한다.
- 자동 테스트는 실제 battery CLI, login item, production store를 건드리지 않는다.
- 테스트 수보다 safety branch의 success/failure/timeout/cancellation/stale-generation 완결성을 우선한다.

## 9. 실제 하드웨어 검증

사용자가 승인한 통제된 세션에서만 다음을 실행한다.

각 trial 전후에 아래 원자료를 별도 파일로 보존한다.

- local wall-clock 및 monotonic 기준 시각
- `pmset -g batt`
- `pmset -g log`의 해당 sleep/wake 구간
- IOKit의 external connected/capable, charging, current 값
- `AppleRawCurrentCapacity`와 `AppleRawMaxCapacity`
- `battery status_csv`
- exact Maintain worker argv, PID file, PID start identity
- 관련 operation ID의 diagnostics
- UI screenshot

검증 matrix:

1. AC 연결, 배터리 80% 미만, Maintain 80 정상 상태에서 idle sleep 허용 후 wake
2. 같은 조건에서 idle sleep 취소
3. 뚜껑 닫기 forced sleep 후 짧은 wake
4. 뚜껑 닫기 forced sleep 후 10분 이상 wake
5. 빠른 sleep/wake 반복
6. sleep 중 AC 분리 후 wake
7. sleep 중 AC 연결 후 wake
8. forced sleep/wake를 연속 3회 수행해 operation generation과 worker가 누적되지 않는지 확인

Idle sleep을 재현하기 위해 `pmset` 값을 임시 변경해야 한다면 먼저 `pmset -g custom`을 보존하고, 승인된 trial 뒤 정확히 원복한 다음 원복 결과를 기록한다.

각 trial의 통과 조건:

- sleep acknowledgement deadline 초과 없음
- 동일 transition에서 mutation command 1회 이하
- 잠들기 직전 verified charging disabled, non-discharge, Maintain worker stopped
- 10분 이상 forced-sleep trial에서 raw capacity가 측정 오차를 넘게 증가하지 않고 `pmset` log에 예기치 않은 wake가 없음
- 정상 wake 후 10초 이내 exact Maintain 80 worker 1개와 non-discharge 확인
- 실패 trial은 자동 충전 재개 없이 명시적 복구 UI를 제공
- UI의 AC 연결 표시는 IOKit 사실과 일치
- trial 종료 시 Maintain 80, non-discharge, exact worker 1개로 복원

평균값만 남기지 않고 모든 trial 원자료를 보존한다. 준비 실패나 hardware 초기 상태 mismatch가 있는 trial은 성능 또는 안정성 결과에 포함하지 않는다.

## 10. 성능 및 복잡도 점검

- settlement는 잠자기 전 mutation 직후에만 실행하며 background polling이 아니다.
- 정상 경로는 status read 1회로 끝난다.
- 비정상 경로도 최대 attempt와 absolute deadline으로 제한한다.
- backoff 동안 MainActor를 막지 않고 async sleep을 사용한다.
- UI 갱신 빈도와 BatteryMonitor watchdog 주기를 늘리지 않는다.
- 추가 diagnostic은 lifecycle transaction 하나에 묶고 routine event처럼 매 polling마다 전체 파일을 flush하지 않는다. 실패/최종 결과만 즉시 flush한다.
- 상태 모델 외부에 recovery Boolean이나 별도 source of truth를 만들지 않는다.

예상 영향:

- 정상 sleep: 기존과 거의 동일한 command 수와 latency
- transient mismatch: 최대 4회의 추가 read-only status 확인과 약 1.85초의 backoff
- idle CPU/wakeup: 변화 없음
- 실패 분석: 단일 최종 오류 대신 전체 상태 안정화 sequence 확인 가능

## 11. Rollback 전략

- PR 1은 backend 내부 변경이므로 독립 revert 가능하다.
- PR 2는 typed observer/controller contract만 포함하고 UI와 분리해 독립 revert 가능하게 한다.
- PR 3은 UI와 explicit recovery entry point를 포함하되 기존 read-only reconciliation을 삭제하지 않는다.
- rollback 중에도 실패 상태를 성공으로 완화하거나 periodic mutation을 허용하지 않는다.
- hardware trial에서 regression이 나오면 마지막 검증된 Maintain 80 상태를 수동으로 복원한 뒤 해당 PR을 병합하지 않는다.

## 12. 완료 기준

다음을 모두 만족해야 이 문제를 해결 완료로 표시한다.

- transient tuple fixture가 기존 one-shot failure를 재현하고 새 settlement로 통과한다.
- persistent/unknown/cancelled/deadline failure는 모두 fail-closed 한다.
- vetoable idle sleep과 forced sleep이 controller와 diagnostics에서 구분된다.
- 불확실한 실패는 자동 mutation 없이 명시적인 복구가 가능하다.
- AC 연결과 CLI drift가 UI에서 동시에 사실대로 보인다.
- 모든 automated gate가 통과한다.
- 승인된 hardware matrix가 원자료와 함께 통과한다.
- 최종 설치 앱과 build artifact가 일치하고, 실제 상태가 Maintain 80, non-discharge, exact worker 1개다.

“다시는 발생하지 않음”은 일시적인 CLI/SMC 값이 절대 나타나지 않는다는 뜻이 아니다. 그런 값이 다시 나타나더라도 bounded settlement로 정상 안정화를 흡수하고, 안정화되지 않는 경우에는 안전하게 중단하며, 사용자가 원인을 정확히 보고 검증된 복구를 수행할 수 있음을 뜻한다.

## 13. 계획 자체 재검토 결과

- 부족했던 부분: 기존 backend test는 준비 성공/실패만 주입하고 실제 status 안정화 sequence를 재현하지 못한다. PR 1에서 이 seam을 우선 보강한다.
- 구조적 결함: observer가 두 sleep 종류와 두 completion event를 각각 Boolean/단일 callback으로 잃어버린다. PR 2의 typed contract는 선택적 정리가 아니라 올바른 lifecycle 정책에 필요하다.
- 복구 결함: 현재 버튼은 read-only 확인만 하므로 이미 종료된 Maintain worker를 복원할 수 없다. PR 3의 explicit mutation은 필요하지만 typed target과 fresh safety precondition으로 제한한다.
- 과한 설계 제외: daemon, 새 ownership journal, 상시 polling, BatteryMonitor 재작성, 범용 state-machine framework는 문제 해결에 필요하지 않아 제외했다.
- 성능 위험 통제: 정상 경로 command 수는 그대로이고, 추가 status read는 sleep mutation 직후 mismatch가 있을 때만 최대 4회 수행한다.
- 남는 위험: 실제 battery CLI 내부의 transient bit 원인은 외부 구현이므로 완전히 제거할 수 없다. 대신 애플리케이션이 이를 영구 drift로 확대하지 않고, 미안정 상태는 fail-closed와 명시적 복구로 containment한다.
