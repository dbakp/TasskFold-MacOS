// npm ci --prefix Scripts/Database; npm run --prefix Scripts/Database test:task-dependencies
// In-memory PostgreSQL only. No URLs, credentials or app/user containers are read.
// Phase 1 applies the migration and runs the fixture. Phase 2 runs the same fixture WITHOUT the
// migration and requires it to fail, so the test cannot pass vacuously.
import { PGlite } from '@electric-sql/pglite';
import { readFile } from 'node:fs/promises';
const url = (name) => new URL(name, import.meta.url);
const bootstrap = url('./task-dependencies-bootstrap.sql');
const migration = url('../../supabase/migrations/20261114120000_task_dependencies_lite.sql');
const fixture = url('../../supabase/tests/task_dependencies.sql');
const run = async (db, files) => { for (const file of files) { await db.exec(await readFile(file, 'utf8')); console.log('PASS ' + file.pathname.split('/').at(-1)); } };
try {
  const db = new PGlite();
  try {
    await run(db, [bootstrap, migration, fixture]);
    if ((await db.query('select count(*)::int as n from auth.users')).rows[0].n !== 0) throw new Error('Fixture rollback failed');
    if ((await db.query('select count(*)::int as n from public.task_dependencies')).rows[0].n !== 0) throw new Error('Dependencies survived fixture rollback');
    console.log('PASS fixture rolled back');
  } finally { await db.close(); }
  const bare = new PGlite();
  try {
    await run(bare, [bootstrap]);
    let failed = false;
    try { await bare.exec(await readFile(fixture, 'utf8')); } catch (error) { failed = true; console.log('PASS fixture fails without the migration: ' + error.message.split('\n')[0]); }
    if (!failed) throw new Error('Fixture passed without the migration, so it proves nothing');
  } finally { await bare.close(); }
} catch (error) {
  console.error(error.message);
  if (error.where) console.error(error.where);
  process.exitCode = 1;
}
