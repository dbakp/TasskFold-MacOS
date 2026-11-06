# Calendar test correction

The first phone/tablet scenario passed its task-detail/completion assertions,
but screenshot review showed Week in images labelled Month and Year. The test
had pinned calendarMode through a launch argument, which overrides the stored
preference while the process runs. Those runs are not accepted as cross-mode
coverage.

The final scenario omits the launch override while switching modes, waits for
the requested mode to acquire its selected accessibility state, and verifies
the editor has closed before capturing each screen. Final summaries and
screenshots are recorded separately. No product behavior was changed to make
the test pass.
