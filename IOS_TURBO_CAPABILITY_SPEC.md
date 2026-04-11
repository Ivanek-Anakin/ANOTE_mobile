# iOS Turbo Capability Detection — Technical Spec & Implementation Plan

## Goal

Determine whether a given iPhone should expose and use local Turbo transcription without causing a bad user experience or risking repeated app crashes.

This spec is explicitly designed around the observed failure mode on the current iPhone:

- local on-device model startup can trigger iOS `jetsam`
- `jetsam` is a process kill, not a catchable Dart exception
- therefore a silent in-process Turbo probe at startup is not safe if it performs real Turbo initialization

## Product Outcome

After implementation, the app should:

1. Decide whether `Turbo` should be shown, hidden, or downgraded on a given device.
2. Default `Hybrid` to `Turbo` only on devices that are likely safe.
3. Default `Hybrid` to `Small` on unknown or constrained devices.
4. Persist device capability results so the decision improves after first real usage.
5. Avoid startup crashes caused by a hidden background Turbo test.

## Non-Goal

This design does **not** attempt to safely run a real Turbo init probe in the background on startup and survive failure. That is not feasible if the failure mode is iOS `jetsam`, because the whole app process would be terminated.

## Key Constraint

### Why silent startup probing is unsafe

If Turbo initialization exceeds the iOS memory budget, the OS kills the entire app process. A worker isolate does not help because it still belongs to the same app process. Therefore:

- a hidden real Turbo startup test can kill the app
- there is no reliable in-process sandbox for this test
- runtime free-memory sampling is not sufficient to guarantee safety

## Recommended Strategy

Use a layered capability system instead of a real silent probe.

### Layer 1 — Static device capability inference

Use conservative heuristics to classify a device before Turbo is ever attempted.

Inputs:

- platform (`iOS`, `Android`)
- device model identifier on iOS
- OS version
- total RAM if available
- known-good / known-bad device list

Possible initial decisions:

- `turboAllowed`
- `turboHidden`
- `hybridUsesTurbo`
- `hybridUsesSmall`

### Layer 2 — Persistent runtime evidence

Store what actually happened on this device.

Signals:

- Turbo init succeeded previously
- Turbo recording session completed previously
- App relaunched after a pending Turbo attempt marker was left uncleared
- Model init timed out

This lets the app learn per-device behavior without requiring repeated risky attempts.

### Layer 3 — Crash-history downgrade

If the app suspects that a Turbo attempt caused termination, it should mark Turbo unsupported for that device and hide or downgrade it on subsequent launches.

This produces one bad experience at most, instead of repeated crashes.

## Proposed UX

### Settings visibility

The settings UI should support three Turbo states:

1. `Available`
2. `Limited / Experimental`
3. `Unavailable on this device`

Recommended UX behavior:

- On clearly unsupported devices: hide Turbo entirely, or show it disabled with explanation.
- On known-good devices: show Turbo normally.
- On unknown devices: keep Turbo behind a warning or “experimental” badge.

### Hybrid default behavior

- known-good device: `Hybrid` defaults to Turbo local preview
- unknown device: `Hybrid` defaults to Small local preview
- known-bad device: `Hybrid` uses Small local preview, Turbo hidden or disabled

### User messaging

Warning copy should be informational, not error-like.

Examples:

- `Turbo není na tomto zařízení doporučen. Používá se Small.`
- `Zařízení podporuje Turbo model.`
- `Turbo bylo po předchozím selhání na tomto zařízení vypnuto.`

## Capability Model

Introduce a persistent device capability record.

### Example data model

```dart
enum TurboCapabilityStatus {
  unknown,
  allowed,
  discouraged,
  blocked,
}

class DeviceModelCapability {
  final String deviceId;
  final String platform;
  final String? deviceModel;
  final String? osVersion;
  final TurboCapabilityStatus turboStatus;
  final bool hybridPrefersTurbo;
  final bool previousTurboSuccess;
  final bool previousTurboCrashSuspected;
  final DateTime? lastEvaluatedAt;
}
```

### Storage

Persist in local preferences/secure storage under a device-specific key.

Suggested fields:

- `turbo_status`
- `hybrid_prefers_turbo`
- `turbo_probe_pending`
- `turbo_probe_succeeded`
- `turbo_crash_suspected`
- `device_model_identifier`

## Detection Sources

### iOS device metadata

Preferred metadata if obtainable:

- model identifier, e.g. `iPhone15,2`
- physical memory if accessible via native bridge
- OS version

This likely requires a small native iOS bridge rather than Dart-only logic.

### Initial policy table

Start with an allowlist/blocklist table.

Example policy concept:

