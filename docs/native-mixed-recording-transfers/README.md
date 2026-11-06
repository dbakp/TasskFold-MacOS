# Native transfers with mixed recording history · 6 November 2026

The reserved native integration now reviews a published recording, a genuinely in-flight upload and a removed recording together. It uses the same Store factory, protected original-request journal and Backend as the transfer screen. The explicit private-history policy and all three counts must match the current server inventory before the app can queue a command. This changes only DEBUG acceptance code and the owning test driver; existing production policies, UI, schema and rollout gates are unchanged.

The new `--project-transfer-mixed` mode uses actual disposable Auth, REST, Storage and production handlers. It publishes and removes synthetic media through the production API, starts another real upload, and holds its successful Storage response while the actual app reviews and commits the transfer. An old-audience download also crosses the native commit. The original request must survive offline send and a committed lost reply, then confirm across cold processes while fresh transfers are paused. The published object alone moves to the new audience; stopped and removed originals must remain fenced privately. Original published/removed ledgers, original Storage objects, exact recording bytes, complete canonical task fields and older nested content are compared separately.

Reproduce after building the current own signed isolated host:

```
node Scripts/Database/test-native-audio-publication.mjs ios /tmp/taskfold-new-native-mixed.json --keychain --project-transfer-mixed
```

Use Node 22 or later. The original `--project-transfer` published-only mode remains available. Each repository owns its implementation independently. The Mac protected-transfer runtime still requires its own dedicated provisioned app identity/profile; an iPhone pass does not establish a Mac pass. Mixed files, other realm directions, wider account/window/background/lifecycle histories, actual transfer-screen interaction, physical protection and hosted Storage remain separately unaccepted. Installed apps and frozen daily packages are unchanged.

## Recorded result

The signed current-source iPhone app passes all 50 named checks (`ios.json`), with source identity verified before and after. The actual transfer review binds counts 1 published / 1 unfinished / 1 retained. Only three original uploads occur; cold transfer retry and the stopped sender retry add none. Both original private fences are exact. The Mac-owned candidate compiles and passes strict signature verification (`mac-build.json`); its protected-transfer runtime is not accepted. The iPhone report is iOS-owner evidence retained here for the shared progress record, not a Mac runtime result. No new Core unit tests were added: the change is DEBUG integration coverage over existing policies. Previous Core evidence keeps its own original source scope.

The app and all five owned services/internal network are closed/removed, temporary private app fixture files are removed, and the used Simulator is restored to shutdown. Both compiler caches remain within 768 MiB. Completed raw compiler logs were retired after compressed copies and SHA-256 records were retained. Free space is about 57.7 GiB; changes in global free space are not attributed solely to this run. Real data, backups, normal Keychain items, installed apps, frozen candidates, unrelated devices and Docker user volumes were untouched.
