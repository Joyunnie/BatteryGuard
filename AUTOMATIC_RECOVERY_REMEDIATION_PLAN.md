# BatteryGuard 장기 복구성 개선 계획

작성: 2026-10-02 · 상태: 코드 구현 및 자동 검증 완료, 실제 하드웨어 검증 대기

## 1. 목적과 확인된 사실

목표는 일시적인 CLI 지연이나 관측 실패가 안전한 하드웨어 상태를 영구적인 앱 오류와 사용자 수동 작업으로 확대하지 않게 하는 것이다. 모든 실패에서 무조건 자동으로 충전을 재개한다는 뜻은 아니다. 제어 상태가 불확실하거나 외부에서 변경되었으면 자동 **하드웨어 명령**은 멈추되, 앱이 가능한 **읽기 전용 검증**과 자기 복구는 끝까지 수행해야 한다.

2026-10-02 장애에서 확인된 순서는 다음과 같다.

1. 잠자기에서 깬 뒤 Maintain 80 worker가 생성됐다.
2. 뒤따른 `battery status_csv`가 2초 제한에 걸려 검증에 실패했다. 지연의 하위 원인은 아직 확인되지 않았다.
3. 앱은 `mode.failed(manualIntervention)`과 `readiness.failed`를 기록했다. 초기화 실패 정리 과정에서 monitoring/observer도 중단됐다.
4. 이후 실제 하드웨어는 AC 연결, 80%, 충전 비활성, 비방전, PID 파일과 일치하는 정확한 Maintain 80 worker 하나로 안전했다.
5. 초기화는 먼저 mode를 `.idle`로 바꾸므로 이 실패는 `previous == nil`일 수 있다. 그 경우 복구 안내와 버튼 자체가 나타나지 않고, `previous`가 남아도 UI의 재확인은 `readiness == ready`를 요구한다. 앱 재시작 또는 외부 조작 없이는 정상 상태를 재검증하고 초기화를 마칠 경로가 없다.

`status_csv` 내부가 SMC와 `pmset`을 여러 번 읽는 것은 확인됐지만, 이번 2초 초과가 어느 호출 때문인지는 입증되지 않았다. 단순히 제한 시간을 크게 늘리거나 timeout을 성공으로 간주하는 것은 해결책이 아니다.

코드에서 확인된 다른 유사 경계도 범위에 넣는다.

- CLI preflight, Maintain, 충전 차단, 제어 해제는 단일 상태 읽기의 일시적 실패에 취약하다. 잠자기 보호는 tuple mismatch만, Top Up/Discharge 시작은 제한된 재확인이 있으므로 각각의 기존 안전 계약을 보존하며 검토한다.
- 수동 복구가 상태를 읽은 뒤 온도를 `await`하는 사이 실제 tuple이 바뀔 수 있다. 일부 경로는 마지막 제어 tuple을 다시 확인하지 않고 성공을 표시한다.
- 복구 중 stale completion 또는 shutdown과 겹치면 `readiness.reconciling`이 남을 수 있는 경로가 있다.
- Heat Protection의 restore 실패가 검증된 차단 상태로 돌아가면 retry backoff가 설정되지 않아 다음 센서 평가마다 반복 시도할 수 있다.
- 이력 저장소 load 실패는 앱 재시작 전까지 재시도 경로가 없다. 충전 안전과는 분리된 낮은 우선순위다.

## 2. 안전 경계와 비목표

