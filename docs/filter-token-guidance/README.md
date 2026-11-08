# Direct token-guided filter generation: not accepted

This candidate keeps the existing single expression, production prompt, ordinary parser and review. It adds a fixed developer-authored regex guide for filter-language tokens instead of asking the model to learn a new semantic AST or produce an English paraphrase. Apple documents regex guides in [guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation) and its [framework deep dive](https://developer.apple.com/videos/play/wwdc2025/301/).

The exact candidate compiles. Its real twelve-goal Mac probe completes with twelve generation errors and no expressions; the driver correctly refuses acceptance. This does not measure semantic quality, and it is not a zero-of-twelve semantic score. No new oracle, relaxed parser, local-grammar result or successful formatting is substituted for inference. The original report and candidate remain in rejected-candidate. The candidate is not shipped; production FilterAssistanceEngine is restored byte-for-byte.

A separate bounded control test runs two additional actual requests on the same Mac: a plain generated structure returns “priority three” instead of the requested “p3”; a minimal p[1-4] regex guide also fails with a generation error. Both failed assertions and literal observations are preserved in generation-controls.json. This establishes text-generation activity and a minimal pattern failure, not a fully healthy model, an identified framework root cause, an unsupported API on every OS or successful filter classification. The opt-in control test is independently owned in both repos; actual controls ran only in the Mac owner. Ordinary tests skip inference.

Both restored owners execute 123 selected Core cases: 119 pass, four opt-in model/benchmark cases skip, no failures. Existing complete local descriptions remain. The prior raw-model quality result is not superseded. Future work must first account for the minimal pattern failure or use a materially different supported design; do not rerun this candidate unchanged to seek a passing result. Advanced target/Boolean/language quality and native review remain open.

All requests use only fixed synthetic descriptions. No private tasks/catalog, cloud fallback, saved filter/task writes, model setting change, permission change, hosted change, normal update or Simulator boot occurs. Mac 53 stays installed and usable. Both reused Core caches remain below 768 MiB. Cleanup checks are adjacent; tasks, backups, packages, rollback, Keychain, Docker, shared SDKs and other projects stay intact.

Reproduce the controls only when intentionally investigating the model runtime: TASKFOLD_TEST_ON_DEVICE_MODEL=1 bash Scripts/test_core.sh --filter FilterGuidanceControlTests. This is a diagnostic, not product-quality acceptance. The separate twelve-goal driver remains strict and unchanged.


## Runtime diagnosis, 8 November

Two additional standalone native controls used the same ready Mac model on macOS 26.6.2 (25G83), one synthetic request each. The minimal `p[1-4]` pattern failed again; the diagnostic now retains its concrete NSError and schema. The probe’s own process log explicitly reports “A generation guide with an unsupported pattern was used”. This identifies this request’s failure; the numeric underlying error alone is not a general diagnosis, and no claim is made about all OS/model versions.

Replacing only the pattern guide with the documented finite-choice `anyOf(["p1", "p2", "p3", "p4"])` succeeded and returned `p3`. Sources, literal results and a concise process-log extraction are retained under `runtime-diagnosis/`. No full system log or private app data is included. Neither control is a filter-quality score. The next candidate should use supported typed choices while preserving Boolean grouping, then pass the existing semantic and held-out checks before production adoption. No replacement has shipped; production code and the ready native Mac note-regression products remain unchanged.


## Typed token-sequence candidate: rejected

A materially different finite-choice token sequence compiles and runs the unchanged twelve semantic cases and three held-out paraphrases on the actual Mac model. All fifteen requests reach generation but violate the candidate's token contract: bare conditions/operators carry nonempty values. The compiler refuses every response. This is zero usable expressions, not a zero semantic score; no unsupported-pattern error occurs. Literal observations, candidate and complete compressed test logs are retained in `rejected-typed-sequence/`. Production is restored to its exact prior SHA256. Do not relax the contract by silently dropping values or retry the same schema unchanged. A future design needs a structural distinction between bare tokens and valued predicates, followed by the same strict semantic checks. No feature is accepted, installed or enabled from this experiment.


## Structural token enum: rejected

A separate bare-token/valued-predicate enum removes the prior impossible empty-value contract. It compiles and runs all twelve unchanged semantic cases plus the three held-out paraphrases. Generated queries now reach the ordinary parser and target/date validation, but all fifteen fail it (including invented multiword project values and invalid dates). The full candidate, literal observations and compressed stdout/stderr are retained in `rejected-structural-sequence/`. The engine is restored to its pre-experiment SHA256 before the separate local lower-bound feature is authored. No model feature ships or receives semantic acceptance. Do not retry this schema unchanged or weaken target/date validation. Further model work needs diagnostic evidence that improves this failure mode; local deterministic support is recorded separately and never counted as model inference.
