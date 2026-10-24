import { readFile } from "node:fs/promises";
import { loadTeamTaskLifecycle } from "./team-task-schema.mjs";
export const teamConversationMigration =
  "20261024043412_team_conversation_recovery.sql";
export async function loadTeamConversationSchema(
  execute,
  { base = true } = {},
) {
  if (base) await loadTeamTaskLifecycle(execute);
  await execute(
    await readFile(
      new URL(
        "../../supabase/migrations/" + teamConversationMigration,
        import.meta.url,
      ),
      "utf8",
    ),
  );
}
