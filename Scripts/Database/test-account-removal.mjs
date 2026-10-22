import { PGlite } from '@electric-sql/pglite';
import { readFile } from 'node:fs/promises';
const db = new PGlite();
try {
 for (const name of ['./account-removal-bootstrap.sql','../../supabase/migrations/20261022193804_account_removal_service.sql','../../supabase/tests/account_removal.sql']) {
  await db.exec(await readFile(new URL(name,import.meta.url),'utf8'));
  console.log('PASS '+name.split('/').at(-1));
 }
 if ((await db.query('select count(*)::int n from auth.users')).rows[0].n!==0) throw new Error('Fixture users survived rollback');
 if ((await db.query('select count(*)::int n from taskfold_private.account_removal_receipts')).rows[0].n!==0) throw new Error('Receipts survived rollback');
 console.log('PASS independent local SQL/role/cascade/rollback checks; hosted and HTTP acceptance remain separate');
} catch(error) { console.error(error.message); if(error.where)console.error(error.where);process.exitCode=1; }
finally {await db.close();}
