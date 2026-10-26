# Acceptance harness notes

The first iPhone text-intake scenario passed; screenshots showed the source type
fields needed persistent visual labels. The labelled presentation then passed a
second iPhone scenario with the same Cancel/Save/cold-state assertions.

The initial iPad run was intentionally stopped after an actual Simulator
screenshot showed its global application swipe landing outside the narrower
modal. It had not reached the first contents review or Save. The test helper now
drags inside the visible modal, using its navigation bar as the coordinate anchor.
The cancelled CLI then hung while finalizing its log and was terminated; its
unfinished result bundle is not a passing or failing app result. Its transcript
and the synthetic live screenshot are retained in the iOS evidence directory.
After the runner/app stopped, only that Simulator’s DragUI helper was stopped:
it repeatedly appeared in remote-hierarchy errors with no accessible window.
No device data was erased. Final runs use a fresh UI runner and the scoped gesture.

The first signed Mac runner timed out enabling UI automation before invoking any
app test. Developer mode was disabled; system logs required authorization for
Enable UI Automation. SecurityAgent is explicitly inaccessible to computer use. A DevToolsSecurity
helper was attempted, then cancelled after Apple’s local man page confirmed that
it changes debugger authorization rather than the specific UI-automation grant.
The helper exited 143; Developer mode remained disabled, its original state. No
action is needed on that cancelled prompt. The actual Xcode Enable UI Automation
grant remains pending. This startup result is not an app-test failure.

The first coordinate-based helper still chose a background navigation bar by
query order. The iPad transcript identifies it as Templates rather than Map CSV
columns; the missing Review target then failed at 129.8 seconds. The CLI stalled
finalizing after its completed failure and was terminated. The final helper
selects the active Map CSV columns / Review template / Import template text bar
by name. Phone flows passed before this locator correction; final coverage is
recorded separately. The corrected Simulator calls returned to normal speed
after the scoped DragUI helper restart.
