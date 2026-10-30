import {readFile} from 'node:fs/promises';
import {loadWorkflowRunSchema} from './team-workflow-run-schema.mjs';
import {loadChildTaskRecordsSchema} from './child-task-records-schema.mjs';
export async function loadChildAuthorityDependencies(pg) {
 process.env.TASKFOLD_TEST_NODE_ADOPTION='0';process.env.TASKFOLD_TEST_HISTORY_CUSTODY='0';
 await loadWorkflowRunSchema(pg.raw,{taskTypes:true});
 for(const file of ['20261026095807_task_node_activity_history.sql','20261026104450_task_activity_root_context.sql','20261026113556_task_node_activity_custody.sql','20261026121332_task_node_project_adoption_review.sql','20261026122805_reviewed_history_custody.sql'])await pg.raw(await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
 await loadChildTaskRecordsSchema(pg.raw);
 for(const file of ['20261029001127_child_task_record_reads.sql','20261029005723_child_task_field_edits.sql','20261029194600_child_task_field_resolution.sql','20261029211038_child_task_completion_commands.sql','20261029215232_child_task_completion_resolution.sql','20261030002245_child_structure_revision_and_assignment_bridge.sql'])await pg.raw(await readFile(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
 await pg.raw(await readFile(new URL('../../supabase/migrations/20261030004452_independent_child_structure_commands.sql',import.meta.url),'utf8'));
 await pg.raw(await readFile(new URL('../../supabase/migrations/20261030012858_native_team_child_field_adapter.sql',import.meta.url),'utf8'));
}
export const childAuthorityMigration='20261030090934_child_task_record_authority.sql';
