import {readFile} from 'node:fs/promises';
import {loadTeamProjectSchema} from './team-project-schema.mjs';
export const teamTemplateLibraryMigration='20261025064636_team_workflow_template_library.sql';
export async function loadTeamTemplateLibrarySchema(execute) {
 await loadTeamProjectSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/'+teamTemplateLibraryMigration,import.meta.url),'utf8'));
}
