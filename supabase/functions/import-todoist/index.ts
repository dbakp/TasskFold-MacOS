import { createHandler } from "./handler.ts";
Deno.serve(
  createHandler({
    url: Deno.env.get("SUPABASE_URL") ?? "",
    key: Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    headingsEnabled:
      Deno.env.get("TASKFOLD_TODOIST_HEADINGS_ENABLED") === "true",
  }),
);
