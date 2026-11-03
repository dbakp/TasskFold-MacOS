# Searchable project parents

Both independently owned apps replace the long parent-project menu with a searchable native sheet. Project names and ancestor paths are searchable; selected parents and Top level remain explicit. Selection edits only the project draft. Cancel discards it; the existing Save path retains live validation. Selection also checks the current workspace/session and current eligible graph.

Parent eligibility now builds the canonical graph once rather than invoking the full write validator for every candidate. The write validator itself is unchanged. Deterministic oracle cases compare the optimized choices with that validator across malformed legacy graphs, duplicate identities/owners, cycles, depth boundaries and missing ancestors.

The iOS Debug Core diagnostic for 1,000 projects / 997 eligible choices measured 0.8230735 seconds before and 0.0058831 seconds after in one local observation each. These are bounded algorithm diagnostics, not frame-rate, device or whole-app claims. Mac has no measured before baseline.

## Verification

Each independently owned repo passes 178 selected Core tests, with four existing opt-in skips and no failures. The iPhone native case passes production search, draft Cancel, Save, cold return and restoration to Top level with 4,000 synthetic projects / 240 tasks, retaining every other project field, task and queued edit. The actual Store produced 3,596 eligible choices in 0.030771 seconds. The isolated app was closed and its Simulator state restored afterward. See `iphone-after.json`, `core-checks.json` and the retained saved-parent screenshot. Both current Debug apps and test runners build and pass strict signature verification (`build-verification.json`). App builds/signatures do not establish native Mac, spoken VoiceOver, cloud/account-change or all-screen acceptance. Those wider checks remain open.

No hosted deployment, release signing or deferred feature activation belongs to this change.
