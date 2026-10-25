import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import {
  loadTeamBatchSchema,
  teamBatchMigration as migration,
} from "./team-batch-schema.mjs";
const report = {
  checks: {},
  deployed: false,
  realDataChanged: false,
  nativeTeamUIEnabled: false,
};
const check = (n, a, b = true) => {
  assert.deepEqual(a, b, n);
  report.checks[n] = true;
};
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
const u = Object.fromEntries(
  ["owner", "editor", "viewer", "outsider"].map(
    (k) => [k, { id: randomUUID(), session: randomUUID() }],
  ),
);
const team = randomUUID(), project = randomUUID(), other = randomUUID();
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  const currentWorkspace = process.env.TASKFOLD_TEAM_CURRENT_BATCH_REGRESSION === "1";
  if (currentWorkspace) {
    const { loadTeamWorkspaceSchema } = await import("./team-workspace-schema.mjs");
    await loadTeamWorkspaceSchema(pg.raw);
    report.currentWorkspaceSchema = true;
  } else { await loadTeamBatchSchema(pg.raw); }
  report.migrationSHA256 = createHash("sha256").update(
    await readFile(
      new URL("../../supabase/migrations/" + migration, import.meta.url),
    ),
  ).digest("hex");
  if (!currentWorkspace && process.env.TASKFOLD_TEAM_PLANNING_REGRESSION === "1") {
    const { loadTeamPlanningSchema, teamPlanningMigration } = await import(
      "./team-planning-schema.mjs"
    );
    await loadTeamPlanningSchema(pg.raw);
    report.planningMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamPlanningMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (!currentWorkspace && process.env.TASKFOLD_TEAM_CHECKLIST_REGRESSION === "1") {
    if (process.env.TASKFOLD_TEAM_PLANNING_REGRESSION !== "1") {
      throw new Error("Checklist regression requires planning");
    }
    const { loadTeamChecklistSchema, teamChecklistMigration } = await import(
      "./team-checklist-schema.mjs"
    );
    await loadTeamChecklistSchema(pg.raw);
    report.checklistMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamChecklistMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (!currentWorkspace && process.env.TASKFOLD_TEAM_COMPLETION_REGRESSION === "1") {
    if (process.env.TASKFOLD_TEAM_CHECKLIST_REGRESSION !== "1") {
      throw new Error("Completion regression requires checklist schema");
    }
    const { loadTeamCompletionSchema, teamCompletionMigration } = await import(
      "./team-completion-schema.mjs"
    );
    await loadTeamCompletionSchema(pg.raw, { base: false });
    report.completionMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamCompletionMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  for (const [n, x] of Object.entries(u)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at)values(${lit(x.id)},${
        lit(n + "@example.invalid")
      },now());insert into auth.sessions(id,user_id)values(${lit(x.session)},${
        lit(x.id)
      });`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name)values(${lit(team)},${
      lit(u.owner.id)
    },'Batch workspace');` + Object.entries(u).filter(([n]) =>
      n !== "outsider"
    ).map(([n, x]) =>
      `insert into taskfold_private.team_members(team_id,user_id,role)values(${
        lit(team)
      },${lit(x.id)},${lit(n === "owner" ? "admin" : "member")});`
    ).join(""),
  );
  for (const p of [project, other]) {
    await pg.raw(
      `insert into public.projects(id,user_id,name)values(${lit(p)},${
        lit(u.owner.id)
      },'Batch project');insert into taskfold_private.team_content_projects(project_id,team_id)values(${
        lit(p)
      },${lit(team)});insert into taskfold_private.team_project_grants values(${
        lit(p)
      },${lit(team)},${lit(u.viewer.id)},'viewer');`,
    );
  }
  const run = (who, expr, opts = {}) => {
    const x = u[who];
    return pg.scalar(
      `begin;set application_name=${
        lit(opts.app ?? "batch-" + randomUUID().slice(0, 8))
      };create temp table result(value jsonb,code text,reason text)on commit drop;grant all on result to authenticated,anon,service_role;set local role ${
        opts.role ?? "authenticated"
      };set local request.jwt.claim.sub=${
        lit(x.id)
      };set local request.jwt.claims=${
        lit(
          JSON.stringify({ sub: x.id, session_id: opts.session ?? x.session }),
        )
      };do $r$begin begin insert into result values((${expr}),null,null);exception when others then insert into result values(null,sqlstate,left(sqlerrm,160));end;end$r$;select jsonb_build_object('value',value,'code',code,'reason',reason)from result;commit;`,
    );
  };
  const rpc = (who, op, b, opts) =>
    run(who, `public.taskfold_team_task_batch(${lit(op)},${json(b)})`, opts);
  const row = (id) =>
    pg.scalar(
      `select coalesce((select to_jsonb(t) from public.tasks t where id=${
        lit(id)
      }),'null'::jsonb)`,
    );
  const seed = async (title, parent = null, p = project) => {
    const id = randomUUID();
    await pg.raw(
      `insert into public.tasks(id,user_id,project_id,title,recurrence_parent_id)values(${
        lit(id)
      },${lit(u.owner.id)},${lit(p)},${lit(title)},${
        parent ? lit(parent) : "null"
      });insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body)select ${
        lit(randomUUID())
      },id,task_generation,project_id,${lit(u.owner.id)},${
        lit("Discussion: " + title)
      }from public.tasks where id=${lit(id)};`,
    );
    return id;
  };
  const deletion = async (ids) => ({
    team_id: team,
    request_id: randomUUID(),
    items: (await Promise.all(ids.map(async (id) => {
      const r = await row(id);
      return {
        team_id: team,
        project_id: r.project_id,
        task_id: id,
        request_id: randomUUID(),
        task_generation: r.task_generation,
        record: r,
      };
    }))).sort((a, b) => a.task_id.localeCompare(b.task_id)),
  });
  const restore = (d) => ({
    team_id: team,
    request_id: randomUUID(),
    restores: d.request_id,
    items: d.items.map((i) => {
      const g = randomUUID();
      return {
        ...i,
        request_id: randomUUID(),
        task_generation: g,
        record: { ...i.record, task_generation: g, completion_version: 0 },
        restore_from: i.request_id,
      };
    }),
  });
  const parent = await seed("Parent"),
    child = await seed("Child", parent, other),
    grandchild = await seed("Grandchild", child),
    external = await seed("Unselected occurrence", parent);
  const d = await deletion([parent, grandchild, child]);
  check(
    "disabled by default",
    (await rpc("editor", "delete", d)).code,
    "PT503",
  );
  await pg.raw(
    "update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true",
  );
  for (const who of ["viewer", "outsider"]) {
    check(who + " denied", (await rpc(who, "delete", d)).code, "42501");
  }
  for (const role of ["anon", "service_role"]) {
    check(
      role + " denied",
      (await rpc("editor", "delete", d, { role })).code,
      "42501",
    );
  }
  check(
    "stale session denied",
    (await rpc("editor", "delete", d, { session: randomUUID() })).code,
    "28000",
  );
  let result = await rpc("editor", "delete", d);
  check("linked deletion succeeds", result.code, null);
  check(
    "selected roots all removed",
    await Promise.all([parent, child, grandchild].map(row)),
    [null, null, null],
  );
  check(
    "unselected occurrence remains",
    (await row(external)).title,
    "Unselected occurrence",
  );
  check(
    "unselected occurrence detached",
    (await row(external)).recurrence_parent_id,
    null,
  );
  const native = {
    account: u.editor.id,
    delete: { body: d, reply: result.value },
  };
  check(
    "batch receipt is minimal",
    JSON.stringify(result.value).includes("Parent"),
    false,
  );
  check(
    "three private discussion archives",
    await pg.scalar(
      `select to_jsonb(count(*))from taskfold_private.team_conversation_keys where team_id=${
        lit(team)
      }`,
    ),
    3,
  );
  check(
    "batch scope cleaned",
    await pg.scalar(
      "select to_jsonb(count(*))from taskfold_private.team_task_batch_scope",
    ),
    0,
  );
  check(
    "lost response retry acknowledged",
    (await rpc("editor", "delete", d)).value.replayed,
    true,
  );
  const changed = structuredClone(d);
  changed.items[0].record.title = "Changed payload";
  check(
    "nonce cannot change payload",
    (await rpc("editor", "delete", changed)).code,
    "PT409",
  );
  const standalone = { ...restore(d).items[0] };
  check(
    "single Undo cannot split selection",
    (await run(
      "editor",
      `public.taskfold_team_task_lifecycle('restore',${json(standalone)})`,
    )).code,
    "PT409",
  );
  const partial = restore(d);
  partial.items.pop();
  check(
    "partial Undo rejected",
    (await rpc("editor", "restore", partial)).code,
    "PT409",
  );
  const undo = restore(d);
  result = await rpc("editor", "restore", undo);
  check("linked Undo succeeds", result.code, null);
  native.restore = { body: undo, reply: result.value };
  const restored = await Promise.all(
    [parent, child, grandchild, external].map(row),
  );
  check("child parent restored", restored[1].recurrence_parent_id, parent);
  check("grandchild parent restored", restored[2].recurrence_parent_id, child);
  check(
    "external occurrence reattached",
    restored[3].recurrence_parent_id,
    parent,
  );
  check(
    "all selected generations new",
    restored.slice(0, 3).every((r) =>
      undo.items.find((i) => i.task_id === r.id).task_generation ===
        r.task_generation
    ),
  );
  check(
    "discussion count restored",
    await pg.scalar(
      `select to_jsonb(count(*))from public.task_comments where task_id in(${
        [parent, child, grandchild].map(lit).join(",")
      })`,
    ),
    3,
  );
  check(
    "recovery keys consumed",
    await pg.scalar(
      `select to_jsonb(count(*))from taskfold_private.team_conversation_keys where team_id=${
        lit(team)
      }`,
    ),
    0,
  );
  check(
    "Undo retry idempotent",
    (await rpc("editor", "restore", undo)).value.replayed,
    true,
  );
  check(
    "old delete retry does not delete new generation",
    (await rpc("editor", "delete", d)).code,
    null,
  );
  check(
    "new generation still live",
    (await row(parent)).task_generation,
    restored[0].task_generation,
  );
  check(
    "consumed batch Undo cannot run again",
    (await rpc("editor", "restore", restore(d))).code,
    "PT409",
  );
  const stale = await deletion([parent, child]);
  await pg.raw(
    `update public.tasks set title='Newer child work'where id=${lit(child)}`,
  );
  check(
    "one changed task blocks whole batch",
    (await rpc("editor", "delete", stale)).code,
    "PT409",
  );
  check("parent preserved after conflict", (await row(parent)).title, "Parent");
  const missing = await deletion([parent, child, grandchild]);
  await pg.raw(`delete from public.tasks where id=${lit(grandchild)}`);
  const missingOriginal = structuredClone(missing);
  missingOriginal.request_id = randomUUID();
  check(
    "one missing task blocks whole batch",
    (await rpc("editor", "delete", missingOriginal)).code,
    "PT409",
  );
  const duplicate = await deletion([parent, child]);
  duplicate.items[1].task_id = duplicate.items[0].task_id;
  check(
    "duplicate task identity rejected",
    (await rpc("editor", "delete", duplicate)).code,
    "22023",
  );
  const fresh = await deletion([parent, child]);
  fresh.items[1].request_id = fresh.items[0].request_id;
  check(
    "duplicate operation identity rejected",
    (await rpc("editor", "delete", fresh)).code,
    "22023",
  );
  const forged = await deletion([parent, child]);
  forged.items[0].team_id = randomUUID();
  check(
    "mixed workspace rejected",
    (await rpc("editor", "delete", forged)).code,
    "22023",
  );
  const alive = await deletion([parent, child]);
  alive.request_id = d.request_id;
  check(
    "header nonce cannot be reused",
    (await rpc("editor", "delete", alive)).code,
    "PT409",
  );
  const longA = await seed("Large selection record"),
    longB = await seed("Second large record");
  await pg.raw(
    `update public.tasks set description=repeat('x',30000)where id in(${
      lit(longA)
    },${lit(longB)})`,
  );
  const big = await deletion([longA, longB]);
  check(
    "large records are supported",
    (await rpc("editor", "delete", big)).code,
    null,
  );
  check(
    "large record Undo works",
    (await rpc("editor", "restore", restore(big))).code,
    null,
  );
  const brokenA = await seed("Atomic one"),
    brokenB = await seed("Atomic two"),
    atomicDelete = await deletion([brokenA, brokenB]);
  const lastDelete = atomicDelete.items.at(-1).task_id;
  await pg.raw(
    `create function taskfold_private.fixture_fail_batch_delete() returns trigger language plpgsql set search_path='' as $$begin if old.id=${
      lit(lastDelete)
    }::uuid and auth.uid() is not null then raise exception using errcode='PT409',message='Owned atomic failure';end if;return old;end$$;create trigger z_fixture_fail_batch_delete before delete on public.tasks for each row execute function taskfold_private.fixture_fail_batch_delete()`,
  );
  check(
    "second deletion failure rolls back first",
    (await rpc("editor", "delete", atomicDelete)).code,
    "PT409",
  );
  check(
    "failed batch keeps every task",
    (await Promise.all([brokenA, brokenB].map(row))).every(Boolean),
  );
  check(
    "failed batch has no header receipt",
    await pg.scalar(
      `select to_jsonb(count(*))from taskfold_private.team_task_batches where request_id=${
        lit(atomicDelete.request_id)
      }`,
    ),
    0,
  );
  check(
    "failed batch has no member receipts",
    await pg.scalar(
      `select to_jsonb(count(*))from taskfold_private.team_task_edits where request_id in(${
        atomicDelete.items.map((i) => lit(i.request_id)).join(",")
      })`,
    ),
    0,
  );
  await pg.raw(
    "drop trigger z_fixture_fail_batch_delete on public.tasks;drop function taskfold_private.fixture_fail_batch_delete()",
  );
  check(
    "same failed batch identity retries safely",
    (await rpc("editor", "delete", atomicDelete)).code,
    null,
  );
  const atomicRestore = restore(atomicDelete),
    orderedRestore = await pg.scalar(
      `select to_jsonb(taskfold_private.team_batch_order(${
        json(atomicRestore.items)
      },'restore'))`,
    ),
    lastRestore = orderedRestore.at(-1);
  await pg.raw(
    `create function taskfold_private.fixture_fail_batch_restore() returns trigger language plpgsql set search_path='' as $$begin if new.id=${
      lit(lastRestore)
    }::uuid and auth.uid() is not null then raise exception using errcode='PT409',message='Owned atomic failure';end if;return new;end$$;create trigger z_fixture_fail_batch_restore before insert on public.tasks for each row execute function taskfold_private.fixture_fail_batch_restore()`,
  );
  check(
    "second restoration failure rolls back first",
    (await rpc("editor", "restore", atomicRestore)).code,
    "PT409",
  );
  check(
    "failed Undo recreates no selected task",
    await Promise.all([brokenA, brokenB].map(row)),
    [null, null],
  );
  check(
    "failed Undo retains every discussion key",
    await pg.scalar(
      `select to_jsonb(count(*))from taskfold_private.team_conversation_keys where request_id in(${
        atomicDelete.items.map((i) => lit(i.request_id)).join(",")
      })`,
    ),
    2,
  );
  check(
    "failed Undo does not consume group receipt",
    await pg.scalar(
      `select to_jsonb(restored_request is null)from taskfold_private.team_task_batches where request_id=${
        lit(atomicDelete.request_id)
      }`,
    ),
  );
  await pg.raw(
    "drop trigger z_fixture_fail_batch_restore on public.tasks;drop function taskfold_private.fixture_fail_batch_restore()",
  );
  check(
    "same failed Undo identity retries safely",
    (await rpc("editor", "restore", atomicRestore)).code,
    null,
  );
  const current = await row(parent), soloNonce = await deletion([parent]);
  soloNonce.items[0].request_id = d.request_id;
  check(
    "batch header nonce cannot be reused by single lifecycle",
    (await run(
      "editor",
      `public.taskfold_team_task_lifecycle('delete',${
        json(soloNonce.items[0])
      })`,
    )).code,
    "PT409",
  );
  check(
    "batch header nonce cannot be reused by patch",
    (await run(
      "editor",
      `public.taskfold_edit_team_task(${
        json({
          team_id: team,
          project_id: project,
          task_id: parent,
          request_id: d.request_id,
          task_generation: current.task_generation,
          base: {
            title: current.title,
            project_id: project,
            task_generation: current.task_generation,
          },
          changes: { title: "Forged nonce" },
        })
      })`,
    )).code,
    "PT409",
  );
  const memberNonce = await deletion([parent, child]);
  memberNonce.items[0].request_id = d.request_id;
  check(
    "batch header nonce cannot become a member nonce",
    (await rpc("editor", "delete", memberNonce)).code,
    "PT409",
  );
  for (
    const table of [
      "team_task_batches",
      "team_task_batch_items",
      "team_task_batch_scope",
    ]
  ) {
    check(
      table + " inaccessible",
      (await run(
        "editor",
        `(select to_jsonb(count(*))from taskfold_private.${table})`,
      )).code,
      "42501",
    );
  }
  const cycleA = await seed("Cycle A"), cycleB = await seed("Cycle B", cycleA);
  await pg.raw(
    `update public.tasks set recurrence_parent_id=${lit(cycleB)} where id=${
      lit(cycleA)
    }`,
  );
  check(
    "cyclic selection rejected without partial effects",
    (await rpc("editor", "delete", await deletion([cycleA, cycleB]))).code,
    "PT409",
  );
  check(
    "cyclic tasks remain",
    (await Promise.all([cycleA, cycleB].map(row))).every(Boolean),
  );
  const empty = await deletion([parent]);
  empty.items = [];
  check(
    "empty group rejected",
    (await rpc("editor", "delete", empty)).code,
    "22023",
  );
  const tooMany = await deletion([parent]);
  tooMany.items = Array.from({ length: 101 }, () => tooMany.items[0]);
  check(
    "oversized group rejected",
    (await rpc("editor", "delete", tooMany)).code,
    "22023",
  );
  const replay = await deletion([parent, child]), app = "batch-role-revoke";
  const holder = await pg.hold(
    `select id from taskfold_private.teams where id=${lit(team)}for update`,
  );
  const pending = rpc("editor", "delete", replay, { app });
  await pg.waitForLock(app, holder.pid);
  await holder.release(
    "commit",
    `insert into taskfold_private.team_project_grants values(${lit(other)},${
      lit(team)
    },${lit(u.editor.id)},'viewer')`,
  );
  check(
    "project revocation while waiting blocks whole selection",
    (await pending).code,
    "42501",
  );
  check(
    "parent retained after project revocation",
    (await row(parent)) !== null,
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where user_id=${
      lit(u.editor.id)
    }`,
  );
  const contended = await deletion([parent, child]),
    holdTask = await pg.hold(
      `select id from public.tasks where id=${lit(child)}for update`,
    );
  const contendedRequest = rpc("editor", "delete", contended, {
    app: "batch-newer-content",
  });
  await pg.waitForLock("batch-newer-content", holdTask.pid);
  await holdTask.release(
    "commit",
    `update public.tasks set title='Concurrent protected work'where id=${
      lit(child)
    }`,
  );
  check(
    "new content while waiting prevents whole batch",
    (await contendedRequest).code,
    "PT409",
  );
  check("parent remains after waiting conflict", (await row(parent)) !== null);
  check(
    "all task scopes clean",
    await pg.scalar(
      "select to_jsonb(count(*))from taskfold_private.team_task_edit_scope",
    ),
    0,
  );
  check(
    "all batch scopes clean",
    await pg.scalar(
      "select to_jsonb(count(*))from taskfold_private.team_task_batch_scope",
    ),
    0,
  );
  check(
    "all discussion scopes clean",
    await pg.scalar(
      "select to_jsonb(count(*))from taskfold_private.team_conversation_scope",
    ),
    0,
  );
  const archived = await deletion([parent, child]);
  await pg.raw(
    `update public.projects set is_archived=true where id=${lit(other)}`,
  );
  check(
    "one archived project blocks whole selection",
    (await rpc("editor", "delete", archived)).code,
    "PT409",
  );
  check("archive denial preserves other project", (await row(parent)) !== null);
  await pg.raw(
    `update public.projects set is_archived=false where id=${lit(other)}`,
  );
  const cleanupA = await seed("Cleanup A"),
    cleanupB = await seed("Cleanup B"),
    cleanup = await deletion([cleanupA, cleanupB]);
  check(
    "actor cleanup batch created",
    (await rpc("editor", "delete", cleanup)).code,
    null,
  );
  await pg.raw(`delete from auth.users where id=${lit(u.editor.id)}`);
  check(
    "actor removal cleans group receipts",
    await pg.scalar(
      `select to_jsonb(count(*))from taskfold_private.team_task_batches where actor_id=${
        lit(u.editor.id)
      }`,
    ),
    0,
  );
  check(
    "actor removal cleans member receipts",
    await pg.scalar(
      `select to_jsonb(count(*))from taskfold_private.team_task_edits where actor_id=${
        lit(u.editor.id)
      }`,
    ),
    0,
  );
  check(
    "actor removal cleans recovery keys",
    await pg.scalar(
      `select to_jsonb(count(*))from taskfold_private.team_conversation_keys where team_id=${
        lit(team)
      }`,
    ),
    0,
  );
  check(
    "removed actor cannot replay batch",
    (await rpc("editor", "delete", cleanup)).code,
    "28000",
  );
  report.advisors = await pg.advisors();
  check(
    "no new advisor warnings",
    report.advisors.result.filter((x) =>
      ["WARN", "ERROR"].includes(x.level) && x.name !== "auth_rls_initplan"
    ),
    [],
  );
  report.containerRemoved = await pg.close();
  pg = null;
  report.checkCount = Object.keys(report.checks).length;
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
  if (process.argv[3]) {
    await writeFile(process.argv[3], JSON.stringify(native, null, 2) + "\n");
  }
  console.log(
    JSON.stringify({
      checks: report.checkCount,
      containerRemoved: report.containerRemoved,
    }),
  );
} finally {
  if (pg) await pg.close();
}
