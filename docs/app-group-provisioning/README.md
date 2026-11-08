# Shared app-group provisioning

The installed Mac53 app, widget and share extension each declare group.com.dbakp.taskfold. Their embedded profiles contain no application-groups authorization. Earlier runtime logs show rejection, an App Data prompt, then successful fallback access. Mac53 remains installed and usable; this work does not revoke its permissions or move its data.

Apple currently recommends provisioned group-prefixed identifiers on macOS. The profile must authorize the group, and Xcode can refresh automatic profiles with REGISTER_APP_GROUPS=YES. Team-prefixed macOS-only identifiers are another supported scheme, with different platform/keychain limitations. We retain the existing identifier to avoid a data/queue migration. Sources: [existing macOS groups](https://developer.apple.com/documentation/xcode/accessing-app-group-containers), [configuration](https://developer.apple.com/documentation/xcode/configuring-app-groups), [entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups).

## Changes

Mac project configurations now enable group registration for the app and both extensions. Both independent owners select cached profiles only when they authorize every declared group. Both inspect actual signed app/extension claims against actual embedded profiles before recording daily readiness; Simulator output explicitly does not establish that authorization. The Mac release-artifact check applies the same test. Correct macOS team-prefixed groups remain supported, including the allowed no-profile case. Real teams and matching bundle-family groups are required. New audit code is included in cached build-tool provenance.

## Evidence and remaining work

Each owner passes19 unit cases: policy boundaries, missing/newer unauthorized profiles, every group/bundle, synthetic actual-file bundle inspection, mismatched teams, macOS-vs-iOS rules, all six target configurations and refusal before project mutation. These use synthetic public certificate/profile fixtures; no genuine successful provisioned runtime is claimed. The read-only audit of all three installed53 profiles fails authorization as expected.

A real Release54 attempt with automatic provisioning fails before compilation: Xcode reports No Accounts and all three profiles lack the App Groups capability/identifier/entitlement. No54 package/receipt is accepted and the installed53 app remains untouched. The existing installed app and archive are preserved. The user has been asked to sign into Xcode with the existing development team; account credentials belong only in Xcode. Once available, refresh profiles, require the new package audit to pass, then inspect actual startup/group lookup and prompts. If membership/registration remains unavailable, review a safe compatibility/migration plan before considering another namespace; never abandon old shared drafts or queued actions.

No Swift app code, storage format, app-group identifier, Keychain namespace, task data, hosted schema or normal feature gates change. No Simulator is booted. Only the used daily-build cache is cleaned. AppStore/distribution work and iPhone installation remain deferred. The missing runtime acceptance stays visible on the progress checklist.
