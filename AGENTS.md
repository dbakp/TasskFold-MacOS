# Working on Taskfold for macOS

- After implementing requested changes, run appropriate checks, commit the changes, and push them to this repository. The user explicitly wants all completed changes pushed, including follow-up fixes.
- This repository owns its Mac code, resources, tests and release scripts. Do not add build dependencies on the iOS repository. Preserve unrelated work in other checkouts; implement and test relevant data-contract fixes in each app repository independently.
- Keep the implementation status and verification notes in `docs/PREMIUM_MAC_PLAN.md` current while working through the polish milestones.
- Use isolated debug fixtures for UI tests; do not modify real task data for testing.
