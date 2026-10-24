import { readFile } from 'node:fs/promises';
import { loadTeamCompletionSchema } from './team-completion-schema.mjs';
export const teamCompletionReviewMigration='20261024071232_team_completion_review.sql';
export async function loadTeamCompletionReviewSchema(execute,{base=true}={}) {
 if(base) await loadTeamCompletionSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamCompletionReviewMigration,import.meta.url),'utf8'));
}
