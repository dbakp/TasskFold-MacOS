# Restore working account removal

## Confirmed gap — 22 October 2026

Both native `Backend.deleteAccount()` implementations POST to `/functions/v1/delete-account`. The Taskfold project's live Edge Function inventory contains import-todoist, send-invitation-email, send-invitation-response-email, check-due-tasks and dispatch-reminders; it has no delete-account function. Direct management lookup also returns Function not found. The app therefore exposes an action whose server implementation is unavailable. This is a newly verified P0 gap, separate from the user's deferred distribution, general older-client and remote-reminder work.

No real account deletion was attempted. Disposable share-test cleanup used explicitly scoped operator removal after global session revocation; that is not acceptance of the app's Delete account action.

## Required next implementation

1. Independently own the endpoint source and verification inputs in both repositories. Inspect the deployed schema, storage ownership and current Auth deletion/revocation APIs before implementing cleanup.
2. Authenticate the actual caller on the server, reject unauthenticated/wrong-method requests, and derive the account from verified identity rather than a submitted account ID or editable metadata. Address active-session/revocation behavior for this destructive operation.
3. Define and test owned-data, uploaded-file and shared-project cleanup against the actual schema. Do not affect an unrelated account. Make partial failure and retry behavior explicit; do not report success after incomplete removal.
4. Keep native confirmation and failure recovery coherent. Clear the client session/workspace only after confirmed server success; preserve recoverable local work on refusal/failure.
5. Verify real HTTP and native removal with fresh disposable owner/outsider accounts, stored test content and retries. Inspect the resulting Auth/data/storage state and prove unrelated work remains unchanged. No real user's account is a test fixture.

The existing client action, a successful build and administrator fixture deletion do not prove this requirement. Endpoint implementation, controlled deployment and genuine native acceptance remain outstanding. The rest of `P2_PLAN.md` stays in scope after this correction.
