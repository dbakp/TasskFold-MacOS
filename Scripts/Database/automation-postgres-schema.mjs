// The same owned minimal dependency schema used by the mutation suite. Actual
// guarded native/candidate routines load unchanged; full hosted triggers differ.
import { readFile } from "node:fs/promises";
const source = (path) => readFile(new URL(path, import.meta.url), "utf8");
export async function loadAutomationPostgresSchema(execute) {
  const load = async (path) => execute(await source(path));
  await execute(
    "create schema extensions;create extension pgcrypto with schema extensions",
  );
  await load("./account-removal-bootstrap.sql");
  await load(
    "../../supabase/migrations/20261022193804_account_removal_service.sql",
  );
  await load("./automation-task-bootstrap.sql");
  await execute(
    "alter table public.projects add column is_archived boolean not null default false,add column ancestor_archived boolean not null default false,add column color text,add column order_index integer,add column parent_id uuid;create table public.sections(id uuid primary key,project_id uuid references public.projects(id) on delete cascade,name text,order_index integer)",
  );
  for (
    const [file, boundary] of [
      [
        "20261006124947_task_generations_and_reminder_eligibility.sql",
        "-- The read-only remote activation epoch",
      ],
      ["20261006031648_completion_revision.sql", null],
      ["20261020194217_subtask_structure_review.sql", null],
      ["20261007101832_automatic_reminder_preferences.sql", "-- Row locking"],
    ]
  ) {
    const text = await source("../../supabase/migrations/" + file);
    if (boundary && text.indexOf(boundary) < 0) {
      throw new Error("Native fixture boundary changed");
    }
    await execute(boundary ? text.slice(0, text.indexOf(boundary)) : text);
  }
  await execute(
    "create table public.reminder_preferences(user_id uuid references auth.users(id) on delete cascade,id text default 'current',settings jsonb not null check(taskfold_private.valid_reminder_preferences(settings)),updated_at timestamptz default now(),primary key(user_id,id))",
  );
  for (
    const file of [
      "20261022212224_automation_access.sql",
      "20261022215836_automation_recurrence_plan.sql",
      "20261022220821_automation_task_access.sql",
      "20261022222726_automation_task_writes.sql",
      "20261022225439_automation_task_mutations.sql",
      "20261023002825_automation_enrollment_cancellation.sql",
      "20261023010559_automation_destinations.sql",
      "20261023011251_automation_portable_reminders.sql",
      "20261023012417_automation_ingress_limits.sql",
      "20261023031416_automation_management_deadlines.sql",
    ]
  ) await load("../../supabase/migrations/" + file);
  await execute(
    "create trigger taskfold_normalize_planned_instant before insert or update on public.tasks for each row execute function taskfold_private.normalize_planned_instant();create trigger taskfold_timestamp before update on public.tasks for each row execute function public.update_completed_at()",
  );
}