- IOKit 측정과 CLI의 검증된 제어 tuple을 혼동하지 않는다. 성공은 charging, discharging, maintain level, 정확한 worker/PID identity 전체의 최신 일치를 뜻한다.
- 명령 종료, timeout, 불완전 출력, 이전 성공 snapshot, 일부 일치, 센서 하나의 정상값은 성공 증거가 아니다.
- mutation이 시작된 뒤 검증만 실패했다면 같은 mutation을 무작정 재실행하지 않는다. 먼저 읽기 전용 재확인으로 결과를 판별한다.
- 주기적·앱 활성화 reconciliation은 계속 read-only다. Terminal 또는 다른 소유자의 변경을 자동으로 덮어쓰지 않는다.
- Heat Protection 이외의 불확실한 제어 실패는 자동 *충전 재개 명령*을 허용하지 않는다. 다만 완전하고 최신인 안전 tuple이 확인되면 자동으로 **표시/초기화 상태만** 회복할 수 있다. mismatch나 외부 drift는 잠금과 명시적 조치를 유지한다. 이 규칙은 앱 시작 때 저장된 소유권과 충전 목표도 다시 확인해야 한다.
- 확인 불가능한 상태에서 앱을 정상 종료시키거나 Discharge sleep assertion을 해제하지 않는다. runner의 terminal cleanup failure도 재시도 가능한 상태로 둔갑시키지 않는다.
- ownership journal의 `batteryGuard`/`releasing`/`system` 경계를 유지한다. `releasing` 재개는 기존의 durable intent에 한해서만 실행한다.
- 실패를 감추기 위한 상시 빠른 polling, 별도 daemon, 새 ownership journal, 범용 retry framework, 앱 전체 재작성은 하지 않는다.
- 실제 배터리 CLI 조작과 잠자기 하드웨어 시험은 별도 사용자 승인 없이는 실행하지 않는다.

## 3. 목표 상태 모델과 복구 규칙

하나의 semantic operation ID와 generation 아래에서 변경, 관측, 최종 판정을 연결한다. 기존 `ChargeMode`와 readiness를 유지하되, 오류 문자열에 의존하지 않는 작은 typed 실패 분류를 둔다.

| 분류 | 예 | 자동 행동 | 종료 상태 |
|---|---|---|---|
| 검증 대기 | 변경 명령 종료 후 status timeout/일시 mismatch | 같은 작업의 제한된 read-only 재확인 | 완전 일치 시 verified success; 기한 초과 시 unknown |
| 읽기 일시 실패 | 초기화·wake의 status timeout, runner는 정상 | 제한된 read-only 재시도; 필요하면 사용자에게 비차단 재시도 제공 | 최신 완전 tuple로 판정 |
| 확인된 외부 drift | target/worker/charging tuple 불일치 | 관측만 갱신, 충돌 제어 잠금 | expected vs observed 표시 |
| 확인된 안전 상태 | 의도한 tuple과 owner가 일치 | 초기화/monitoring 재개, 오류 해소 | ready |
| 불확실·위험 상태 | ambiguous worker, PID 재사용, cleanup 실패, 센서 불가 등 | 기존 fail-closed 동작 유지; 자동 충전 재개 금지 | 원인과 다음 행동 표시 |

`unknown`과 `drift`는 별개다. status를 읽지 못한 것만으로 외부 변경을 확정하지 않고, 과거 정상 status만으로 현재 안전을 확정하지 않는다. 초기화 실패 후 verified success에 도달해도 관측자·monitoring·히스토리 heartbeat·sleep observer 등록 또는 기존 degraded fallback 설정이 다시 완료되기 전에는 `ready`라고 표시하지 않는다. observer 등록 실패 자체는 기존의 명시적 degraded 상태로 남길 수 있으며, `ready`를 영구 차단하지 않는다.

## 4. 구현 순서와 독립 PR

### PR 1 — 실패 초기화에서 빠져나오는 읽기 전용 복구

**수정:** `ChargeController.initialize()`가 mode를 `.idle`로 바꾸기 전에 durable owner, 목표 tuple, mutation 단계, 이전 안전 모드를 별도의 typed 초기화 복구 context에 보존한다. backend/preflight 실패, mutation 전 실패, mutation 후 검증 불확실, 확인된 drift를 구분하고 `previous == nil`이어도 상태/복구 안내가 나타나게 한다. 검증 불확실 상태에서도 충돌 제어는 잠그되 `상태 다시 확인`을 허용한다. 이 PR 자체에 짧고 유한한 read-only 자동 재확인 window를 포함한다. 실패 뒤에도 사용자가 언제든 다시 읽을 수 있어야 한다. 재확인으로 기대 tuple이 완전히 확인되면 중단됐던 초기화 인프라를 중복 없이 재구성하고 readiness를 `ready`로 만든다. CLI 미사용 상태나 preflight 실패에서 backend가 없는 경우는 초기화 자체의 명시적 재시도 경로로 분리한다. 앱 시작 NSAlert가 modal로 복구 UI를 영구 차단하지 않도록 오류 표시를 비차단으로 바꾼다.

