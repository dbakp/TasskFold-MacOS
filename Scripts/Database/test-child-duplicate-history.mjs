// Run the full owned repair/access acceptance corpus with this additive contract.
import {fileURLToPath} from 'node:url';
process.env.TASKFOLD_DUPLICATE_HISTORY_SQL=fileURLToPath(new URL('../../supabase/migrations/20261101071304_reviewed_duplicate_history_preservation.sql',import.meta.url));
await import('./test-child-repair-history-access.mjs');
