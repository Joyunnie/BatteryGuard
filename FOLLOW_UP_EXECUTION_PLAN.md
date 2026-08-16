# BatteryGuard Follow-up Execution Plan

## Goal

Finish the remaining requested work without mixing installer, controller, process, or repository-cleanup risk. BatteryGuard remains a personal Apple Silicon app; public distribution, CI, notarization, auto-update, Intel support, and release automation remain out of scope.

## Pull Request Boundaries

### PR A — Plan and checkpoint consistency

- Add this execution plan.
- Update the stale `REFACTOR_PLAN.md` review footer from Checkpoint 23 / 296 tests to Checkpoint 24 / 311 tests.
- No production-code change.
- Verification: review the Markdown diff and confirm a clean worktree after merge.

### PR B — Friend installer

- Reapply the existing `feat/friend-installer` work onto the latest `main` without rewriting shared history.
- Keep the installer manual and local: no download-at-install time, no unpinned installer commands, no CI/release pipeline, and no notarization unless separately requested.
- Audit package scripts for root execution, path traversal, symlink handling, ownership, modes, exact battery CLI v1.3.4 validation, least-privilege `sudoers`, rollback, reinstall, and uninstall guidance.
- Explain the control-ownership choice: native macOS Charge Limit must be disabled before BatteryGuard owns charging; otherwise install in monitoring-only mode.
- Build the `.pkg`; inspect its payload, scripts, identifiers, permissions, and signature state; test install/reinstall on this Mac only after recording battery status; verify the app and exact 80% Maintain worker; restore the starting state.
- Keep generated packages out of Git.
- Merge only after hostile security review and the standard automated verification gates.

### PR C — `ChargeController` decomposition

- Pure refactor only. Do not change charge policy, state transitions, task ownership, generations, timeouts, diagnostics, or hardware commands.
- Split cohesive implementation areas into explicitly named files/extensions: initialization and observation, reconciliation, Heat Protection/temperature, long-running Top Up/Discharge, lifecycle/shutdown, and diagnostics/history where access boundaries allow.
- Keep stored state and hardware ownership in the primary `@MainActor ChargeController` declaration.
- Avoid new protocols or services unless moving code is impossible without a real boundary.
- Require a review proving each moved method has the same body and call graph, plus all automated gates.

### PR D — `SMCKit` decomposition

- Pure refactor only. Preserve the supported CLI version, executable identity contract, minimal PATH, parsing, worker identity checks, PID safeguards, timeout/cancellation behavior, and temperature fallback deadline.
- Split validation/preflight, command construction and status parsing, Maintain worker inspection, and temperature-reader compatibility into focused files/extensions.
- Keep mutation serialization in `BatteryCommandRunner`; do not introduce a second runner or competing process abstraction.
- Require targeted parser/worker/helper tests plus all automated gates.

## Verification Gates for Every Code PR

```sh
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug test
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug build-for-testing SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Release build
xcodebuild -project BatteryGuard.xcodeproj -scheme BatteryGuard -configuration Debug analyze
```

- Tests must use fakes, isolated defaults, in-memory storage, disabled diagnostics, and fixture executables.
- No automated check may invoke the real battery CLI, change a login item, or write the production store.
- Before merge, review the complete diff against `main`; reject behavior changes hidden inside either decomposition.
- Hardware checks remain read-only unless the user explicitly approves a controlled mutation.

## Repository Cleanup

After all PRs are merged:

1. Fetch and prune remote-tracking references without deleting branches.
2. Classify local branches as merged into `main`, unique/unmerged, or explicit backup.
3. Delete only local branches proven merged and not needed as backups; never force-delete a unique branch.
4. Delete remote branches only when GitHub reports their PR merged and the branch contains no unique commit.
5. Preserve `baseline/import` and explicit `backup/*` branches unless the user separately requests their removal.
6. Confirm generated `.pkg`, `.xcarchive`, DerivedData, diagnostics, and local secrets remain ignored and untracked.
7. Finish on clean, synchronized `main` with no open PR.

## Planned Order

1. PR A: plan/checkpoint documentation.
2. PR B: friend installer.
3. PR C: `ChargeController` decomposition.
4. PR D: `SMCKit` decomposition.
5. Repository cleanup and final verification/report.

## Completion Criteria

- All four PRs are reviewed, merged in order, and visible in `main`.
- The installed app remains in the intended 80% Maintain, non-discharge state after any approved hardware check.
- Automated verification passes on the final merged `main`.
- No unique branch or generated installer artifact is removed accidentally.
- Remaining work, if any, is recorded explicitly rather than implied by stale plan text.