**이유:** 이번 사건의 직접적 교착이다. 재시작이나 수동 CLI 없이 이미 안전한 상태를 회복할 수 있어야 한다.

**테스트:** `previous == nil`과 `readiness.failed`에서 복구 UI/재확인 가능; 일시 status 실패→정확한 Maintain 80 확인→monitoring/observer 한 번만 재시작; 불일치·센서 불가·backend 미개방은 ready가 되지 않음; 같은 버튼 중복 누름·shutdown 경쟁·stale generation; observer 등록 실패는 degraded fallback으로 완료; PR 1 단독으로 이번 장애 fixture를 통과; 기본 XCTest에서 실제 하드웨어/로그인 항목/운영 store 접근 0회.

### PR 2 — 공통 post-command 검증 안정화

**수정:** CLI preflight의 첫 status 읽기와 Maintain, charging off, 제어 해제, wake 복원의 post-command 검증을 작은 공통 read-only settlement 정책으로 묶는다. preflight의 version/path/owner 검증 자체는 절대 재시도 성공으로 우회하지 않는다. 기존 잠자기/long-running launch 구현을 성급히 교체하지 말고 동등한 조건과 예외를 먼저 표로 비교한다. 특히 잠자기 settlement는 현재 tuple mismatch만 재시도하고 status read failure는 즉시 종료한다는 점을 명시한다. mutation은 한 번만, status 시도별 상한과 작업 전체 monotonic deadline을 함께 둔다. runner의 정상 teardown이 확인된 조회 timeout과 완전한 tuple의 일시 mismatch만 재확인 후보로 삼는다. unsupported/malformed/truncated output, ambiguous/stale/duplicate worker, runner cleanup failure, 취소는 fail-fast로 둔다. 모든 attempt는 exact worker identity까지 검사하며 기존 control gate 안에서 직렬화한다. `releasing`의 durable journal 최종 기록은 완전 검증 이후에만 한다.

**이유:** 정상 명령 뒤 단발성 2초 관측 실패가 앱 전체 실패로 확대되는 패턴을 명령마다 반복하지 않게 한다. 2초는 per-attempt 한계이지 영구 실패의 근거가 아니다.

**성능/기한:** 정상 경로는 status 1회로 유지한다. 추가 읽기는 변경 직후·초기화/wake의 제한된 복구 구간에만 허용한다. 일반 명령과 sleep acknowledgement는 서로 다른 절대 기한을 가진다. 구체적인 총 기한과 backoff는 정상/느린 실제 CLI 분포 및 sleep acknowledgement 예산을 측정해 PR에서 확정한다. 각 attempt에 총 기한을 새로 부여하지 않는다. timeout이 하위 프로세스 정리를 완료하지 못하면 재시도를 금지한다.

**테스트:** 최초 일치, timeout→일치, mismatch→일치, 지속 실패, partial/truncated output, worker ambiguity, 취소, deadline 직전, 명령 정확히 1회, journal commit 경계, 다른 작업과 gate 경쟁. 주입 clock/fixture로 실제 대기 없이 판정한다.

### PR 3 — 복구·종료·wake의 단일 소유권과 최종 재검증

**수정:** recovery Task가 readiness와 mode 변경의 소유자가 되도록 generation/operation ID를 일관되게 검사하고, 조기 return·취소·shutdown 경합 시 readiness가 `.reconciling`에 갇히지 않도록 명시적 종료 처리를 둔다. 상태 read 뒤 temperature `await`가 있으면 최종 CLI tuple과 owned process liveness를 다시 읽고, 같은 generation/ownership/expected mode인지 확인한 후에만 정상 상태로 전이한다. 이 중간에 tuple이 바뀌면 drift/unknown으로 남긴다. 이미 종료된 initialization infrastructure를 `ready` 전환과 혼동하지 않는다. shutdown은 fresh read로 판단하고 실패 시 기존 retryable 상태와 assertion을 보존한다.

