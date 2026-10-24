import {readFile} from 'node:fs/promises';
import {loadTeamCompletionReviewSchema} from './team-completion-review-schema.mjs';
export const teamCompletionCancellationMigration='20261024072504_team_completion_cancellation.sql';
export async function loadTeamCompletionCancellationSchema(execute,{base=true}={}) {
 if(base)await loadTeamCompletionReviewSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamCompletionCancellationMigration,import.meta.url),'utf8'));
}
