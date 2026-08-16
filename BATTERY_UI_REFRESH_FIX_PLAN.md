# Battery UI Refresh Fix Plan

## 1. 목적

충전기 연결·분리 직후 macOS의 실제 전원 및 충전 상태가 바뀌었는데도 BatteryGuard UI가 이전 `BatteryInfo`를 수십 초에서 1분 이상 표시하는 회귀를 해결한다.

상시 고빈도 polling으로 되돌리지 않고 다음 계약을 지킨다.

- 실제 AC↔Battery 전환 뒤 UI를 3초 안에 최신 IOKit 상태로 수렴시킨다.
- 전원 전환이 없는 평상시 read/wakeup 빈도는 늘리지 않는다.
- IOKit 측정값과 verified CLI charge-control 상태의 역할을 섞지 않는다.
- Heat Protection, Top Up, Discharge, external drift 및 shutdown 안전 계약을 유지한다.
- installer 작업과 섞지 않고 `origin/main` 기반의 독립 PR로 전달한다.

## 2. 확인된 현상과 원인

2026-08-16 실기 로그에서 macOS는 충전기 연결 후 1초 안에 상태를 확정했다.

- `19:47:17.965`: 전원 공급원이 AC로 변경됨
- `19:47:17.983`: `State:Charging`, `UISOC:68`

그러나 `19:48:01` 스크린샷의 BatteryGuard는 여전히 `충전 일시정지`와 `-1539 mA (방전)`을 표시했다. 앱 UI는 응답 중이었으므로 렌더링 정지가 아니라 측정 갱신 계약의 문제다.

현재 `BatteryMonitor`는 다음 방식으로 동작한다.

1. 넓은 범위의 IOPowerSource 알림 뒤 100ms에 AppleSmartBattery를 한 번 읽는다.
2. 연결 직후의 `plugged=true, charging=false, negative amperage` 과도기 값도 정상 snapshot으로 게시한다.
3. 그 값이 곧 바뀌는지 확인하는 전환 전용 bounded settlement가 없다.
4. 알림을 놓치면 다음 보정은 30초 watchdog까지 기다린다.
5. IOPowerSource source와 watchdog이 default run-loop mode에 묶여 event tracking 중 전달이 늦어질 수 있다.
6. 메뉴바·Dashboard 표시와 앱 활성화가 최신 배터리 측정을 요청하지 않는다.

이 문제는 2초 polling을 notification-driven monitoring과 30초 watchdog으로 바꾼 뒤 생긴 회귀다. 60초 CLI reconciliation은 `BatteryInfo`를 직접 갱신하지 않으므로 원인이 아니다.

## 3. 확정 데이터 흐름

```text
routine IOPS notification -> coalesced single read
explicit AC/Battery edge  -> anchored settlement [100ms, 500ms, 1s, 2s]
30s common-mode watchdog  -> single read
UI visibility/activation  -> coalesced single read
                           -> changed snapshot only
                           -> UI + existing controller policy
```

`BatteryMonitor`의 각 read는 하드웨어를 변경하지 않는다. 다만 새 snapshot을 받은 `ChargeController`는 기존 Heat Protection 및 Top Up/Discharge 정책에 따라 안전 명령을 실행할 수 있다. 따라서 controller integration test로 이 간접 반응도 검증한다.

## 4. 변경 범위

### 포함

- 실제 AC↔Battery 전환만 구분하는 signal과 전환 전용 settlement
- routine notification, watchdog, UI refresh의 단일-read coalescing
- notification/watchdog의 common run-loop 전달 보장
- start/stop, 동일 방향 burst, 반대 방향 전환의 task ownership
- UI 표시와 기존 activation observer의 측정 refresh 연결
- monitor 및 controller regression test
- 자동 검증, 통제된 실기 검증, 원본 timing 증거 보존
- 완료 후 이 문서와 `REFACTOR_PLAN.md` 체크포인트 갱신

### 제외

- battery CLI 명령·worker·status verification 계약 변경
- `ChargeMode`, charge ownership 또는 Heat Protection SMC cadence 변경
- 상시 2초 polling 복원
- UI 디자인·이력 저장 형식·installer 작업 변경
- 실제 하드웨어를 건드리는 기본 XCTest

## 5. 상세 설계

### 5.1 일반 알림과 실제 전원 전환 분리

