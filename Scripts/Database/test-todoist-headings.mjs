import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamCompletionSchema } from "./team-completion-schema.mjs";
const report = { checks: {}, deployed: false, realDataChanged: false };
const check = (name, actual, expected = true) => {
  assert.deepEqual(actual, expected, name);
  report.checks[name] = true;
};
const owner = "f3010000-0000-4000-8000-000000000001",
  other = "f3010000-0000-4000-8000-000000000002",
  session = randomUUID();
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
let pg, folder;
try {
  folder = await mkdtemp(join(tmpdir(), "taskfold-heading-import-fixture-"));
  const generated = join(folder, "prepared.json");
  await promisify(execFile)("deno", [
    "run",
    "--allow-write=" + generated,
    new URL("./todoist-heading-fixture.ts", import.meta.url).pathname,
    generated,
  ]);
  const prepared = JSON.parse(await readFile(generated, "utf8")),
    bundle = prepared.bundle;
  check("actual provider mapper generates version two", bundle.version, 2);
  pg = await createPostgresFixture({ advisors: true });
  await loadTeamCompletionSchema(pg.raw);
  await pg.raw(
    `alter table public.projects add column if not exists description text,add column if not exists source_metadata jsonb default '{}';create table if not exists public.labels(id uuid primary key,user_id uuid not null,name text,color text);alter table public.labels enable row level security;create policy fixture_import_labels_owner on public.labels for all to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));grant select,insert,update,delete on public.labels to authenticated;`,
  );
  await pg.raw(
    await readFile(
      new URL(
        "../../supabase/migrations/20261026032336_task_headings_contract.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const files = await readdir(
    new URL("../../supabase/migrations/", import.meta.url),
  );
  const migration = files.find((x) =>
    x.endsWith("_todoist_heading_import.sql")
  );
  assert(migration);
  const sql = await readFile(
    new URL("../../supabase/migrations/" + migration, import.meta.url),
    "utf8",
  );
  report.migration = migration;
  report.migrationSHA256 = createHash("sha256").update(sql).digest("hex");
  await pg.raw(sql);
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at) values(${
      lit(owner)
    },'heading-import-owner@example.invalid',now()),(${
      lit(other)
    },'heading-import-other@example.invalid',now());insert into auth.sessions(id,user_id) values(${
      lit(session)
    },${lit(owner)})`,
  );
  const statement = (command, actor = owner) =>
    pg.scalar(
      `begin;create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated;set local role authenticated;set local request.jwt.claim.sub=${
        lit(actor)
      };set local request.jwt.claims=${
        lit(JSON.stringify({ sub: actor, session_id: session }))
      };do $q$begin begin ${command};exception when others then insert into result values(null,sqlstate,left(sqlerrm,180));end;end$q$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`,
    );
  const run = (b, actor = owner) =>
    statement(
      `insert into result values(public.taskfold_import_todoist('synthetic-todoist-source',${
        json(b)
      }),null,null)`,
      actor,
    );
  const ok = (name, r) => {
    check(name, r.code, null);
    return r.value;
  };
  const count = () =>
    pg.scalar(
      "select jsonb_build_array((select count(*) from public.projects),(select count(*) from public.tasks),(select count(*) from public.import_sources))",
    );
  const before = await count();
  const unversioned = structuredClone(bundle);
  delete unversioned.version;
  delete unversioned.capabilities;
  check(
    "unversioned root and child headings refuse",
    (await run(unversioned)).code,
    "P0001",
  );
  check(
    "refusal is atomic before any project or mapping",
    await count(),
    before,
  );
  const receipt = ok(
    "real mapper bundle imports through authenticated invoker RPC",
    await run(bundle),
  );
  check("typed receipt confirms capability", [
    receipt.formatVersion,
    receipt.capabilities,
  ], [2, ["task_headings"]]);
  check(
    "nested count includes both preserved child nodes",
    receipt.subtasksImported,
    2,
  );
  const id = bundle.tasks[0].record.id;
  const stored = () =>
    pg.scalar(
      `select coalesce((select to_jsonb(t) from public.tasks t where id=${
        lit(id)
      }),'null'::jsonb)`,
    );
  const saved = await stored();
  check("stored root is open heading", [
    saved.is_heading,
    saved.completed,
    saved.completed_at,
  ], [true, false, null]);
  check("title notes and planning survive", [
    saved.title,
    saved.description,
    saved.due_date,
  ], ["Reference instructions", "Full instructions", "2026-11-01"]);
  check("nested heading and actionable descendant survive", [
    saved.subtasks[0].is_heading,
    saved.subtasks[0].subtasks[0].title,
  ], [true, "Do the work"]);
  check("comments files and original title survive", [
    saved.comments[0].text,
    saved.attachments[0].name,
    saved.source_metadata.original.content,
  ], ["Supporting notes", "reference.pdf", "* Reference instructions"]);
  ok(
    "owner can edit imported heading metadata",
    await statement(
      `with changed as (update public.tasks set description='My later Taskfold edit' where id=${
        lit(id)
      } returning *) insert into result select to_jsonb(changed),null,null from changed`,
    ),
  );
  const edited = await stored(),
    retry = ok("replay skips existing source identity", await run(bundle));
  check(
    "replay does not flatten or overwrite edited heading",
    await stored(),
    edited,
  );
  check("replay reports skip", retry.tasksSkipped, 1);
  check(
    "other account cannot read owner source mapping",
    ok(
      "authenticated outsider mapping query",
      await statement(
        "insert into result select to_jsonb(count(*)),null,null from public.import_sources",
        other,
      ),
    ),
    0,
  );
  check(
    "other account cannot forge owner mapping",
    (await statement(
      `insert into public.import_sources(user_id,provider,source_account,entity,source_id,record_id) values(${
        lit(owner)
      },'todoist','forged','tasks','x',${
        lit(randomUUID())
      });insert into result values('true',null,null)`,
      other,
    )).code,
    "42501",
  );
  const originalCount = await count();
  for (
    const [name, change] of [
      ["unknown capability", (b) => b.capabilities = ["future"]],
      ["wrong format", (b) => b.version = 3],
      ["malformed root type", (b) => b.tasks[0].record.is_heading = "true"],
      ["completed root heading", (b) => b.tasks[0].record.completed = true],
      [
        "completed nested heading",
        (b) => b.tasks[0].record.subtasks[0].completed = true,
      ],
    ]
  ) {
    const bad = structuredClone(bundle);
    bad.tasks[0].source_id = randomUUID();
    bad.tasks[0].record.id = randomUUID();
    change(bad);
    const r = await run(bad);
    check(name + " refuses before partial save", r.code !== null);
    check(
      name + " leaves existing rows and mappings unchanged",
      await count(),
      originalCount,
    );
  }
  const childOnly = structuredClone(unversioned);
  delete childOnly.tasks[0].record.is_heading;
  check(
    "nested-only heading also needs capability",
    (await run(childOnly)).code,
    "P0001",
  );
  const oversized = {
    projects: [],
    sections: [],
    labels: [],
    tasks: Array.from({ length: 20001 }, () => ({})),
  };
  check(
    "oversized outer task collection refuses before tree inspection",
    (await run(oversized)).code !== null,
  );
  const deep = structuredClone(bundle);
  deep.tasks[0].source_id = randomUUID();
  deep.tasks[0].record.id = randomUUID();
  let branch = deep.tasks[0].record;
  for (let n = 0; n < 34; n++) {
    branch.subtasks = [{ id: randomUUID(), title: "Child", completed: false }];
    branch = branch.subtasks[0];
  }
  check(
    "typed hierarchy outside reader depth refuses",
    (await run(deep)).code,
    "P0001",
  );
  check(
    "bounded import refusals retain all existing work",
    await count(),
    originalCount,
  );
  const ordinary = {
    projects: [],
    sections: [],
    labels: [],
    tasks: [{
      source_id: "ordinary",
      record: {
        id: randomUUID(),
        title: "* Literal Taskfold text",
        completed: false,
        source_metadata: { opaque: { is_heading: true, completed: true } },
      },
    }],
  };
  const normal = ok(
    "ordinary legacy bundle remains readable",
    await run(ordinary),
  );
  check("ordinary receipt remains legacy", normal.formatVersion === undefined);
  const row = await pg.scalar(
    `select to_jsonb(t) from public.tasks t where id=${
      lit(ordinary.tasks[0].record.id)
    }`,
  );
  check("literal title and opaque metadata are not reinterpreted", [
    row.title,
    row.is_heading,
    row.source_metadata.opaque,
  ], ["* Literal Taskfold text", null, { is_heading: true, completed: true }]);
  await pg.raw(`delete from public.tasks where id=${lit(id)}`);
  ok("replay after deliberate deletion is safe", await run(bundle));
  check("deleted destination is not resurrected", await stored(), null);
  check(
    "RPC remains invoker",
    await pg.scalar(
      "select to_jsonb(prosecdef) from pg_proc where oid='public.taskfold_import_todoist(text,jsonb)'::regprocedure",
    ),
    false,
  );
  check(
    "anonymous role has no import execution",
    await pg.scalar(
      "select to_jsonb(has_function_privilege('anon','public.taskfold_import_todoist(text,jsonb)','execute'))",
    ),
    false,
  );
  report.advisors = await pg.advisors();
  report.passed = Object.keys(report.checks).length;
} finally {
  if (pg) await pg.close();
  if (folder) await rm(folder, { recursive: true, force: true });
}
await writeFile(
  process.argv[2] ?? "/tmp/taskfold-heading-import-sql.json",
  JSON.stringify(report, null, 2) + "\n",
);
console.log(JSON.stringify({ passed: report.passed, deployed: false }));
