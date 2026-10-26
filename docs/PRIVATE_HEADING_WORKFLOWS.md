# Private heading workflows in shared workspaces

The earlier heading-workflow implementation supported the plan/command/service
but the private template screen still hid its shared-workspace entry whenever
the definition used headings. Both clients now expose that route for understood
v2 definitions with client support. This follows the ordinary destination,
contents, audience and durable request/recovery flow; opening or backing out of
the review does not create work or modify the saved template.

Client support and current workspace permission remain separate. A known heading
definition in an app without creation support has a disabled shared-create
button and an explicit explanation in both the private template and team library.
Private copy/export controls stay available. A workspace whose fresh signed
boundary lacks typed authoring/lifecycle support produces a clear, bounded
message before any workflow request is sent. Other preparation errors retain
the existing general message, rather than exposing raw backend errors.

The private workflow preview now explicitly distinguishes its unavailable local
creation path from the separately available shared-workspace path. Source,
destination, actor/session, order and capability rechecks, complete v2 transport,
strict typed acknowledgments and original retry identities remain as implemented
in `SHARED_WORKFLOW_HEADINGS.md`.

Verification records and exact source/isolated variants are in
`private-heading-workflows/`. All work uses the reserved signed debug host and
synthetic URLProtocol peer. These UI checks do not replace the previous real
isolated PostgreSQL checks or imply hosted/cross-device delivery acceptance.
No normal app feature flag, hosted configuration or user-deferred rollout,
provider, notification, safe-upgrade or distribution setting changed.


Verification: 82 focused Core checks pass per independently owned repo. Five
installed scenarios pass on each Mac, iPhone and iPad, covering workspace support
refusal without writes, Back/cold source preservation, personal v2 shared-run
lost-reply/relaunch/exact retry, ordinary v1 reuse, and actual Info-disabled creation
with a complete typed private-copy save. Seven retained output images were visually
inspected. Initial selector/scrolling failures remain alongside final passing logs.
Native checks use only the local synthetic peer and do not claim hosted delivery.


Cleanup: the isolated test apps and runners are uninstalled from both Simulators;
all Taskfold app processes are closed. Owned temporary hosts/builds/results were
pruned after retaining the verification record. Repo build caches were preserved.
