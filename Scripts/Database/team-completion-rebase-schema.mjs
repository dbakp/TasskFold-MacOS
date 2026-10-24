import {readFile} from 'node:fs/promises';
import {loadTeamCompletionCancellationSchema} from './team-completion-cancellation-schema.mjs';
export const teamCompletionRebaseMigration='20261024074022_team_completion_rebase_capabilities.sql';
export async function loadTeamCompletionRebaseSchema(execute,{base=true}={}) {
 if(base)await loadTeamCompletionCancellationSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamCompletionRebaseMigration,import.meta.url),'utf8'));
}
