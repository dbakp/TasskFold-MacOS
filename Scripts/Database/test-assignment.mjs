// npm ci --prefix Scripts/Database; npm run --prefix Scripts/Database test:assignment
// In-memory PostgreSQL only. No URLs, credentials or app/user containers are read.
import { PGlite } from '@electric-sql/pglite';
import { readFile } from 'node:fs/promises';
const db = new PGlite();
try {
  const files = [new URL('./assignment-bootstrap.sql', import.meta.url),
    new URL('../../supabase/migrations/20261021122959_assignment_provenance.sql', import.meta.url),
    new URL('../../supabase/tests/assignment_provenance.sql', import.meta.url)];
  for (const file of files) {
    const results = await db.exec(await readFile(file, 'utf8'));
    console.log('PASS ' + file.pathname.split('/').at(-1));
    for (const result of results) for (const row of result.rows ?? []) {
      if (row.jsonb_build_object) console.log(JSON.stringify(row.jsonb_build_object));
    }
  }
  if ((await db.query("select count(*)::int as n from auth.users")).rows[0].n !== 0) throw new Error('Fixture rollback failed');
  console.log('PASS fixture rolled back; local runtime is not hosted-policy or HTTP acceptance');
} catch (error) {
  console.error(error.message);
  if (error.where) console.error(error.where);
  process.exitCode = 1;
} finally { await db.close(); }
