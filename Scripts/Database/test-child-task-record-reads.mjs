import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamTaskLifecycle } from "./team-task-schema.mjs";
import { loadTeamChecklistSchema } from "./team-checklist-schema.mjs";
import { loadChildTaskRecordsSchema } from "./child-task-records-schema.mjs";
const sql = await readFile(
  new URL(
    "../../supabase/migrations/20261029001127_child_task_record_reads.sql",
    import.meta.url,
  ),
  "utf8",
);
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
const report = {
  checks: {},
  migrationSHA256: createHash("sha256").update(sql).digest("hex"),
  deployed: false,
  clientAdoption: false,
};
const check = (n, a, e) => {
  assert.deepEqual(a, e, n);
  report.checks[n] = true;
};
const pg = await createPostgresFixture({ advisors: true });
try {
  await loadTeamTaskLifecycle(pg.raw);
  await loadTeamChecklistSchema(pg.raw);
  await loadChildTaskRecordsSchema(pg.raw);
  report.baselineAdvisors = await pg.advisors();
  await pg.raw(sql);
  const owner = randomUUID(),
    viewer = randomUUID(),
    outside = randomUUID(),
    session = randomUUID(),
    vs = randomUUID(),
    os = randomUUID(),
    task = randomUUID(),
    project = randomUUID();
  for (const [id, s] of [[owner, session], [viewer, vs], [outside, os]]) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${lit(id)},${
        lit(id + "@example.invalid")
      },now());insert into public.profiles(user_id) values(${
        lit(id)
      });insert into auth.sessions(id,user_id) values(${lit(s)},${lit(id)});`,
    );
  }
  const source = [{
    id: "parent",
    title: "Keep all fields",
    future: { keep: [null, false] },
    subtasks: [{ id: "child", title: "Nested" }],
  }];
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${lit(project)},${
      lit(owner)
    },'Synthetic read project');insert into public.tasks(id,user_id,project_id,title,subtasks) values(${
      lit(task)
    },${lit(owner)},${lit(project)},'Synthetic read root',${json(source)});`,
  );
  const root = () =>
    pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(task)}`);
  let generation = (await root()).task_generation;
  const call = async (
    {
      id = owner,
      s = session,
      target = task,
      g = generation,
      helper = false,
      claims = {},
    } = {},
  ) =>
    pg.scalar(
      `begin;create temp table result(value jsonb,code text) on commit drop;grant all on result to authenticated;set local role authenticated;set local request.jwt.claim.sub=${
        lit(id)
      };set local request.jwt.claims=${
        lit(JSON.stringify({ sub: id, session_id: s, ...claims }))
      };do $read$begin begin insert into result values(${
        helper
          ? "taskfold_private.read_child_task_records"
          : "public.taskfold_read_child_tasks"
      }(${lit(target)},${
        g ? lit(g) : "null"
      }),null);exception when others then insert into result values(null,sqlstate);end;end$read$;select jsonb_build_object('value',value,'code',code) from result;commit;`,
    );
  check("read gate disabled by default", (await call()).code, "PT503");
  await pg.raw(
    "update taskfold_private.child_task_record_config set reads_enabled=true",
  );
  check("unadopted root requires review", (await call()).code, "PT409");
  await pg.raw(
    `select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${
      lit(task)
    }`,
  );
  const accepted = await call();
  check("owner reads enabled adopted root", accepted.code, null);
  check("account bound", accepted.value.account, owner);
  check("root generation bound", accepted.value.task_generation, generation);
  check("project binding returned", accepted.value.project_id, project);
  check("two records returned", accepted.value.records.length, 2);
  check(
    "unknown fields retained",
    accepted.value.records.find((r) => r.node_key === "parent").fields.future,
    { keep: [null, false] },
  );
  check(
    "no raw snapshot returned",
    Object.hasOwn(accepted.value, "source_tree"),
    false,
  );
  check(
    "outside owner denied",
    (await call({ id: outside, s: os })).code,
    "42501",
  );
  check(
    "helper independently denies outsider",
    (await call({ id: outside, s: os, helper: true })).code,
    "42501",
  );
  check(
    "wrong generation denied",
    (await call({ g: randomUUID() })).code,
    "42501",
  );
  check(
    "missing root denied",
    (await call({ target: randomUUID() })).code,
    "42501",
  );
  for (
    const [label, opts] of [
      ["no session", { claims: { session_id: null } }],
      ["malformed session", { claims: { session_id: "invalid" } }],
      ["forged session", { s: randomUUID() }],
      ["another actor session", { s: vs }],
    ]
  ) check(label, (await call(opts)).code, "42501");
  await pg.raw(
    `update auth.sessions set not_after=now()-interval '1 minute' where id=${
      lit(session)
    }`,
  );
  check("expired session denied", (await call()).code, "42501");
  await pg.raw(
    `update auth.sessions set not_after=null where id=${lit(session)}`,
  );
  await pg.raw(
    `update auth.users set banned_until=now()+interval '1 day' where id=${
      lit(owner)
    }`,
  );
  check("banned actor denied", (await call()).code, "42501");
  await pg.raw(
    `update auth.users set banned_until=null where id=${lit(owner)}`,
  );
  await pg.raw(
    `set request.jwt.claim.sub=${
      lit(owner)
    };insert into public.project_collaborators(id,project_id,user_id,invited_by,status,invited_email) values(${
      lit(randomUUID())
    },${lit(project)},${lit(viewer)},${lit(owner)},'pending',${
      lit(viewer + "@example.invalid")
    });update public.project_collaborators set status='accepted' where user_id=${
      lit(viewer)
    }`,
  );
  check(
    "accepted collaborator can read",
    (await call({ id: viewer, s: vs })).code,
    null,
  );
  await pg.raw(
    `set request.jwt.claim.sub=${
      lit(owner)
    };update public.project_collaborators set status='pending' where user_id=${
      lit(viewer)
    }`,
  );
  check(
    "revoked collaboration denied",
    (await call({ id: viewer, s: vs })).code,
    "42501",
  );
  check(
    "helper denies revoked collaboration",
    (await call({ id: viewer, s: vs, helper: true })).code,
    "42501",
  );
  await pg.raw(
    `update public.tasks set subtasks='[{"id":"dup"},{"id":"dup"}]' where id=${
      lit(task)
    }`,
  );
  check("ambiguous source requires review", (await call()).code, "PT409");
  await pg.raw(
    `update taskfold_private.child_task_projections set state='ready',issue=null where task_id=${
      lit(task)
    }`,
  );
  check(
    "incorrect ready marker cannot admit malformed source",
    (await call()).code,
    "PT409",
  );
  await pg.raw(
    `update public.tasks set subtasks=${json(source)} where id=${lit(task)}`,
  );
  const row = await pg.scalar(
    `select to_jsonb(r) from taskfold_private.child_task_records r where task_id=${
      lit(task)
    } and node_key='child'`,
  );
  await pg.raw(
    `update taskfold_private.child_task_records set fields=fields||'{"title":"Wrong derived value"}' where task_id=${
      lit(task)
    } and node_key='child'`,
  );
  check("corrupt derived row cannot leak", (await call()).code, "PT409");
  await pg.raw(
    `update taskfold_private.child_task_records set fields=${
      json(row.fields)
    } where task_id=${lit(task)} and node_key='child'`,
  );
  check("restored projection reads", (await call()).code, null);
  await pg.raw(
    `update taskfold_private.child_task_projections set source_tree='[]' where task_id=${
      lit(task)
    }`,
  );
  check("stale projection refused", (await call()).code, "PT409");
  await pg.raw(
    `update taskfold_private.child_task_projections set source_tree=${
      json(source)
    } where task_id=${lit(task)}`,
  );
  // Actual root update holds the lock; read must wait and return the committed tree.
  const changed = structuredClone(source);
  changed[0].subtasks[0].title = "Concurrent update wins";
  const holder = await pg.hold(
    `update public.tasks set subtasks=${json(changed)} where id=${lit(task)}`,
  );
  let pending;
  try {
    pending = pg.scalar(
      `set application_name='taskfold-child-read-race';set role authenticated;set request.jwt.claim.sub=${
        lit(owner)
      };set request.jwt.claims=${
        lit(JSON.stringify({ sub: owner, session_id: session }))
      };select public.taskfold_read_child_tasks(${lit(task)},${
        lit(generation)
      })`,
    );
    await pg.waitForLock("taskfold-child-read-race", holder.pid);
    await holder.release("commit");
    check(
      "read waits for root write and returns winning content",
      (await pending).records.find((r) => r.node_key === "child").fields.title,
      "Concurrent update wins",
    );
  } finally {
    await holder.release("rollback");
    if (pending) await pending;
  }
  for (const role of ["anon", "service_role"]) {
    let code;
    try {
      await pg.raw(
        `set role ${role};select public.taskfold_read_child_tasks(${
          lit(task)
        },${lit(generation)})`,
      );
    } catch (e) {
      code = e.code;
    }
    check(role + " has no read API grant", code, "42501");
  }
  check(
    "authenticated still cannot select private records",
    await pg.scalar(
      "select to_jsonb(has_table_privilege('authenticated','taskfold_private.child_task_records','SELECT'))",
    ),
    false,
  );
  await pg.raw(`delete from auth.sessions where id=${lit(session)}`);
  check("deleted session denied", (await call()).code, "42501");
  await pg.raw(
    `update public.tasks set subtasks=jsonb_build_array(jsonb_build_object('id','large','description',repeat('x',2000001))) where id=${
      lit(task)
    }`,
  );
  // This actor's session was deleted above; restore only this synthetic session.
  await pg.raw(
    `insert into auth.sessions(id,user_id) values(${lit(session)},${
      lit(owner)
    })`,
  );
  check(
    "oversized read is refused without content",
    (await call()).code,
    "54000",
  );
  await pg.raw(
    `update public.tasks set subtasks=${json(source)} where id=${lit(task)}`,
  );
  const team = randomUUID();
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(owner)
    },'Synthetic reader team');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(owner)},'admin'),(${lit(team)},${lit(viewer)},'member'),(${
      lit(team)
    },${
      lit(outside)
    },'guest');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
      lit(project)
    },${
      lit(team)
    },'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${
      lit(project)
    },${lit(team)},${lit(viewer)},'viewer');`,
  );
  check("team native gate still applies", (await call()).code, "42501");
  await pg.raw(
    "update taskfold_private.team_project_config set native_reads_enabled=true",
  );
  check("team manager can read", (await call()).code, null);
  check("team viewer can read", (await call({ id: viewer, s: vs })).code, null);
  check(
    "ungranted guest cannot read",
    (await call({ id: outside, s: os })).code,
    "42501",
  );
  check(
    "forged user metadata grants nothing",
    (await call({
      id: outside,
      s: os,
      helper: true,
      claims: { user_metadata: { role: "manager", team_id: team } },
    })).code,
    "42501",
  );
  await pg.raw(
    `update public.projects set is_archived=true where id=${lit(project)}`,
  );
  check(
    "archived project remains readable to viewer",
    (await call({ id: viewer, s: vs })).code,
    null,
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where user_id=${
      lit(viewer)
    }`,
  );
  check(
    "revoked viewer denied",
    (await call({ id: viewer, s: vs })).code,
    "42501",
  );
  check(
    "private helper also rejects revoked viewer",
    (await call({ id: viewer, s: vs, helper: true })).code,
    "42501",
  );
  await pg.raw(
    "update taskfold_private.child_task_record_config set reads_enabled=false",
  );
  check(
    "candidate gate closes accepted team reader",
    (await call()).code,
    "PT503",
  );
  report.advisors = await pg.advisors();
  const keys = new Set(report.baselineAdvisors.result.map((r) => r.cache_key));
  check(
    "no added advisor findings",
    report.advisors.result.filter((r) => !keys.has(r.cache_key)),
    [],
  );
} finally {
  report.containerRemoved = await pg.close();
}
report.checkCount = Object.keys(report.checks).length;
if (process.argv[2]) {
  await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
}
console.log(
  JSON.stringify({
    checks: report.checkCount,
    containerRemoved: report.containerRemoved,
  }),
);
