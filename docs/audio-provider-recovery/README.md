# Interrupted recording service recovery

Reviewed 2 November 2026. Each repository independently passes 42 assertions against its own production gateway, actual local PostgreSQL and pinned Storage API. This milestone adds failure coverage and synthetic fault controls; it changes no production app/service logic, schema, hosted project or normal-use feature gate.

- An actual upload commits, then its response is replaced by HTTP 503 and immediate readback is refused once. The reservation and open writer remain quota-counted. Metadata Check performs no Storage request. An explicit retry verifies the existing bytes, settles the writer and returns the same immutable receipt without another media POST.
- Storage actually deletes the recording, but its reply is replaced by HTTP 503. The ledger stays retired and quota-counted. Its active cleanup claim prevents a second DELETE. After advancing only the synthetic claim expiry, a fresh claim rotates its token; the old token cannot release quota. The real Storage API accepts a second removal of the absent object, and verified absence permits the new claim to finish.
- Publication finalization commits in SQL before its reply is replaced by HTTP 503. Metadata status recovers the exact operation without uploading or downloading media.
- Cleanup confirmation commits before its reply is replaced by HTTP 503. The worker reports an unresolved response, but the terminal SQL state and released quota remain correct. The next worker neither claims nor deletes it again.
- A second ambiguous upload is explicitly closed by its sender. The worker hashes the real stored bytes, reconciles the unresolved writer, then removes the object and releases quota. All three operation identities remain; each uploaded only once, all finish purged, no open writer remains, and the task is unchanged.

The fixture replaces replies only after observing actual provider/SQL success. It does not simulate success by editing Storage metadata. The only direct timing changes are to cleanup eligibility and one known synthetic claim expiry. Real provider responses remain recorded in provider-report.json. All owned services are closed without cleanup errors; no native app, Simulator or real task is used.

The unchanged default controlled-byte adapter also passes 93 PostgreSQL gateway boundary regressions per repository, including no new advisor findings. The progress checklist passes light/dark checks at 320, 736 and 1,024 pixels with 28 scoped substeps and the same 74 curated checkpoints.

Auth is a controlled adapter; the owning migration loader still uses a minimal base-schema bootstrap around actual Storage schema and selected unchanged production migrations. This is not genuine sign-in, hosted deployment, full production-schema parity, hardware capture/playback or native lifecycle acceptance. Existing mobile UI evidence remains in [native delivery](../audio-real-provider-native/README.md). Unknown uploads with absent/corrupt bytes, concurrent account/window/background changes, Mac UI/speech/privacy, generation restoration and whole-project transfers remain open.

Run from the owning repository with its installed dependencies:

```sh
node Scripts/Database/test-audio-provider-recovery.mjs /tmp/taskfold-audio-recovery-fresh.json
```

The runner requires the default 20 GiB storage floor and removes only its own services. Verification records exact source/report hashes and attempt qualifications. Earlier unchanged app builds and 52 service unit tests were not rerun for this test-only milestone.

Follow-up: the [certified generation-restoration service](../audio-generation-restore/README.md) now has separate local proof. Native review, wider lifecycle and whole-project transfers remain open. Earlier remaining lists describe their original stage.