- 기존 broad IOPowerSource 알림은 percent/time/state 변화용으로 유지하되 callback burst를 합쳐 한 번만 읽는다.
- AC/Battery source 변화는 `kIOPSNotifyPowerSource`의 dispatch notification으로 별도 관찰한다.
- source 등록 실패는 one-shot `Logger` warning으로 남기고 30초 watchdog 및 broad notification 경로는 계속 동작시킨다.
- 전환 callback마다 현재 source kind를 읽고 마지막 관찰값과 비교한다.
- 같은 source kind의 중복 callback은 기존 settlement를 취소하거나 마감 시각을 연장하지 않는다.
- 실제 반대 방향 edge만 이전 generation을 취소하고 새 generation을 시작한다.
- 최초 monitoring 시작의 `nil -> current source`는 baseline 설정이며 물리 전환으로 취급하지 않는다.
- baseline read와 observer 등록 사이의 edge를 놓치지 않도록 등록 직후 source kind를 한 번 재확인하고, 달라졌으면 동일한 settlement를 시작한다.

이 분리가 없으면 잦은 percent/time 알림마다 여러 번 읽어 평상시 비용이 기존보다 커진다.

### 5.2 anchored bounded settlement

실제 전원 edge의 최초 monotonic timestamp를 deadline anchor로 사용한다.

```text
100ms -> 500ms -> 1s -> 2s
```

- 지연은 이전 read 완료 시점이 아니라 최초 edge의 절대 offset이다.
- 같은 방향 callback은 schedule을 재시작하지 않는다.
- 반대 방향 edge, `stopMonitoring()`, teardown 또는 새 monitoring generation만 기존 task를 취소한다.
- 각 await와 read 뒤 monitoring generation, transition generation 및 expected source kind를 재검증한다.
- stale task는 read 결과를 게시하지 않는다.
- 각 단계에서 registry를 새로 읽으며 기존 snapshot과 같으면 `@Published` 이벤트를 만들지 않는다.
- `isCharging` 또는 amperage를 합성하지 않는다. native Charge Limit, Maintain, Heat Protection 때문에 plugged-but-not-charging이 정상일 수 있다.
- 실제 전환당 최대 네 번만 추가로 읽는다. 마지막 read를 2초에 두어 UI render까지 포함한 3초 acceptance에 여유를 둔다.

### 5.3 routine refresh coalescing

routine IOPS 알림, watchdog, UI 표시 요청은 평상시 각각 독립적인 single-read trigger다. 다만 active settlement가 있으면 추가 read를 만들지 않고 가장 가까운 scheduled settlement read가 그 요청을 충족한다.

- routine IOPS burst: 100ms coalescing 뒤 한 번 읽기
- watchdog: 30초마다 한 번 읽기
- UI visibility/activation: 같은 run-loop turn의 요청을 한 번으로 합치고, active settlement 중이면 별도 read 없이 settlement에 합류
- power transition/active settlement 중에는 snapshot age를 이유로 refresh를 생략하지 않는다.
- 별도 freshness-age gate를 두지 않는다. 방금 읽은 과도기 snapshot이 있다는 이유로 필요한 전환 read가 막혀서는 안 된다.

### 5.4 run-loop mode

- IOPowerSource run-loop source는 `.commonModes`에 등록하고 같은 mode에서 제거한다.
- watchdog은 `Timer(timeInterval:repeats:block:)`로 한 번 생성한 뒤 `RunLoop.main.add(timer, forMode: .common)`로 등록한다.
- `scheduledTimer`와 common-mode 재등록을 혼용하지 않는다.
- 별도 dispatch watchdog은 추가하지 않는다.
- watchdog 30초와 tolerance는 유지한다.

### 5.5 UI와 activation 연결

- `BatteryMonitor`에 표시용 explicit refresh API를 둔다.
- `MenuBarView`와 `DashboardView`의 실제 표시 시점에 이 API를 호출한다.
- 앱 활성화는 새 observer를 만들지 않고 기존 `ChargeController` activation observer에서 measurement refresh를 먼저 요청하고 기존 read-only reconciliation을 이어서 수행한다.
- SwiftUI 재구성만으로 반복 read가 발생하지 않도록 동시 표시 요청을 coalesce한다.

### 5.6 기존 안전 계약

- IOKit은 measurement source of truth, verified CLI status는 charge-control source of truth로 유지한다.
- 측정 read 자체는 mutation을 수행하지 않는다.
- 새 snapshot에 따른 Heat/long-running 반응은 기존 operation generation, ownership, readiness 및 failure disposition을 반드시 통과한다.
- 빠른 snapshot이 external drift를 지우거나 stale Top Up/Discharge intent를 되살려서는 안 된다.
- stop/shutdown 뒤 monitor task는 controller state를 변경할 수 없다.

