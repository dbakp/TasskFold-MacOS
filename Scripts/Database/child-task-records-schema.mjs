// Private, opt-in projection only; not a client adoption/independent-write API.
import { readFile } from "node:fs/promises";
export const childTaskRecordsMigration =
  "20261028235056_independent_child_record_projection.sql";
export async function loadChildTaskRecordsSchema(execute) {
  await execute(
    await readFile(
      new URL(
        "../../supabase/migrations/" + childTaskRecordsMigration,
        import.meta.url,
      ),
      "utf8",
    ),
  );
}
