# Hierarchy Undo and Redo

Adding, moving (including indenting/outdenting) and removing a subtask branch now have a linked Undo/Redo history. Saved hierarchy actions offer Review Redo after a confirmed Undo. Confirming an inverse there advances the current native history entry without submitting the change twice. Native history uses a fresh request for every new inverse and keeps a retry tied to its original request.

Redo uses the existing typed structure protocol and exact confirmed structure revision. Repeating an insertion restores only the authored addition. Moving a branch preserves its current fields. Repeating removal requires the restored branch's fresh identities and revision-one records; a later field edit, including an edit away and back, prevents removal. A race after review is checked again by the existing database transaction. No new server migration, permission grant or production feature gate is introduced here.

The encrypted journal reads existing v1 records and writes logical v2 when Redo links are present. Its physical path, key and encryption context remain stable. Linked histories stay together during retention; a previous Undo cannot cause the archive owned by a newer removal to be pruned. Competing windows reuse the same queued inverse.

The ordinary editor/inspector now owns the organizer presentation outside reusable Form rows. Each opening captures its root identity. This prevents a nested Add review from disappearing when its row presenter is replaced. Temporary lifecycle diagnostics used to locate that failure are removed from app code.

## Verification scope

See verification.json and the captured receipts in this folder. Client tests exercise command binding, later-edit refusal, encrypted cold recovery, competing writers, retention and saved/native history handoff. The independently run PostgreSQL fixture uses the current authority SQL for personal owners and team editors. Native results use reserved isolated accounts and a synthetic HTTP peer, not hosted shared-account acceptance.

## Remaining migration work

Ordinary migration use remains disabled. Shared activity/history, older-data mapping, shared file/discussion custody, hosted deployment and genuine shared-account acceptance remain open. Mac keyboard acceptance must be reported separately from successful builds and client tests. The user's rollout deferrals remain unchanged.
