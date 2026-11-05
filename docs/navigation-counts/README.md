# Reuse navigation badge counts

Project rows previously rescanned the productive task library individually to draw their counts. On Mac, the All tasks badge and each label row also repeated full scans. Both clients now reuse an immutable aggregate owned by their existing task cache. Project lookup and label lookup use prepared dictionaries; revisiting unchanged data does not recount it.

The aggregate is computed in one workload pass plus the label aliases actually present. ID-based and legacy label-name references retain exact existing matching, including duplicate names and collisions between a label ID and another name. A task tagged by both forms still counts once for a given label. Ordinary checklists remain part of their parent task; heading descendants and legacy readable work retain the existing workload interpretation. Archived project exclusions and incomplete/lower-bound markers are unchanged. The iPhone project section skips aggregation entirely when no projects are visible.

Task changes invalidate the aggregate, while label catalog changes and archive scope changes are checked independently. Completion, Undo, moves, empty/account-replaced sources and cold-decoded source rows have explicit tests. Only counts leave the aggregate; it supplies no editing authority and persists no new data.

Six new focused tests per owning repository compare the results with the previous literal badge expressions, including a 4,096-task/128-project/64-label fixture. One hundred retained lookup rounds reuse a single aggregate. The separate heading workload regression suite is also included. These are deterministic Core checks running on this Mac; they do not establish physical device frame rate, rendering latency or full native acceptance.

This follow-up is newer than installed iPhone 1.4.0 (34) and Mac 1.2.0 (14). Their running sessions, drafts and saved data are unchanged. Current build/signature results are recorded separately; native and physical smoothness checks remain open.
