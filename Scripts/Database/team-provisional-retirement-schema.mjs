import {readFile} from 'node:fs/promises';
import {loadTeamCompletionRebaseSchema} from './team-completion-rebase-schema.mjs';
export const teamProvisionalRetirementMigration='20261024080409_team_provisional_generation_retirement.sql';
export async function loadTeamProvisionalRetirementSchema(execute,{base=true}={}) {
 if(base)await loadTeamCompletionRebaseSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamProvisionalRetirementMigration,import.meta.url),'utf8'));
}
