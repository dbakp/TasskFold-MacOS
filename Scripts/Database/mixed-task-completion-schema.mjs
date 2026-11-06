import {readFile} from 'node:fs/promises';
import {loadChildAuthorityDependencies,childAuthorityMigration} from './child-task-authority-schema.mjs';
export const mixedTaskCompletionMigration='20261031040011_mixed_task_completion_transactions.sql';
export async function loadMixedTaskCompletionDependencies(pg) {
 await loadChildAuthorityDependencies(pg);
 for(const file of [childAuthorityMigration,'20261030093035_child_record_reviewed_team_transfers.sql','20261030102036_child_record_project_adoption_custody.sql','20261030104147_personal_child_record_task_moves.sql','20261030114138_cross_root_child_task_transfers.sql','20261030134132_reviewed_child_record_adoption.sql','20261030170753_child_adoption_metadata_discovery.sql','20261030183133_child_task_repair_previews.sql','20261030184402_child_task_repair_commits.sql','20261030192638_child_repair_original_history_access.sql','20261030204000_child_repair_bounded_originals.sql','20261031001141_child_task_completion_batches.sql','20261031031909_completion_selection_root_observations.sql'])await pg.raw(await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
}

// Fresh owned-fixture schema for exercising existing API suites after this upgrade.
export async function loadMixedTaskCompletionRegression(pg,report) {
 await loadMixedTaskCompletionDependencies(pg);
 report.baselineAdvisors=await pg.advisors();
 const sql=await readFile(new URL('../../supabase/migrations/'+mixedTaskCompletionMigration,import.meta.url),'utf8');
 await pg.raw(sql);
 const {createHash}=await import('node:crypto');
 report.mixedCompletionUpgradeSHA256=createHash('sha256').update(sql).digest('hex');
}
