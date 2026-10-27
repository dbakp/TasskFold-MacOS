# Audio draft review candidate — scoped evidence

The feature remains gated and unfinished. See ../AUDIO_COMMENTS.md for the full
remaining lifecycle. The native host uses generated tone data and a silent player;
no microphone, speech-permission prompt or speaker output is opened by these tests.

- core.log: 47 actual focused Core cases on this Mac.
- audio-controller.json: 19 actual controller/codec/vault checks with synthetic drivers.
- dictation-controller.json: 17 checks after the shared input-lease refactor.
- duration-regression-before.json: the old counter fails one new duration check;
  final controller/native checks retain the old duration and caption after refusal.
- verification.json: source/binary hashes, scope and accepted native run mapping.
- captures.json and PNGs: selected synthetic native screens, inspected visually.

Mac's final run has four passes. iPad's final run has four passes. iPhone's main
run has three passes and one test-navigation failure; a targeted rerun accepts that
remaining case after explicitly scrolling upward to the timer. The failed main
summary is retained rather than relabeled as a passing suite. The app code is
unchanged between those iPhone runs. All accepted runs report no runtime warnings.
Largest-text native acceptance applies to iPhone/iPad; Mac's dark case uses its
ordinary native text size. These checks establish neither genuine audio/TCC nor
spoken accessibility, production permission enforcement, ordinary app integration,
background/window/Quit preservation or complete Px readiness.