## 6. 구현 순서

### 1단계: 브랜치와 계획 격리

1. `origin/main`을 fetch한다.
2. installer commit이 있는 `feat/friend-installer`에서 작업하지 않는다.
3. `origin/main`에서 `fix/battery-ui-refresh-settlement`를 만든다.
4. branch 고유 diff가 이 계획서와 UI refresh 수정만 포함하는지 확인한다.

### 2단계: deterministic regression test

실제 IOKit/CLI/Core Data/login item을 사용하지 않는 fixture seam을 최소 범위로 둔다. production schedule과 monotonic timing contract는 유지한다.

다음 테스트를 먼저 추가한다.

1. routine percent/time notification은 coalesced single read만 하고 settlement를 시작하지 않는다.
2. 실제 source edge에서 `plugged=true, charging=false, amperage<0` 뒤 충전 snapshot으로 수렴한다.
3. 같은 source 방향의 callback burst는 anchored deadline을 연장하지 않는다.
4. 반대 방향 edge는 이전 generation을 취소하고 새 schedule을 시작한다.
5. `nil -> valid source` baseline은 settlement가 아니며 persistent `nil`도 안전하게 single-read/watchdog에 남는다.
6. `stopMonitoring()`과 stop/start generation은 이전 task의 read/post를 무효화한다.
7. 동일 snapshot은 `@Published` 이벤트를 중복 생성하지 않는다.
8. 정상 charge pause를 `charging=true`로 합성하지 않는다.
9. 전환 한 번의 최대 settlement read 수는 4회다.
10. 전환이 없으면 settlement read 수는 0회다.
11. MenuBar/Dashboard/activation의 동시 visibility refresh는 한 번으로 합쳐진다.
12. source registration failure는 fallback monitoring을 막지 않는다.
13. baseline read와 observer 등록 사이에 발생한 edge도 post-registration 재확인으로 settlement를 시작한다.

### 3단계: monitor 구현

1. broad routine callback의 기존 one-read coalescing을 유지한다.
2. explicit power-source signal과 cached source kind를 추가한다.
3. transition generation, monitoring generation, owning `Task`를 구현한다.
4. 최초 edge에 anchor된 100/500/1000/2000ms 절대 schedule을 구현한다.
5. 모든 suspension 뒤 generation/source를 검증한다.
6. stop/deinit에서 work item, transition task, notification token, timer, run-loop source를 대칭 정리한다.
7. `BatteryMonitor`가 `@MainActor`이므로 새 actor 계층은 추가하지 않는다.

### 4단계: common-mode 및 표시 refresh 연결

1. broad IOPS source를 common modes에 등록한다.
2. unscheduled watchdog Timer를 common mode에 한 번 등록한다.
3. MenuBar와 Dashboard 표시에서 explicit refresh를 요청한다.
4. 기존 app activation observer에서 refresh 후 reconciliation을 수행한다.
5. 60초 external reconciliation cadence는 변경하지 않는다.

### 5단계: controller integration test

빠른 snapshot 게시의 간접 정책 반응을 검증한다.

- Maintain 중 charging 표시 갱신
- high-temperature snapshot이 기존 Heat Protection 안전 경로를 그대로 실행
- Heat Protection이 소유한 charging-off 상태 유지
- Top Up/Discharge generation과 process ownership 유지
- long-running completion/failure 판단이 stale monitor generation에 의해 바뀌지 않음
- external drift 보존
- shutdown 뒤 stale settlement 무효화
- monitoring-only/native Charge Limit 상태의 정당한 charge pause 표시

### 6단계: 성능 계측과 자동 검증

테스트 seam에서 다음 budget을 검증한다.

- steady state transition settlement read: `0`
- routine notification burst: coalesced `1`
- visibility burst: coalesced `1`
- physical edge: 최대 `4`
- same-direction burst: deadline/총 read 수 불변

이후 다음을 모두 실행한다.

