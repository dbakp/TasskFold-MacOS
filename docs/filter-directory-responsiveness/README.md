# Filter directory responsiveness

The ordinary saved-filter editor now requests project member lists only when a person condition needs them. Dates, priorities and quoted keyword searches do not warm the directory. Named references continue to request a complete directory even when the first matching member is the current user; this preserves ambiguity checks.

Each Store shares simultaneous reads for the same project and account, session, provider and access generation. One reader cancelling leaves other readers active; the last reader cancels the operation. No finished result is cached by the coordinator, so a later refresh still contacts the existing service. Account changes invalidate pending operations and late results cannot overwrite a replacement read. The production RPC and its expected-account check are unchanged. One shared response is decoded and persisted once.

Verification: each repository independently passes 109 selected Core tests (108 passed, one real-model probe skipped), including six focused directory-demand, sharing, failure, cancellation and account/session/access/provider/project isolation checks. The first test fixture crashed because its continuation queue was not actor isolated; isolating that fixture fixed the race. The first native compile also caught a missing throwing-origin access; that was corrected before the successful builds recorded separately.

Native control behavior, live directory delivery and measured physical scrolling remain unaccepted. This source change is not part of installed iPhone 1.4.0 (34) or Mac 1.2.0 (14). Their saved data and running sessions are unchanged by these checks.
