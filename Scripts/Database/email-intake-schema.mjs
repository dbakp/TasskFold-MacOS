import { readFile } from "node:fs/promises";
import { loadAutomationPostgresSchema } from "./automation-postgres-schema.mjs";
export const emailMigration = "20261023150729_email_intake_journal.sql";
export async function loadEmailIntakeSchema(execute) {
  await loadAutomationPostgresSchema(execute);
  // Fixture Auth tables deliberately model only inspected prerequisites.
  await execute(
    "alter table auth.users add column email_confirmed_at timestamptz",
  );
  await execute(
    await readFile(
      new URL("../../supabase/migrations/" + emailMigration, import.meta.url),
      "utf8",
    ),
  );
}
