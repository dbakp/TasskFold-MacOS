// Owned minimal inspected dependencies plus unchanged real migrations.
// No hosted/HTTP/native acceptance is implied by this local fixture.
import { readFile } from "node:fs/promises";
import { loadAutomationPostgresSchema } from "./automation-postgres-schema.mjs";
export const teamProjectMigration = "20261024025423_team_project_access.sql";
export async function loadTeamProjectSchema(execute) {
  await loadAutomationPostgresSchema(execute);
  await execute(
    `create table storage.buckets(id text primary key,public boolean not null);insert into storage.buckets values('avatars',true),('task-attachments',false);
 alter table auth.users add column email_confirmed_at timestamptz,add column raw_user_meta_data jsonb not null default '{}',add column raw_app_meta_data jsonb not null default '{}';
 create table auth.identities(user_id uuid references auth.users(id) on delete cascade,provider text,identity_data jsonb,created_at timestamptz default now());
 alter table public.profiles add column display_name text,add column avatar_url text;
 create function auth.jwt() returns jsonb language sql stable set search_path='' as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 alter table public.sections add column user_id uuid references auth.users(id) on delete cascade;
 drop function public.is_project_owner(uuid,uuid);
 create function public.is_project_owner(_user_id uuid,_project_id uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.projects where id=_project_id and user_id=_user_id)$$;
 alter table public.projects enable row level security;alter table public.sections enable row level security;alter table public.project_collaborators enable row level security;
 grant select,insert,update,delete on public.sections to authenticated;
 create policy fixture_project_access on public.projects to authenticated using(user_id=auth.uid() or public.has_project_access(auth.uid(),id)) with check(user_id=auth.uid() or public.has_project_access(auth.uid(),id));
 create policy fixture_section_access on public.sections to authenticated using(public.has_project_access(auth.uid(),project_id)) with check(public.has_project_access(auth.uid(),project_id));
 create policy fixture_collaborator_read on public.project_collaborators for select to authenticated using(user_id=auth.uid() or public.is_project_owner(auth.uid(),project_id));`,
  );
  for (
    const file of [
      "20261006100647_task_activity_history.sql",
      "20261006100920_task_activity_cascade_authorization.sql",
      "20261021020423_shared_comments_and_mentions.sql",
      "20261024021629_team_organization.sql",
      "20261024022352_team_content_custody.sql",
      teamProjectMigration,
    ]
  ) {
    await execute(
      await readFile(
        new URL("../../supabase/migrations/" + file, import.meta.url),
        "utf8",
      ),
    );
  }
}
