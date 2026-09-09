# Working on Taskfold for macOS

- After implementing requested changes, run appropriate checks, commit the changes, and push them to this repository. The user explicitly wants all completed changes pushed, including follow-up fixes.
- Preserve unrelated local work, particularly in the sibling iOS checkout. Set `TASKFOLD_IOS_ROOT` to a clean checkout when building against shared sources.
- Keep the implementation status and verification notes in `docs/PREMIUM_MAC_PLAN.md` current while working through the polish milestones.
- Use isolated debug fixtures for UI tests; do not modify real task data for testing.
