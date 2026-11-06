# Visual review

The first seven installed cases passed on each Simulator. The actual screenshots
then exposed an iPad issue: the inline progress/Cancel row lay below the current
preview viewport. The phone row was visible at the sheet edge. Green interaction
tests alone did not establish a good layout. The implementation was changed to
a bottom safe-area bar so both progress and Cancel remain visible independently
of the preview scroll position. The initial images/logs are retained here.
Final targeted tests and images must be assessed separately from that first run.

Final phone and iPad preparation screenshots were inspected. Both show the
complete progress text and Cancel in a fixed bottom bar. These are default-size,
light appearance screenshots; largest-text/dark/VoiceOver and Mac visual checks
are not inferred from them. Final targeted Cancel/dismiss tests pass twice per
device with unchanged saved data beyond the worker delay.
