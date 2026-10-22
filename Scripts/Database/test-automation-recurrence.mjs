import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
const db = new PGlite({ extensions: { pgcrypto } });
try {
 await db.exec('create role anon; create role authenticated; create role service_role; create schema taskfold_private; create schema extensions; create extension pgcrypto with schema extensions');
 await db.exec(await readFile(new URL('../../supabase/migrations/20261022215836_automation_recurrence_plan.sql', import.meta.url), 'utf8'));
 const cases = JSON.parse(await readFile(new URL('../../TaskfoldTests/Fixtures/automation-recurrence.json', import.meta.url), 'utf8'));
 assert(cases.length >= 300);
 for (const test of cases) {
  const { rows } = await db.query('select taskfold_private.automation_recurrence_plan($1::jsonb,$2::timestamptz,$3::text) result', [JSON.stringify(test.task),test.completed_at,test.input_zone]);
  assert.deepEqual(rows[0].result,test.expected,test.name);
 }
 // These helpers are unusable by any client role, even the service role; a future
 // private operation can invoke them internally after same-transaction authorization.
 const { rows: functions } = await db.query(`select p.proname,p.prosecdef,p.proconfig,
  has_function_privilege('anon',p.oid,'EXECUTE') a,
  has_function_privilege('authenticated',p.oid,'EXECUTE') u,
  has_function_privilege('service_role',p.oid,'EXECUTE') s
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='taskfold_private'`);
 assert.equal(functions.length,7);
 for (const f of functions) {
  assert.equal(f.prosecdef,false,f.proname);
  assert.deepEqual(f.proconfig,['search_path=""'],f.proname);
  assert.equal(f.a||f.u||f.s,false,f.proname);
 }
 for (const [stamp,zone] of [[null,'UTC'],['infinity','UTC'],['2026-01-31T12:00:00Z',null],['2026-01-31T12:00:00Z','Mars/Nope']]) {
  await assert.rejects(db.query('select taskfold_private.automation_recurrence_plan($1::jsonb,$2::timestamptz,$3::text)',[JSON.stringify(cases[0].task),stamp,zone]), e=>e.code==='22023');
 }
 // Transaction clock, server TimeZone and repeat calls cannot alter explicit clocks.
 await db.exec("set time zone 'Pacific/Auckland'");
 for (const test of cases.filter(c=>/zone|floating|dst/.test(c.name))) {
  const {rows}=await db.query('select taskfold_private.automation_recurrence_plan($1::jsonb,$2::timestamptz,$3::text) result',[JSON.stringify(test.task),test.completed_at,test.input_zone]);
  assert.deepEqual(rows[0].result,test.expected,test.name+' server-zone independence');
 }
 console.log(`PASS ${cases.length} native-shared recurrence plans; private privileges, invalid clocks, explicit-zone repeat checks. No task writes, hosted deployment or Simulator acceptance.`);
} catch(error) { console.error(error.message); if(error.actual!==undefined)console.error({actual:error.actual,expected:error.expected}); if(error.where)console.error(error.where);process.exitCode=1; }
finally {await db.close();}
