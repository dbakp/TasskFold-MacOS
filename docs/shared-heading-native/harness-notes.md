# Initial failures and fixes

Initial phone/tablet runs exposed a real Undo failure: Store created a fresh
field-only baseline before completion capture. Both Stores now use the complete
edit-baseline helper. The final five native cases pass on each device.
The phone’s debug Fail test save button was in toolbar overflow; the tablet could
activate it. The retry case now uses the existing creation first-save failure
switch. Production UI is not changed to accommodate test access. The initial
native runs ended with completed failed suites and exit 65; they were not passing
acceptance, and no collector was restarted on an observation timeout.

The first Mac build specified a certificate common-name suffix as its team and a
full identity under automatic signing. Existing signed output and the public
certificate identified the actual development team; generic Apple Development
with that verified team succeeds. The new Mac test was initially placed in an
unregistered empty source file without imports. It now resides in the existing
registered TaskfoldMacUITests.swift. The final signed app/runner build passes.
Its runtime then fails before any case with a timeout enabling Xcode automation
mode. No DevToolsSecurity helper or system-setting change was used.
