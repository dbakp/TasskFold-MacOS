import {readFile} from 'node:fs/promises';
import {loadProjectAdoptionSchema} from './project-adoption-schema.mjs';
import {teamTemplateLibraryMigration} from './team-template-library-schema.mjs';
export const workflowRunMigration='20261025092534_team_workflow_runs.sql';
export async function loadWorkflowRunSchema(execute,{taskTypes=process.env.TASKFOLD_TEST_WORKFLOW_TYPES==='1'}={}){
 await loadProjectAdoptionSchema(execute);
 // Inspected base fields omitted by the minimal task fixtures; no user rows.
 await execute(`alter table public.projects add column description text;
 create table public.view_orders(user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,id text not null,ids jsonb not null default '[]',updated_at timestamptz not null default now(),primary key(user_id,id));
 alter table public.view_orders enable row level security;
 create policy account_owner on public.view_orders to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
 grant select,insert,update,delete on public.view_orders to authenticated;
 create function taskfold_private.touch_organization()returns trigger language plpgsql set search_path='' as $$begin new.updated_at=now();return new;end$$;`);
 const foundation=await readFile(new URL('../../supabase/migrations/20261020174132_project_workflow_foundation.sql',import.meta.url),'utf8');
 await execute(foundation.slice(foundation.indexOf('create table public.project_templates')));
 for(const file of [teamTemplateLibraryMigration,workflowRunMigration])await execute(await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
 if(taskTypes)for(const file of ['20261024222451_team_task_repeat_edits.sql','20261026032336_task_headings_contract.sql','20261026155711_team_task_heading_commands.sql','20261026161001_team_task_heading_lifecycle.sql','20261026165807_shared_workflow_task_headings.sql'])await execute(await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
}
