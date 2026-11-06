import {readFile} from 'node:fs/promises';
import {loadTeamWorkspaceSchema} from './team-workspace-schema.mjs';
export const teamTaskMoveMigration='20261025000653_team_task_moves.sql';
export async function loadTeamTaskMoveSchema(execute,{base=true}={}) {
 if(base)await loadTeamWorkspaceSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamTaskMoveMigration,import.meta.url),'utf8'));
}