```sh
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug build-for-testing
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Release build
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug analyze
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug build-for-testing SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

관련 테스트를 먼저 실행하고 기본 테스트가 hardware/system state에서 격리된 것을 확인한 뒤 안전한 전체 XCTest를 실행한다.

### 7단계: 계획 감사와 hostile review

- 실제 diff를 이 문서의 각 항목과 대조한다.
- correctness, cancellation, stale completion, safety side effect, main-thread wakeup, read count를 hostile senior 기준으로 검토한다.
- P1/P2 및 재현 가능한 성능 문제를 수정하고 code 변경 뒤 검증을 다시 실행한다.
- 완료 증거를 이 문서와 `REFACTOR_PLAN.md`에 기록한다.

### 8단계: 통제된 실기 검증

자동 검증을 모두 통과한 Release 앱만 `/Applications/BatteryGuard.app`에 설치한다. 사용자가 충전기를 직접 연결·분리하고, 도구는 read-only 관찰만 수행한다.

각 trial의 원본 timestamp를 보존한다.

1. 앱 readiness와 초기 snapshot을 기록한다.
2. 실제 CLI가 Maintain 80%, exact worker 1개, non-discharge인지 기록한다.
3. sampler 시작 시각을 기록한 뒤 사용자가 충전기를 연결 또는 분리한다.
4. `powerd`/IOKit source edge timestamp를 기록한다.
5. monitor publish 및 UI 표시 변화 timestamp를 코드 signpost/진단 timestamp로 기록한다. 육안 추정만 사용하지 않는다.
6. 연결·분리를 각각 최소 5회 반복한다.
7. 메뉴바가 열린 상태, 닫힌 상태, UI tracking 중을 포함한다.
8. raw trial별 latency와 성공/실패를 보존한다. 실패 launch를 평균에 섞지 않는다.
9. 마지막에 Maintain 80%, exact worker 1개, non-discharge로 복원·검증한다.

#### 완료 결과 (2026-08-16)

자동 gate를 통과한 Release 앱을 `/Applications/BatteryGuard.app`에 설치한 뒤, 동일한 `kIOPSNotifyPowerSource` edge를 관찰하는 read-only recorder와 앱의 `BatteryMonitor` unified log를 함께 기록했다. 시작과 종료 상태는 모두 80%, AC attached, charging disabled, not discharging, exact `maintain_synchronous 80` worker 1개였고 PID 파일은 PID 3395를 가리켰다.

| UI 상태 | 방향 | IOKit edge (UTC) | 최초 material publish (UTC) | 지연 |
|---|---|---:|---:|---:|
| 닫힘 | 분리 | 11:44:41.528 | 11:44:41.632 | 104ms |
| 닫힘 | 연결 | 11:44:49.483 | 11:44:49.590 | 107ms |
| 닫힘 | 분리 | 11:44:56.548 | 11:44:56.658 | 110ms |
| 닫힘 | 연결 | 11:45:04.482 | 11:45:04.597 | 115ms |
| 메뉴 열림 | 분리 | 11:45:47.627 | 11:45:47.739 | 112ms |
| 메뉴 열림 | 연결 | 11:45:54.294 | 11:45:54.405 | 111ms |
| 메뉴 열림 | 분리 | 11:46:01.165 | 11:46:01.275 | 110ms |
| 메뉴 열림 | 연결 | 11:46:08.578 | 11:46:08.687 | 109ms |
| Dashboard chart tracking | 분리 | 11:48:41.330 | 11:48:41.442 | 112ms |
| Dashboard chart tracking | 연결 | 11:48:50.049 | 11:48:50.158 | 109ms |

- 10/10 trial이 3초 상한을 통과했다. 최소 104ms, 최대 115ms, 평균 109.9ms다.
- 모든 최초 publish는 100ms settlement offset에서 발생했다. 연결 trial 일부는 IOKit 값이 더 안정화되면서 500ms offset에서 두 번째 material publish가 있었지만 deadline 재시작이나 read 폭주는 없었다.
- 배터리가 이미 Maintain 80%였으므로 연결 뒤 `charging=false`는 정상이다. 실제 양의 충전 전류 전환을 만들기 위해 limit을 변경하거나 Top Up을 실행하지 않았으며, transitional negative-amperage snapshot에서 charging snapshot으로 수렴하는 경로는 deterministic monitor test로 검증했다.
- 전체 311개 XCTest, Debug build-for-testing, strict concurrency와 warnings-as-errors, Release build, Analyze가 통과했다.
- 실기 검증 뒤에도 PID 파일과 exact worker가 일치하는 Maintain 80%, charging disabled, not discharging 상태를 유지했다.

### 9단계: 전달

- logical code+test commit과 verification docs commit을 만든다.
- 일반 push만 사용하고 force push하지 않는다.
- base가 `main`이고 installer diff가 없는 PR을 생성한다.
- PR 본문에 자동 검증, read-count budget, raw hardware trial 결과, 최종 battery-control 상태를 기록한다.
- 실기 검증이 실패하면 PR은 열 수 있어도 병합하지 않는다.

PR #23은 installer 작업과 분리된 단일 원자적 UI refresh PR로 열었다. monitor settlement, UI trigger와 controller safety test는 하나만 먼저 병합하면 불완전한 동작 계약이 되므로 별도 stacked PR로 나누지 않았다. 코드·테스트와 계획은 논리적 커밋으로 분리하고, 이 실기 결과는 verification docs 커밋으로 같은 PR에 추가한다.

## 7. 승인 기준

다음을 모두 만족해야 완료다.

- 연결·분리 trial 모두에서 IOKit source edge부터 UI publish까지 3초 이내다.
- 마지막 scheduled read는 2초 이내이며 렌더링 여유를 포함해 3초 상한을 지킨다.
- 메뉴바 tracking 중에도 상한을 넘지 않는다.
- 전류는 최신 registry 값을 그대로 표시하며 앱이 값을 합성하지 않는다.
- steady-state watchdog은 30초이고 전환 없는 settlement read는 0이다.
- ordinary notification/visibility burst는 각각 한 번으로 coalesce된다.
- 전환당 settlement read는 최대 4회다.
- 같은 방향 callback이 deadline을 연장하지 않는다.
- stale task가 stop/start/shutdown/reverse edge 뒤 state를 변경하지 않는다.
- high-temperature 및 long-running downstream safety behavior가 기존 계약을 지킨다.
- 자동 테스트가 실제 CLI, login item, production store 또는 hardware를 건드리지 않는다.
- strict concurrency, warnings-as-errors, Release build, Analyze와 안전한 전체 테스트가 통과한다.
- 검증 전후 실제 제어 상태가 Maintain 80%, exact worker 1개, non-discharge다.
- PR 고유 diff에 installer 변경이 없다.

## 8. 성능·위험 평가

### 예상 비용

- steady state: 기존과 동일한 notification-driven single read + 30초 watchdog
- routine callback burst: coalesced 1 read
- UI visibility burst: coalesced 1 read
- 물리 전원 전환: 최대 4개의 추가 IOKit read

4회 read는 드문 물리 전환에만 발생하므로 상시 polling보다 훨씬 싸며 병목으로 보지 않는다.

### 위험과 대응

- **routine notification이 settlement를 시작함:** source kind edge 비교와 read-count test로 차단한다.
- **callback 폭주가 마감을 무한 연장함:** 최초 edge anchor를 유지하고 same-direction callback을 무시한다.
- **reverse edge에서 stale 게시:** task cancellation + generation/source 재검증을 함께 사용한다.
- **freshness gate가 과도기 값을 고정함:** transition과 visibility에 age gate를 두지 않는다.
- **charge start를 추정함:** registry 값을 그대로 게시하고 `isCharging`을 합성하지 않는다.
- **main run-loop starvation:** source와 unscheduled Timer를 common mode에 등록한다.
- **새 measurement가 안전 명령을 촉발함:** 기존 controller policy를 통과시키고 high-temp/long-running integration test를 둔다.
- **source observer 등록 실패:** Logger 경고 후 broad notification/watchdog fallback을 유지한다.
- **PR scope 오염:** branch를 `origin/main`에서 생성하고 base diff를 검사한다.

## 9. 커밋 및 PR 계획

Branch:

```text
fix/battery-ui-refresh-settlement
```

Base:

```text
origin/main
```

권장 logical commits:

1. `fix: settle battery UI after power-source transitions` (implementation + regression tests)
2. `docs: record battery UI refresh verification` (계획 완료 및 raw verification references)

하드웨어 검증 전에도 자동 검증이 끝난 상태로 PR을 열 수 있지만, 실기 acceptance와 최종 Maintain 복원이 확인되기 전에는 병합하지 않는다.

## 10. 롤백 기준

다음 중 하나라도 발생하면 병합하지 않는다.

- 전원 전환 없이 background read/wakeup이 증가한다.
- 같은 방향 callback이 settlement deadline을 계속 연장한다.
- stale task가 shutdown, stop/start, reverse edge 또는 새 control intent 뒤 state를 바꾼다.
- Heat Protection, Top Up/Discharge ownership 또는 Discharge assertion 계약이 약해진다.
- 정상 Maintain/native Charge Limit pause를 charging으로 잘못 표시한다.
- 실기 trial에서 3초 상한을 반복해서 충족하지 못한다.

3초 안에 IOKit registry 자체가 최신 값을 주지 않는다면 추정값을 표시하지 않는다. raw transition timing을 다시 측정하고 근거가 있을 때만 cadence/상한을 조정한다.