- recent Pro / high-end devices: `allowed`
- older or lower-memory devices: `discouraged` or `blocked`
- unknown devices: `unknown`

Important: the initial table should be conservative.

## Safe Runtime Flow

### On app launch

1. Read persisted capability state.
2. Read device model metadata.
3. Resolve capability using:
   - persisted outcome
   - policy table
   - platform defaults
4. Update settings visibility and Hybrid default.
5. Do **not** run a real hidden Turbo init probe automatically.

### On user selecting Turbo explicitly

1. If device is `blocked`, prevent selection and explain why.
2. If device is `discouraged` or `unknown`, allow only with a clear warning.
3. Before attempting Turbo startup, write `turbo_probe_pending = true`.
4. If startup completes and first session stabilizes, write:
   - `turbo_probe_pending = false`
   - `turbo_probe_succeeded = true`
   - `turbo_status = allowed`
5. On next launch, if `turbo_probe_pending = true` is still present and the session never completed, infer crash suspicion and downgrade:
   - `turbo_status = blocked`
   - `turbo_crash_suspected = true`

### On Hybrid selection

Hybrid should select its local preview model based on capability state:

- `allowed` -> Turbo
- `unknown` -> Small
- `discouraged` -> Small
- `blocked` -> Small

This avoids making Hybrid itself the risky path on unknown iPhones.

## Why this is preferable

Compared to a hidden startup probe, this design:

- avoids intentional startup crash risk
- still adapts per device over time
- gives product-level control over Turbo visibility
- supports rollout using telemetry and device policy updates

## Implementation Plan

### Phase 1 — Capability plumbing

Goal: introduce capability state without behavior changes beyond visibility/default selection.

Tasks:

1. Add device capability model and persistence.
2. Add iOS device-model lookup via native bridge or plugin.
3. Add static policy resolver.
4. Add helper methods:
   - `canShowTurbo()`
   - `canUseTurbo()`
   - `hybridShouldUseTurbo()`

Files likely affected:

- `mobile/lib/providers/session_provider.dart`
- `mobile/lib/screens/settings_screen.dart`
- `mobile/lib/models/session_state.dart`
- `mobile/ios/Runner/*` for native device metadata bridge

### Phase 2 — UI and selection policy

Goal: wire capability into settings and model selection.

Tasks:

1. Hide or disable Turbo in Settings based on capability.
2. Add explanatory copy for hidden/disabled Turbo.
3. Make Hybrid choose local preview model from capability resolver.
4. Keep Cloud path unchanged.

### Phase 3 — Crash-suspicion persistence

Goal: let the app learn from real usage safely.

Tasks:

1. Write `turbo_probe_pending` immediately before any risky Turbo init.
2. Clear it only after successful init plus stable first usage milestone.
3. On next launch, if pending flag survived and no success was recorded, mark Turbo unsupported.
4. Automatically downgrade settings and hide Turbo thereafter.

### Phase 4 — Optional explicit compatibility test

Goal: allow manual user-initiated capability verification, not silent startup probing.

Tasks:

1. Add “Test Turbo compatibility” action.
2. Show explicit warning that the app may restart if unsupported.
3. Reuse the same `turbo_probe_pending` and crash-suspicion flow.

This is optional and should not be phase 1.

## Telemetry / Diagnostics

Recommended events:

- `device_capability_resolved`
- `turbo_selection_attempted`
- `turbo_selection_blocked`
- `turbo_init_succeeded`
- `turbo_crash_suspected`
- `hybrid_local_model_selected`

This will let the policy table improve over time.

## Risks

1. Device model heuristics may initially be overly conservative.
2. Crash-suspicion inference is probabilistic, not perfect.
3. iOS metadata access may require native bridge work.
4. Policy complexity can leak into UX if not centralized.

## Recommended First Implementation Slice

The first execution slice should be:

1. Add device capability persistence and a simple policy resolver.
2. Add iOS device-model lookup.
3. Hide/disable Turbo in Settings based on policy.
4. Make Hybrid choose `Small` on unknown iPhones and `Turbo` only on known-good devices.
5. Add `turbo_probe_pending` crash-suspicion persistence for future refinement.

This gives most of the product value without a dangerous startup probe.

## Out of Scope for First Pass

- dynamic live memory pressure estimation as the primary gate
- true hidden startup Turbo initialization probe
- remote config / server-driven capability policy
- Android-specific refactor beyond current heuristics

## Decision Summary

**Do not** implement a silent real Turbo init test on startup.

**Do** implement:

- device capability inference
- persisted per-device outcomes
- crash-suspicion downgrade
- Turbo visibility control in Settings
- Hybrid default-to-Turbo only on known-good devices
