import {readFile} from 'node:fs/promises';
import {loadTeamProvisionalRetirementSchema} from './team-provisional-retirement-schema.mjs';
export const teamDraftCopyMigration='20261024090623_team_saved_draft_copy.sql';
export async function loadTeamDraftCopySchema(execute,{base=true}={}) {
 if(base)await loadTeamProvisionalRetirementSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamDraftCopyMigration,import.meta.url),'utf8'));
}
