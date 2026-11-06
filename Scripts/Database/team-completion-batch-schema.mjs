import { readFile } from 'node:fs/promises';
import { loadTeamProvisionalRetirementSchema } from './team-provisional-retirement-schema.mjs';
export const teamCompletionBatchMigration = '20261025123326_team_completion_batches.sql';
export async function loadTeamCompletionBatchSchema(execute, { base = true } = {}) {
 if (base) await loadTeamProvisionalRetirementSchema(execute);
 await execute(await readFile(new URL('../../supabase/migrations/' + teamCompletionBatchMigration, import.meta.url), 'utf8'));
}
