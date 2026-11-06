import {readFile} from 'node:fs/promises';
import {loadTeamAssignmentBatchSchema} from './team-assignment-batch-schema.mjs';
export const teamLabelBatchMigration='20261025111218_team_task_label_batches.sql';
export async function loadTeamLabelBatchSchema(execute) {
 await loadTeamAssignmentBatchSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamLabelBatchMigration,import.meta.url),'utf8'));
}
