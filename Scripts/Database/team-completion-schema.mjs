import { readFile } from "node:fs/promises";
import { loadTeamBatchSchema } from "./team-batch-schema.mjs";
import { loadTeamPlanningSchema } from "./team-planning-schema.mjs";
import { loadTeamChecklistSchema } from "./team-checklist-schema.mjs";
export const teamCompletionMigration =
  "20261024063514_team_recurring_completion.sql";
export async function loadTeamCompletionSchema(execute, { base = true } = {}) {
  if (base) {
    await loadTeamBatchSchema(execute);
    await loadTeamPlanningSchema(execute);
    await loadTeamChecklistSchema(execute);
  }
  await execute(
    await readFile(
      new URL(
        "../../supabase/migrations/" + teamCompletionMigration,
        import.meta.url,
      ),
      "utf8",
    ),
  );
}
