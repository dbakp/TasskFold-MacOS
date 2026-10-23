import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { PGlite } from '@electric-sql/pglite';
import { readFile } from 'node:fs/promises';
const db = new PGlite({ extensions: { pgcrypto } });
try {
 await db.exec('create schema extensions; create extension pgcrypto with schema extensions');
 for (const name of ['./account-removal-bootstrap.sql','../../supabase/migrations/20261022193804_account_removal_service.sql','../../supabase/migrations/20261022212224_automation_access.sql','../../supabase/migrations/20261022215836_automation_recurrence_plan.sql','../../supabase/migrations/20261023002825_automation_enrollment_cancellation.sql','../../supabase/tests/automation_access.sql']) {
  await db.exec(await readFile(new URL(name,import.meta.url),'utf8'));
  console.log('PASS '+name.split('/').at(-1));
 }
 for (const table of ['auth.users','auth.sessions','taskfold_private.automation_keys','taskfold_private.automation_account_usage','taskfold_private.automation_key_cancellations']) {
  if ((await db.query('select count(*)::int n from '+table)).rows[0].n!==0) throw new Error('Fixture survived rollback: '+table);
 }
 console.log('PASS owned local credential/session/scope/quota/revocation/rollback checks; no hosted deployment or task API acceptance');
} catch(error) {console.error(error.message);if(error.where)console.error(error.where);process.exitCode=1;}
finally {await db.close();}
