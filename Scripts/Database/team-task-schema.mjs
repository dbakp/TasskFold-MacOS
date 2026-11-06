import { readFile } from "node:fs/promises";
import { loadTeamProjectSchema } from "./team-project-schema.mjs";
export const teamTaskLifecycleMigration =
  "20261024041605_team_task_lifecycle.sql";
export async function loadTeamTaskLifecycle(execute, { base = true } = {}) {
  if (base) {
    await loadTeamProjectSchema(execute);
    await execute(
      await readFile(
        new URL(
          "../../supabase/migrations/20261024040403_team_task_edits.sql",
          import.meta.url,
        ),
        "utf8",
      ),
    );
  }
  await execute(
    await readFile(
      new URL("./team-task-guard-snapshot.sql", import.meta.url),
      "utf8",
    ),
  );
  await execute(
    await readFile(
      new URL(
        "../../supabase/migrations/" + teamTaskLifecycleMigration,
        import.meta.url,
      ),
      "utf8",
    ),
  );
}