**이유:** PR 1·2로 재확인이 가능해져도 늦은 완료가 새 의도나 안전 상태를 덮어쓰면 다른 자동 복구 오류가 생긴다.

**테스트:** status read→temperature 대기 중 tuple 변경, wake→recovery 교차, recovery→quit 교차, 새 generation으로 오래된 completion 무효화, 취소 후 readiness 복원, Discharge assertion 유지·해제 조건, postflight 센서 실패 시 충전 재개 성공 표시 금지.

### PR 4 — Heat Protection의 검증된 재시도 간격

**수정:** `HeatRestoreReblockedError`처럼 실제 충전 차단 tuple로 재확인된 restore 실패에도 retry-after를 적용한다. 같은 이유의 반복 시도에는 짧은 시작 간격과 상한이 있는 backoff를 쓰고, 안전 온도·신선도·독립 SMC coverage를 다시 확인한다. 새로운 온도 edge나 사용자 설정 변경이 backoff를 앞당길 수 있는지는 안전 조건과 함께 명시한다. 차단 상태가 *검증되지 않았으면* 자동 restore 대상으로 취급하지 않는다. Heat 진입 실패와 restore 실패의 retry 의미를 테스트로 분리한다.

**이유:** 센서 평가 주기마다 불필요한 privileged mutation을 반복하는 회복 루프를 막으면서 정상 온도 복귀는 자동으로 처리한다.

**테스트:** 재차단 직후 중복 command 없음, 지정 시각 후 1회, 연속 실패 backoff, 온도/센서 실패 시 차단 유지, generation 변경·ownership release 시 예약 재시도 무효화.

### PR 5 — 비안전 데이터의 자체 복구와 관측성

**수정:** history store의 일시적 load 실패에는 앱 내 명시적 재시도 또는 낮은 빈도의 제한된 재열기 경로를 마련한다. pending 기록을 무제한 축적하지 않고 기존 상한을 유지한다. 충전 제어 readiness와 history readiness는 독립적으로 표시한다. 각 복구 transaction에 `operation ID`, 단계, status attempt 횟수/elapsed, 마지막 완전 tuple, 최종 분류를 typed diagnostic으로 남긴다. safety/lifecycle 실패는 즉시 flush하되 정상 반복 관측마다 파일을 쓰지는 않는다. 이전 진단 schema는 계속 읽혀야 한다.

**이유:** 충전 제어와 무관한 저장소 오류로 재시작을 요구하지 않고, 다음 장애 때 timeout의 위치와 최종 하드웨어 상태를 추측하지 않기 위해서다.

**테스트:** store 실패→재시도 성공/반복 실패, 데이터 중복 없음, 구 schema migration, event ID 고유성, 진단 flush barrier, routine diagnostic 쓰기 증가 없음.

각 PR은 직전 PR이 병합된 최신 `main`에서 분기한다. PR 5의 history 변경은 안전 경로와 독립이므로 충전 복구가 지연되면 별도 후속 PR로 미룬다. 서로 다른 변경을 한 PR에 모으기 위해 merge를 늦추지 않는다.

## 5. 검증 게이트와 완료 조건

