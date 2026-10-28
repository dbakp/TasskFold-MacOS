# Shared read-only audio conversations — 28 October 2026

The gated audio viewer now admits current project readers independently of private-draft/publication ownership. Team audio publishing and removal remain closed; no hosted migration or ordinary feature flag is enabled.

## Implemented

- A dedicated client read policy accepts legacy project owners/collaborators and current team manager/editor/viewer boundaries, including archived projects. Every project requires a current account/server-bound access boundary; project creator fields alone never substitute for it. Team reads additionally require the Teams flag, native-team-read boundary capability and the known task/project/team binding. Own Inbox reads retain a separate owner check. Headings, foreign/stale boundaries and known team tasks presented as Inbox refuse.
- Store viewing admission no longer calls the private draft/publishing writer. Live workspace/account/session, current presentation rows, read policy, source generation/project and scene state bind the viewer. The existing writer, draft storage and pending-send admission remain unchanged.
- Shared conversations offer Audio comments independently of their text-writing controls. Root editors/inspectors use the read request path. Author names use the existing scoped conversation-member lookup, with its safe fallback. This is an entry-point integration, not a unified chronological text/audio timeline.
- Removal is a separate controller authority callback, default-denied and rechecked before a request. Team read roles cannot remove audio, even their own; supported legacy authors/project owners retain their existing server-enforced removal path. Hidden/changed UI controls never grant authority. Refused removal leaves the server recording published; refused team publishing creates no operation.
- A separate private SQL read scope checks live team membership/grants and exact task generation/project/team custody. It uses locked membership/custody rows and the existing team read switch/role resolver, with no creator shortcut. Native pages and both pre/post-Storage read checks use this read scope. Other command actions delegate to the unchanged fenced publication/removal coordinator. No team write policy or client table grant is widened.
- Native 401/403/404 read refusals clear previously loaded conversation rows, playback and pagination position. Network failures retain the retry position. Context departure and existing lifecycle hooks continue to revoke late callbacks.

## Verified independently per repo

**184 Core audio tests** cover team viewers, archived reads, absent/disabled/foreign boundaries, legacy collaborator read/removal distinction, own-project boundary requirements and the separate Inbox path, alongside prior recording/publication/recovery cases.

**273 actual controller checks** include read-only removal refusal before any transport call and denied-page clearing of prior private rows/cursor/playback. These use synthetic media drivers; they are not spoken/native UI acceptance.

**30 real PostgreSQL/gateway/shared-native checks** cover viewer/manager reads, creator/outsider refusal, wrong generation, archive reads, the team read switch, grant restoration and membership removal, legacy accepted-share read/revocation and unchanged denied-write state. The actual native Backend pages, downloads and fully decodes the shared recording; its removal request is refused. No media is uploaded by this reader. Revoking the viewer grant during a real gateway Storage read withholds the audio response, and the following page refuses. Advisors run before/after with no added findings. Controlled Auth/Storage and directly seeded synthetic pre-adoption metadata are fixtures, not real provider, adoption-command or device custody acceptance.

**24 native publication/gateway/PostgreSQL regression checks** still pass with the new command delegation: lost publication/removal replies, same-operation retry, retained/compact confirmation, verified readback and unchanged private storage. Owned database containers and native scratch inputs are removed.

Full unsigned builds pass for Mac arm64 and iOS Simulator arm64/x86_64. Build metadata hashes the executable stub and loaded debug-code dylib. Ordinary draft/publishing flags remain absent/off; no app is launched and no microphone/dictation/speaker/system-setting check is requested here. Existing unrelated compiler warnings remain in logs. Compilation is not visual, native interaction, largest-text or spoken acceptance.

[Builds](builds.json) · [Sources](source-bindings.json) · [Core iOS](core-ios.txt) · [Core Mac](core-mac.txt) · [Controller iOS](controller-ios.json) · [Controller Mac](controller-mac.json) · [Shared iOS](shared-ios.json) · [Shared Mac](shared-mac.json) · [Publication regression iOS](native-ios.json) · [Publication regression Mac](native-mac.json) · [iOS build](app-ios.log.gz) · [Mac build](app-mac.log.gz).

Reproduce independently in either repo:

```sh
swift test --scratch-path /tmp/taskfold-audio-shared-core --jobs 2 --filter AudioComment
python3 Scripts/test_audio_comment_capture.py --scratch /tmp/taskfold-audio-shared-core --output /tmp/audio-shared-controller.json
node Scripts/Database/test-audio-shared-reads.mjs /tmp/audio-shared-db.json supabase/migrations/20261028191118_audio_comment_shared_reads.sql /tmp/taskfold-audio-shared-core
node Scripts/Database/test-audio-native-publication.mjs /tmp/taskfold-audio-shared-core /tmp/audio-shared-native.json --retain-audio
```

The forward migration was created with `supabase migration new audio_comment_shared_reads` after the draft passed actual PostgreSQL/advisor checks, then reapplied and verified from each repo's final migration file. Ordinary client roles cannot call the private helpers; public service wrappers retain restricted grants. No hosted schema/configuration/data changes occur.

## Remaining acceptance and implementation

- Native UI/visual/keyboard/largest-text/spoken/account-change runtime acceptance of shared viewing, publication and recovery controls on Mac, iPhone and iPad. Synthetic native API execution does not accept Store/UI activation.
- Independently scoped team audio publishing/removal and reviewed media custody/adoption lifecycle. Read support deliberately does not enable these writes. Unified text/audio timeline presentation remains separate work.
- Unknown-upload terminal recovery, legacy unbound journals and compact-history policy; real hosted provider/custody/removal acceptance and user-deferred genuine audio/dictation checks.

The [pagination checkpoint](../audio-pagination/README.md) remains recorded. Audio and the overall Px objective remain unfinished and gated.
