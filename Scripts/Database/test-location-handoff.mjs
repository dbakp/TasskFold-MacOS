// Owned, pinned, in-memory PostgreSQL. No app config, network or credentials read.
import { PGlite } from '@electric-sql/pglite';
import { readFile,writeFile } from 'node:fs/promises';
const db = new PGlite();
try {
  for (const name of ['./location-handoff-bootstrap.sql','../../supabase/migrations/20261022145128_private_location_handoffs.sql','../../supabase/tests/private_location_handoffs.sql']) {
    const results = await db.exec(await readFile(new URL(name,import.meta.url),'utf8'));
    console.log('PASS '+name.split('/').at(-1));
    for (const result of results) for (const row of result.rows ?? []) {
      if(row.jsonb_build_object) console.log(JSON.stringify(row.jsonb_build_object));
      if(row.handoff_golden && process.argv.includes('--write-golden')) {
        if(!['pending','claimed','other-device','imported'].includes(row.handoff_golden_name)) throw new Error('Unexpected fixture name');
        await writeFile(new URL('../../TaskfoldTests/Fixtures/location-handoff-'+row.handoff_golden_name+'.json',import.meta.url),JSON.stringify(row.handoff_golden,null,2)+'\n');
      }
    }
  }
  if((await db.query('select count(*)::int as n from auth.users')).rows[0].n!==0) throw new Error('Fixture rollback failed');
  if((await db.query('select count(*)::int as n from taskfold_private.location_handoffs')).rows[0].n!==0) throw new Error('Private drafts survived fixture rollback');
  console.log('PASS rollback verified; this minimal bootstrap is not hosted-policy/HTTP acceptance');
} catch(error) { console.error(error.message);if(error.where) console.error(error.where);process.exitCode=1; }
finally { await db.close(); }
