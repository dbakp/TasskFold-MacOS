# Filter review keyboard layout · 6 November 2026

On iPhone and iPad, Suggest a filter uses its existing header action slot to offer **Done** while either text field is being edited. Done has the spoken name **Hide keyboard**. Once editing ends, the usual **Use** action returns with the same preview/source/freshness guards. Cancel remains independently available. Mac retains its existing Use action and native keyboard behavior. No extra bottom bar or keyboard accessory toolbar is mounted.

The previous identical source in both owners produced an Invalid frame dimension warning during the recorded iPhone expression-focus journey. The first attempted replacement used a conditional bottom safe-area bar; its partial journey lost typing focus, so that variant was removed. Its zero-warning partial result is explicitly not accepted as a fix. The retained header version avoids changing the Form’s bottom inset during focus transitions. This describes the implemented layout; scoped native and signed-build evidence is recorded separately.

There are no changes to filter grammar, matching, live preview invalidation, final fresh destination/date checks, draft-only Use or the separate filter Save. No task data is sent to a model; on-device-only generation retains its existing explicit-input policy. No task stores, hosted definitions or rollout gates are changed. Normal Mac23 remains running and iPhone34 remains the last verified installation; further phone installation stays deferred.

## Accepted iPhone scope

The current signed iPhone Simulator journey passes one test with zero failures, skips or runtime warnings. It exercises exact typing, Clear and the new header Done, five-of-seven preview samples, archived-task exclusion, zero/completed queries, edit invalidation, draft-only Use, Cancel and all-table preservation after cold relaunch. The full existing strict wrapper remains unchanged and accepts the result. The exact tested source hashes, product hashes and saved-work proof are retained in `iphone.json`; `iphone-build.json` records the signed build. The recorded sample screenshot has a fully readable title and unobstructed five-item list.

This closes the previously recorded filter-focus warning for this current-source normal-text iPhone journey. It does not close the separate reviewed-step pending/settled Form warning or accept real generation, iPad/Mac interaction, speech, largest text, live access/date races or physical smoothness. No extra Core suite was rerun for a view-only layout change.

## Daily-use package

Mac 1.2.0 (25) is built as optimized Release, signed and archived. Exact archive readback, strict signature, cached embedded development profiles and owning metadata checks pass. It remains uninstalled. App, widgets and incoming Share are included. Existing profile expiry remains 2026-11-10T18:32:04+00:00; cached signing does not renew it. Installed Mac23 and phone34 remain unchanged. No normal feature gate or hosted service change.
