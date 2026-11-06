import { readFile } from "node:fs/promises";
export const teamPlanningMigration =
  "20261024054229_team_task_planning_edits.sql";
export async function loadTeamPlanningSchema(execute) {
  await execute(
    await readFile(
      new URL(
        "../../supabase/migrations/" + teamPlanningMigration,
        import.meta.url,
      ),
      "utf8",
    ),
  );
}
