# Test isolation: automated runs never reach the hosted backend

Rule: no test, UI test, preview, fixture or capture run may contact the hosted Supabase project
(`zqxflydiyfjeedqvyova`) or any other `*.supabase.co` host. Test accounts and data live on
`127.0.0.1` (local `supabase start`) or an unroutable stub (`https://hosted-backend-blocked-in-tests.invalid`).

## In the app (`HostedBackendGuard`, in `Taskfold/Core/Backend.swift`)

A run is a *test context* when any of these holds: XCTest or `swift test` is loaded (or an `XCTest*` environment
variable is set), the process has any `--` launch argument (`--uitesting`, `--preview`, `--live-auth-ui-test`,
`--capture=...`, every fixture flag), the bundle is an isolated test host (id contains `tests` or `.p0`), or
`TASKFOLD_TEST_CONTEXT=1`.

In a test context `Backend` refuses a URL whose host is the hosted project or ends in `.supabase.co`
(also `.supabase.in`, `.supabase.red`, `.supabase.net`):

- A configuration passed in code that names a hosted host stops the process with a precondition in DEBUG builds.
- The bundled `Backend.plist` (hosted) is replaced by the unroutable stub, with the public key dropped, and the refusal is
  logged loudly to stderr and the system log. The app then fails to connect instead of reaching production.
- Every request is checked again on the wire, whatever built the configuration.

Deliberate live test: a human exports `TASKFOLD_ALLOW_HOSTED_TESTS=1` (exactly `1`) for that run.
Unit tests that read a live fixture skip unless it is set. UI tests that sign in to a hosted fixture also skip unless
`TEST_RUNNER_TASKFOLD_ALLOW_HOSTED_TESTS=1` is set for `xcodebuild` (they forward it to the app via `launchEnvironment`).
Never set it in CI, scripts or agent runs, and use only disposable `example.invalid` accounts.

## In scripts

- `Scripts/test_isolation.py`: `require_remote`, `install_network_guard` and `isolate_backend_plist`. Python scripts that call a
  backend refuse hosted URLs unless run with `--remote`. Refusal is immediate (exit 2) with no confirmation prompt.
- `Scripts/Diagnostics/remote-guard.mjs`, and the `--remote` check in `enable_*_hosted.sh` and `automation_hosted_acceptance.sh`, do the
  same for the hosted-branch and owner scripts.
- `prepare_*` scripts that copy the app into a test host rewrite its `Backend.plist` to the stub unless
  `TASKFOLD_ALLOW_HOSTED_TESTS=1` is set. `prepare_team_editor_native_test.py` and `prepare_watch_paired_test.py` already used a stub.
- `Scripts/Database/*` runs on in-memory PGlite, Docker-local Postgres or `.invalid` stubs and never contacts a remote database.
  `Scripts/check_test_isolation.py` (run by `Scripts/test_core.sh`) fails if one starts naming a `*.supabase.co` project, or if any
  test or script names the hosted project without its guard.
- Do not create or delete hosted accounts from tests. Use `supabase start` and local sign-up.

## Tests

`TaskfoldTests/HostedBackendGuardTests.swift` (9 tests) and `Scripts/test_test_isolation.py` cover detection, opt-in,
stubbing, refusal and the wire check. Run `Scripts/test_core.sh`.
