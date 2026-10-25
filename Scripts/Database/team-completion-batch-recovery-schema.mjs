import {readFile} from 'node:fs/promises';
import {loadTeamCompletionBatchSchema} from './team-completion-batch-schema.mjs';
export const teamCompletionBatchRecoveryMigration='20261025140005_team_completion_batch_recovery.sql';
export async function loadTeamCompletionBatchRecoverySchema(execute,{base=true}={}) {
 if(base)await loadTeamCompletionBatchSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamCompletionBatchRecoveryMigration,import.meta.url),'utf8'));
}
