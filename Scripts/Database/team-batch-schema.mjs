import { readFile } from "node:fs/promises";
import { loadTeamConversationSchema } from "./team-conversation-schema.mjs";
export const teamBatchMigration = "20261024045918_team_task_batches.sql";
export async function loadTeamBatchSchema(execute, { base = true } = {}) {
  if (base) await loadTeamConversationSchema(execute);
  await execute(
    await readFile(
      new URL(
        "../../supabase/migrations/" + teamBatchMigration,
        import.meta.url,
      ),
      "utf8",
    ),
  );
}
