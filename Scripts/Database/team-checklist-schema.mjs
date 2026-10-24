import { readFile } from "node:fs/promises";
export const teamChecklistMigration = "20261024055617_team_checklist_edits.sql";
export async function loadTeamChecklistSchema(execute) {
  await execute(
    await readFile(
      new URL(
        "../../supabase/migrations/" + teamChecklistMigration,
        import.meta.url,
      ),
      "utf8",
    ),
  );
}
