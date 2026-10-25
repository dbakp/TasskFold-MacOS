import {readFile} from 'node:fs/promises';
import {loadTeamPlanningBatchSchema} from './team-planning-batch-schema.mjs';
export const teamAssignmentBatchMigration='20261025060438_team_task_assignment_batches.sql';
export async function loadTeamAssignmentBatchSchema(execute) {
 await loadTeamPlanningBatchSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamAssignmentBatchMigration,import.meta.url),'utf8'));
}
