import {readFile} from 'node:fs/promises';
import {loadProjectAdoptionSchema} from './project-adoption-schema.mjs';
export const teamPlanningBatchMigration='20261025044350_team_task_planning_batches.sql';
export async function loadTeamPlanningBatchSchema(execute,{base=true}={}) {
 if(base)await loadProjectAdoptionSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamPlanningBatchMigration,import.meta.url),'utf8'));
}
