import { createAudioCommentsHandler } from "./handler.ts";
// Platform JWT verification stays enabled. Live Auth and SQL session checks are
// independent; do not deploy/enable before provider and native acceptance.
Deno.serve(createAudioCommentsHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  enabled: Deno.env.get("TASKFOLD_AUDIO_COMMENTS_ENABLED") === "true",
}));