1. 각 PR의 targeted fake-backend/fixture tests를 먼저 통과시킨다. XCTest host는 inert monitor, 격리 defaults, in-memory store, disabled diagnostics를 사용한다.
2. 기본 테스트가 실제 battery CLI, login item, production Core Data store를 건드리지 않는 것이 확인된 뒤 전체 test, strict-concurrency warnings-as-errors build-for-testing, Release build, Analyze를 수행한다.
3. PR 1·2 이후 사용자 승인 하에 통제된 실제 Mac 시험을 한다. 기준 상태와 종료 상태는 Maintain 80, non-discharge, exact worker 1개 및 PID identity 일치로 기록한다. 정상 CLI 시간뿐 아니라 wake 직후의 지연 분포와 operation-correlated raw diagnostics를 보존한다. 재현 실패도 누락하지 않는다.
4. 하드웨어 시나리오: 일반 실행/재실행, 짧고 긴 sleep/wake, wake 직후 첫 status 지연, 잠자기 중 AC 변경, transient timeout 후 자동 읽기 복구, 지속 status 실패, 외부 Terminal 변경, Heat 차단/복귀, 종료 경쟁. 실제 timeout·unsafe state를 고의로 만드는 조작은 사전 승인된 안전 범위에서만 한다.
5. 성공 기준: 정상 확인은 불필요한 추가 read/mutation 없이 끝난다; transient read 실패는 정해진 기한 안에 최신 전체 tuple로 회복된다; persistent/ambiguous/unsafe 실패는 잠긴 상태와 명확한 이유/재시도 동작을 남긴다; 어떤 자동 복구도 외부 변경을 덮어쓰거나 충전을 검증 없이 재개하지 않는다; initialization observer/monitor는 정확히 한 세트만 실행된다; idle CPU/wakeup 증가가 유의미하면 원자료로 검토한다.

## 6. 병합 거부 조건과 남는 한계

- timeout 횟수만 늘리고 readiness 교착을 그대로 둔다.
- status read 실패 후 mutation을 자동 반복하거나 마지막 성공 snapshot을 재사용한다.
- 정확한 worker/PID identity 또는 post-temperature 최종 tuple 확인 없이 `ready`/`maintaining`을 발표한다.
- 외부 drift, ownership mismatch, Heat 센서 실패를 일반적인 transient로 취급한다.
- 자동 recovery timer가 상시 고빈도 polling이나 반복 hardware mutation이 된다.
- 실제 하드웨어를 기본 테스트가 건드리거나, raw 실패 증거 없이 하드웨어 성공을 선언한다.

완전한 무인 복구는 **검증 가능한 상태**에서만 가능하다. CLI가 계속 응답하지 않거나 process cleanup/ownership이 불명확하면 앱은 안전하게 멈추고 사용자의 명시적 결정을 요청해야 한다. 이 경계는 버그가 아니라 하드웨어 제어 앱의 의도된 안전 한계다.

## 7. 실행 기록 (2026-10-02)

- PR 1 범위: 초기화 실패의 typed 복구 context, read-only 상태 재검증, `previous == nil`에서도 접근 가능한 재시도, 비차단 오류 UI, 인프라 재구성 후 readiness 전환. 이 PR의 독립 strict-concurrency 전체 테스트 통과.
- PR 2 범위: 단일 명령 뒤 bounded status settlement, preflight와 잠자기 확인의 일시 timeout 재시도, operation-correlated typed 진단. 진단 필드는 검증 구현과 함께 두어 이 PR만으로 실패 증거를 남긴다.
- PR 3 범위: 수동 복구와 wake의 온도 `await` 뒤 최종 tuple 재검증, generation 확인, shutdown 경합의 readiness 복원.
- PR 4 범위: 검증된 Heat 재차단에 bounded backoff, 불확실한 복원 실패는 수동 개입으로 분류.
- PR 5 범위: 실패한 이력 저장소의 낮은 빈도 재열기 및 데이터 보존.
- 전체 변경에서 strict-concurrency warnings-as-errors XCTest, Release build, Debug Analyze, strict build-for-testing 통과. 기본 테스트는 fixture/fake/in-memory 설정으로 실행했으며 실제 배터리 CLI 명령은 실행하지 않았다.
- 미완료: 실제 충전기·잠자기·온도 조건을 이용하는 통제된 하드웨어 시나리오와 시간/전력 원자료 수집. 사용자와 함께 현재 상태를 확인한 뒤 별도 승인된 단계로 진행한다. 이 기록 전에는 실기기 검증 완료나 무인 복구의 절대 보장을 주장하지 않는다.
