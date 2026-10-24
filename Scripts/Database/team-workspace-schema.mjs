import {readFile} from 'node:fs/promises';
import {loadTeamDraftCopySchema} from './team-draft-copy-schema.mjs';
export const teamWorkspaceMigration='20261024094010_team_workspace_boundary.sql';
export async function loadTeamWorkspaceSchema(execute,{base=true}={}) {
 if(base)await loadTeamDraftCopySchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamWorkspaceMigration,import.meta.url),'utf8'));
}
