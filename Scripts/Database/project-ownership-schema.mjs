import {readFile} from 'node:fs/promises';
import {loadTeamTaskMoveSchema} from './team-move-schema.mjs';
export const projectOwnershipMigration='20261025011154_team_project_ownership_fences.sql';
export async function loadProjectOwnershipSchema(execute,{base=true}={}) {
 if(base) {
  await loadTeamTaskMoveSchema(execute);
  await execute(await readFile(new URL('../../supabase/migrations/20261021122959_assignment_provenance.sql',import.meta.url),'utf8'));
  await execute(await readFile(new URL('./project-legacy-adoption-guards.sql',import.meta.url),'utf8'));
 }
 await execute(await readFile(new URL('../../supabase/migrations/'+projectOwnershipMigration,import.meta.url),'utf8'));
}
