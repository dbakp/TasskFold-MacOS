import {readFile} from 'node:fs/promises';
import {loadProjectOwnershipSchema} from './project-ownership-schema.mjs';
export const projectAdoptionMigration='20261025014040_team_project_adoption_review.sql';
export const projectAdoptionConnectionsMigration='20261025031915_team_project_adoption_connection_fences.sql';
export const projectAdoptionPolicyMigration='20261025033903_team_project_adoption_connection_policy.sql';
export async function loadProjectAdoptionSchema(execute,{base=true,connections=true,policy=true,nodes=process.env.TASKFOLD_TEST_NODE_ADOPTION==='1',historyCustody=process.env.TASKFOLD_TEST_HISTORY_CUSTODY==='1'}={}) {
 if(base) {
  await loadProjectOwnershipSchema(execute);
  const foundation=await readFile(new URL('../../supabase/migrations/20261020174132_project_workflow_foundation.sql',import.meta.url),'utf8');
  await execute(foundation.slice(foundation.indexOf('create function taskfold_private.guard_project_organization()'),foundation.indexOf('create table public.project_templates')));
  for(const file of ['20261024163752_team_project_presentation.sql','20261024172109_team_project_archiving.sql','20261024182336_team_project_hierarchy.sql','20261023150729_email_intake_journal.sql','20261023162006_email_domain_binding.sql','20261023050732_webhook_subscriptions.sql','20261023054251_webhook_outbox.sql'])
   await execute(await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
 }
 await execute(await readFile(new URL('../../supabase/migrations/'+projectAdoptionMigration,import.meta.url),'utf8'));
 if(policy && !connections) throw new Error('Connection policy requires its ownership fences');
 if(connections) await execute(await readFile(new URL('../../supabase/migrations/'+projectAdoptionConnectionsMigration,import.meta.url),'utf8'));
 if(policy) await execute(await readFile(new URL('../../supabase/migrations/'+projectAdoptionPolicyMigration,import.meta.url),'utf8'));
 if(historyCustody && !nodes) throw new Error("History custody requires the child history review");
 if(nodes) {
  if(!policy) throw new Error('Child history review requires the current connection policy');
  await execute('alter table public.tasks add column if not exists is_heading boolean');
  for(const file of ['20261026095807_task_node_activity_history.sql','20261026104450_task_activity_root_context.sql','20261026113556_task_node_activity_custody.sql','20261026121332_task_node_project_adoption_review.sql'])
   await execute(await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
 }
 if(historyCustody) await execute(await readFile(new URL('../../supabase/migrations/20261026122805_reviewed_history_custody.sql',import.meta.url),'utf8'));
}
