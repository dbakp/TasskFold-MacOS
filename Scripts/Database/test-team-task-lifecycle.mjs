import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import {
  loadTeamTaskLifecycle,
  teamTaskLifecycleMigration as migration,
} from "./team-task-schema.mjs";
const report = {
  checks: {},
  deployed: false,
  nativeRolloutEnabled: false,
  realDataChanged: false,
  hostedAcceptanceClaimed: false,
  conversationAdapterComplete: false,
};
function check(name, actual, expected) {
  assert.deepEqual(actual, expected, name);
  report.checks[name] = true;
}
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
const people = Object.fromEntries(
  ["owner", "editor", "viewer", "guest", "outsider", "author"].map(
    (k) => [k, { id: randomUUID(), session: randomUUID() }],
  ),
);
const team = randomUUID(),
  project = randomUUID(),
  privateProject = randomUUID(),
  otherTeam = randomUUID(),
  otherProject = randomUUID(),
  section = randomUUID();
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadTeamTaskLifecycle(pg.raw);
  if (process.env.TASKFOLD_TEAM_CONVERSATION_REGRESSION === "1") {
    const { loadTeamConversationSchema, teamConversationMigration } =
      await import("./team-conversation-schema.mjs");
    await loadTeamConversationSchema(pg.raw, { base: false });
    report.conversationAdapterComplete = true;
    report.conversationMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamConversationMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (process.env.TASKFOLD_TEAM_BATCH_REGRESSION === "1") {
    const { loadTeamBatchSchema, teamBatchMigration } = await import(
      "./team-batch-schema.mjs"
    );
    await loadTeamBatchSchema(pg.raw, { base: false });
    report.batchMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamBatchMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  report.migrationSHA256 = createHash("sha256").update(
    await readFile(
      new URL("../../supabase/migrations/" + migration, import.meta.url),
    ),
  ).digest("hex");
  if (process.env.TASKFOLD_TEAM_PLANNING_REGRESSION === "1") {
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
  if (process.env.TASKFOLD_TEAM_CHECKLIST_REGRESSION === "1") {
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
  if (process.env.TASKFOLD_TEAM_COMPLETION_REGRESSION === "1") {
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
  for (const [name, u] of Object.entries(people)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${
        lit(name + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${
        lit(u.id)
      });`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(people.owner.id)
    },'Synthetic workspace'),(${lit(otherTeam)},${
      lit(people.outsider.id)
    },'Other workspace');` + Object.entries(people).filter(([k]) =>
      k !== "outsider"
    ).map(([k, u]) =>
      `insert into taskfold_private.team_members(team_id,user_id,role) values(${
        lit(team)
      },${lit(u.id)},${
        lit(k === "owner" ? "admin" : k === "guest" ? "guest" : "member")
      });`
    ).join("") +
      `insert into taskfold_private.team_members(team_id,user_id,role) values(${
        lit(otherTeam)
      },${lit(people.outsider.id)},'admin');`,
  );
  for (
    const [p, t, v] of [[project, team, "team"], [
      privateProject,
      team,
      "private",
    ], [otherProject, otherTeam, "team"]]
  ) {
    await pg.raw(
      `insert into public.projects(id,user_id,name) values(${lit(p)},${
        lit(t === team ? people.owner.id : people.outsider.id)
      },'Synthetic project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
        lit(p)
      },${lit(t)},${lit(v)});`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${
      lit(people.viewer.id)
    },'viewer');insert into public.sections(id,user_id,project_id,name) values(${
      lit(section)
    },${lit(people.owner.id)},${lit(project)},'Design');`,
  );
  const run = (who, expression, opts = {}) => {
    const u = people[who];
    return pg.scalar(
      `begin;set application_name=${
        lit(opts.app ?? "team-life-" + randomUUID().slice(0, 8))
      };create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated,anon,service_role;set local role ${
        opts.role ?? "authenticated"
      };set local request.jwt.claim.sub=${
        lit(u.id)
      };set local request.jwt.claims=${
        lit(
          JSON.stringify({
            sub: u.id,
            session_id: opts.session ?? u.session,
            ...opts.claims,
          }),
        )
      };do $r$begin begin ${
        opts.statement ??
          `insert into result values((${expression}),null,null);`
      }exception when others then insert into result values(null,sqlstate,left(sqlerrm,180));end;end$r$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`,
    );
  };
  const rpc = (who, op, b, opts) =>
    run(
      who,
      `public.taskfold_team_task_lifecycle(${lit(op)},${json(b)})`,
      opts,
    );
  const fresh = (who = "editor", fields = {}, extra = {}) => {
    const id = fields.id ?? randomUUID(),
      g = fields.task_generation ?? randomUUID();
    return {
      team_id: team,
      project_id: project,
      task_id: id,
      request_id: randomUUID(),
      task_generation: g,
      record: {
        id,
        user_id: people[who].id,
        project_id: project,
        task_generation: g,
        title: "Create a useful task",
        ...fields,
      },
      ...extra,
    };
  };
  const row = (id) =>
    pg.scalar(
      `select coalesce((select to_jsonb(t) from public.tasks t where id=${
        lit(id)
      }),'null'::jsonb)`,
    );
  const deletion = async (id) => {
    const r = await row(id);
    return {
      team_id: team,
      project_id: r.project_id,
      task_id: id,
      request_id: randomUUID(),
      task_generation: r.task_generation,
      record: r,
    };
  };
  const restore = (d, extra = {}) => {
    const g = randomUUID();
    return {
      ...d,
      request_id: randomUUID(),
      task_generation: g,
      record: { ...d.record, task_generation: g, completion_version: 0 },
      restore_from: d.request_id,
      ...extra,
    };
  };
  const success = async (name, who, op, b) => {
    const r = await rpc(who, op, b);
    check(name, r.code, null);
    return r.value;
  };
  const original = fresh();
  check(
    "feature defaults disabled",
    (await rpc("editor", "create", original)).code,
    "PT503",
  );
  await pg.raw(
    "update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true",
  );
  for (const who of ["viewer", "guest", "outsider"]) {
    check(
      who + " cannot create",
      (await rpc(who, "create", fresh(who))).code,
      "42501",
    );
  }
  for (const role of ["anon", "service_role"]) {
    check(
      role + " cannot call lifecycle",
      (await rpc("editor", "create", original, { role })).code,
      "42501",
    );
  }
  check(
    "expired session denied",
    (await rpc("editor", "create", original, { session: randomUUID() })).code,
    "28000",
  );
  const created = await success(
    "fresh task created",
    "editor",
    "create",
    original,
  );
  check("generation and creator retained", [
    created.task.task_generation,
    created.task.user_id,
    created.task.completion_version,
  ], [original.task_generation, people.editor.id, 0]);
  const legacyBase = await row(original.task_id);
  check(
    "legacy unscoped deletion cannot silently acknowledge team task",
    (await run(
      "editor",
      `to_jsonb(public.taskfold_delete_task(${lit(original.task_id)},${
        json(legacyBase)
      }))`,
    )).code,
    "PT409",
  );
  check(
    "legacy unscoped patch requires team review",
    (await run(
      "editor",
      `to_jsonb(public.taskfold_patch_task(${lit(original.task_id)},${
        json(legacyBase)
      },'{"title":"Unsafe legacy edit"}'))`,
    )).code,
    "PT409",
  );
  const native = {
    account: people.editor.id,
    create: { body: original, reply: created },
  };
  check(
    "create retry stable",
    (await rpc("editor", "create", original)).value.replayed,
    true,
  );
  await pg.raw(
    `update public.tasks set description='Later task work' where id=${
      lit(original.task_id)
    }`,
  );
  check(
    "create retry preserves newer fields",
    (await rpc("editor", "create", original)).value.task.description,
    "Later task work",
  );
  check(
    "same nonce cannot change payload",
    (await rpc("editor", "create", {
      ...original,
      record: { ...original.record, title: "Changed" },
    })).code,
    "PT409",
  );
  check(
    "fresh create cannot impersonate",
    (await rpc("editor", "create", fresh("owner"))).code,
    "PT409",
  );
  check(
    "existing task cannot be overwritten",
    (await rpc("editor", "create", { ...original, request_id: randomUUID() }))
      .code,
    "PT409",
  );
  check(
    "private project unavailable",
    (await rpc(
      "editor",
      "create",
      fresh("editor", { project_id: privateProject }, {
        project_id: privateProject,
      }),
    )).code,
    "42501",
  );
  check(
    "cross workspace unavailable",
    (await rpc(
      "editor",
      "create",
      fresh("editor", { project_id: otherProject }, {
        project_id: otherProject,
      }),
    )).code,
    "42501",
  );
  check(
    "forged comments rejected",
    (await rpc(
      "editor",
      "create",
      fresh("editor", { comments: [{ body: "Fake history" }] }),
    )).code,
    "22023",
  );
  check(
    "forged files rejected",
    (await rpc(
      "editor",
      "create",
      fresh("editor", { attachments: [{ id: randomUUID() }] }),
    )).code,
    "22023",
  );
  check(
    "nonzero completion revision rejected",
    (await rpc("editor", "create", fresh("editor", { completion_version: 2 })))
      .code,
    "22023",
  );
  check(
    "unknown field rejected",
    (await rpc("editor", "create", fresh("editor", { unsupported: "future" })))
      .code,
    "22023",
  );
  check(
    "viewer assignment rejected",
    (await rpc(
      "editor",
      "create",
      fresh("editor", { assigned_to: people.viewer.id }),
    )).code,
    "42501",
  );
  check(
    "outsider assignment rejected",
    (await rpc(
      "editor",
      "create",
      fresh("editor", { assigned_to: people.outsider.id }),
    )).code,
    "42501",
  );
  const rich = fresh("editor", {
    title: "Prepare design review",
    description: "Gather the draft and review contrast",
    priority: 1,
    section_id: section,
    labels: ["design"],
    reminders: ["at_due"],
    due_date: "2026-11-02",
    due_time: "09:30",
    time_zone: "Europe/Copenhagen",
    duration_minutes: 45,
    assigned_to: people.owner.id,
    subtasks: [{
      id: "outline",
      title: "Outline the review",
      assigned_to: people.owner.id,
      subtasks: [{
        id: "contrast",
        title: "Check contrast",
        assigned_to: people.editor.id,
      }],
    }],
  });
  const richReply = await success(
    "rich task with checklist and assignment created",
    "editor",
    "create",
    rich,
  );
  check(
    "nested child data preserved",
    richReply.task.subtasks[0].subtasks[0].title,
    "Check contrast",
  );
  const forgedChild = fresh("editor", {
    subtasks: [{
      id: "root",
      title: "Checklist",
      subtasks: [{
        id: "nested",
        title: "Nested",
        assigned_to: people.viewer.id,
      }],
    }],
  });
  check(
    "nested viewer assignment rejected",
    (await rpc("editor", "create", forgedChild)).code,
    "42501",
  );
  check(
    "duplicate checklist identity rejected",
    (await rpc(
      "editor",
      "create",
      fresh("editor", {
        subtasks: [{ id: "same", title: "One" }, { id: "same", title: "Two" }],
      }),
    )).code,
    "22023",
  );
  check(
    "wrong section rejected",
    (await rpc(
      "editor",
      "create",
      fresh("editor", { section_id: randomUUID() }),
    )).code,
    "PT409",
  );
  const foreignPersonal = randomUUID();
  await pg.raw(
    `insert into public.tasks(id,user_id,title) values(${
      lit(foreignPersonal)
    },${
      lit(people.editor.id)
    },'Personal original');delete from public.tasks where id=${
      lit(foreignPersonal)
    }`,
  );
  check(
    "personal deleted UUID cannot enter team",
    (await rpc("editor", "create", fresh("editor", { id: foreignPersonal })))
      .code,
    "PT409",
  );
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(people.guest.id)},'editor')`,
  );
  const guestTask = fresh("guest");
  await success(
    "explicit guest editor creates task",
    "guest",
    "create",
    guestTask,
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where user_id=${
      lit(people.guest.id)
    }`,
  );
  check(
    "former guest editor cannot replay",
    (await rpc("guest", "create", guestTask)).code,
    "42501",
  );
  const assignmentUndo = fresh("editor", { assigned_to: people.guest.id });
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(people.guest.id)},'editor')`,
  );
  await success(
    "assignment fixture created",
    "editor",
    "create",
    assignmentUndo,
  );
  const assignmentDelete = await deletion(assignmentUndo.task_id);
  await success(
    "assignment fixture deleted",
    "editor",
    "delete",
    assignmentDelete,
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where user_id=${
      lit(people.guest.id)
    }`,
  );
  const assignmentRestored = await success(
    "Undo survives recipient losing access",
    "editor",
    "restore",
    restore(assignmentDelete),
  );
  check(
    "stale assignment becomes unassigned",
    assignmentRestored.task.assigned_to,
    null,
  );
  for (const flag of ["is_archived", "ancestor_archived"]) {
    await pg.raw(
      `update public.projects set ${flag}=true where id=${lit(project)}`,
    );
    check(
      flag + " blocks creation",
      (await rpc("editor", "create", fresh())).code,
      "PT409",
    );
    await pg.raw(
      `update public.projects set ${flag}=false where id=${lit(project)}`,
    );
  }
  check(
    "string completion rejected",
    (await rpc("editor", "create", fresh("editor", { completed: "true" })))
      .code,
    "22023",
  );
  const root = fresh("author", {
    title: "Recurring root",
    is_recurring: true,
    recurrence_pattern: { type: "daily" },
  });
  await success("other author creates root", "author", "create", root);
  const child = fresh("author", {
    title: "Keep this occurrence",
    recurrence_parent_id: root.task_id,
  }, { parent_generation: root.task_generation });
  await success("same-team repeat child created", "author", "create", child);
  check(
    "parent generation required",
    (await rpc(
      "editor",
      "create",
      fresh("editor", { recurrence_parent_id: root.task_id }),
    )).code,
    "PT409",
  );
  check(
    "wrong parent generation rejected",
    (await rpc(
      "editor",
      "create",
      fresh("editor", { recurrence_parent_id: root.task_id }, {
        parent_generation: randomUUID(),
      }),
    )).code,
    "PT409",
  );
  const hiddenChild = fresh("owner", {
    title: "Private occurrence",
    project_id: privateProject,
    recurrence_parent_id: root.task_id,
  }, { project_id: privateProject, parent_generation: root.task_generation });
  await success(
    "owner creates private occurrence",
    "owner",
    "create",
    hiddenChild,
  );
  const d = await deletion(root.task_id);
  const stale = structuredClone(d);
  stale.record.title = "Stale baseline";
  check(
    "whole baseline prevents stale deletion",
    (await rpc("editor", "delete", stale)).code,
    "PT409",
  );
  check(
    "viewer cannot delete",
    (await rpc("viewer", "delete", d)).code,
    "42501",
  );
  const deleted = await success(
    "editor deletes root without creator shortcut",
    "editor",
    "delete",
    d,
  );
  native.delete = { body: d, reply: deleted };
  check("only root removed", await row(root.task_id), null);
  check(
    "occurrence retained and detached",
    (await row(child.task_id)).recurrence_parent_id,
    null,
  );
  check(
    "private occurrence retained",
    (await row(hiddenChild.task_id)).recurrence_parent_id,
    null,
  );
  check(
    "delete retry does not repeat effects",
    (await rpc("editor", "delete", d)).value.replayed,
    true,
  );
  const recreation = fresh("editor", { id: root.task_id });
  check(
    "fresh create cannot resurrect deleted ID",
    (await rpc("editor", "create", recreation)).code,
    "PT409",
  );
  const forgedRestore = restore(d);
  forgedRestore.record.title = "Forged restored title";
  check(
    "restore requires original content",
    (await rpc("editor", "restore", forgedRestore)).code,
    "PT409",
  );
  check(
    "another actor cannot restore receipt",
    (await rpc("owner", "restore", restore(d))).code,
    "PT409",
  );
  check(
    "old generation cannot be restored",
    (await rpc(
      "editor",
      "restore",
      restore(d, { task_generation: d.task_generation, record: d.record }),
    )).code,
    "PT409",
  );
  const restoredBody = restore(d),
    restored = await success(
      "verified Undo restores root",
      "editor",
      "restore",
      restoredBody,
    );
  native.restore = { body: restoredBody, reply: restored };
  check(
    "Undo keeps removed root creator",
    restored.task.user_id,
    people.author.id,
  );
  check(
    "Undo has fresh generation",
    restored.task.task_generation,
    restoredBody.task_generation,
  );
  check(
    "Undo reattaches unchanged editable occurrence",
    (await row(child.task_id)).recurrence_parent_id,
    root.task_id,
  );
  check(
    "Undo does not reattach inaccessible private occurrence",
    (await row(hiddenChild.task_id)).recurrence_parent_id,
    null,
  );
  check(
    "consumed Undo cannot resurrect again",
    (await rpc("editor", "restore", restore(d))).code,
    "PT409",
  );
  check(
    "old delete replay preserves new incarnation",
    (await rpc("editor", "delete", d)).code,
    null,
  );
  check(
    "new root remains after old retry",
    (await row(root.task_id)).task_generation,
    restoredBody.task_generation,
  );
  check(
    "Undo retry idempotent",
    (await rpc("editor", "restore", restoredBody)).value.replayed,
    true,
  );
  const d2 = await deletion(root.task_id);
  await success("delete new incarnation", "editor", "delete", d2);
  await pg.raw(
    `update public.tasks set title='A teammate changed this occurrence' where id=${
      lit(child.task_id)
    }`,
  );
  await success(
    "Undo root without overwriting changed child",
    "editor",
    "restore",
    restore(d2),
  );
  check(
    "changed occurrence stays detached",
    (await row(child.task_id)).recurrence_parent_id,
    null,
  );
  const freshDelete = await deletion(original.task_id);
  await success(
    "delete original created task",
    "editor",
    "delete",
    freshDelete,
  );
  const oldCreate = await rpc("editor", "create", original);
  check("old create retry cannot resurrect", oldCreate.value.unavailable, true);
  check("old create row stays deleted", await row(original.task_id), null);
  const noOp = { ...freshDelete, request_id: randomUUID() };
  await success(
    "second removal of same generation safe",
    "editor",
    "delete",
    noOp,
  );
  check(
    "no-op deletion cannot mint Undo",
    (await rpc("editor", "restore", restore(noOp))).code,
    "PT409",
  );
  const patchReuse = fresh("editor", {}, { request_id: original.request_id });
  check(
    "lifecycle nonce conflicts across task IDs",
    (await rpc("editor", "create", patchReuse)).code,
    "PT409",
  );
  const zeroGen = fresh();
  zeroGen.task_generation = "00000000-0000-0000-0000-000000000000";
  zeroGen.record.task_generation = zeroGen.task_generation;
  check(
    "zero incarnation rejected",
    (await rpc("editor", "create", zeroGen)).code,
    "22023",
  );
  const commentTask = fresh();
  await success(
    "conversation fixture task created",
    "editor",
    "create",
    commentTask,
  );
  await pg.raw(
    `insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body) values(${
      lit(randomUUID())
    },${lit(commentTask.task_id)},${lit(commentTask.task_generation)},${
      lit(project)
    },${lit(people.owner.id)},'Preserve this conversation')`,
  );
  check(
    process.env.TASKFOLD_TEAM_CONVERSATION_REGRESSION === "1"
      ? "conversation deletion now recoverable"
      : "conversation cascade blocked pending adapter",
    (await rpc("editor", "delete", await deletion(commentTask.task_id))).code,
    process.env.TASKFOLD_TEAM_CONVERSATION_REGRESSION === "1" ? null : "PT409",
  );
  check(
    process.env.TASKFOLD_TEAM_CONVERSATION_REGRESSION === "1"
      ? "conversation moved to recovery copy"
      : "comment remains",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.task_comments where task_id=${
        lit(commentTask.task_id)
      }`,
    ),
    process.env.TASKFOLD_TEAM_CONVERSATION_REGRESSION === "1" ? 0 : 1,
  );
  const removedAuthor = fresh("author", { title: "Author retention" });
  await success("author retention created", "author", "create", removedAuthor);
  const removeAuthorDelete = await deletion(removedAuthor.task_id);
  await success(
    "author retention deleted",
    "editor",
    "delete",
    removeAuthorDelete,
  );
  await pg.raw(`delete from auth.users where id=${lit(people.author.id)}`);
  const removedRestored = await success(
    "Undo preserves deleted account creator",
    "editor",
    "restore",
    restore(removeAuthorDelete),
  );
  check(
    "retained UUID unchanged",
    removedRestored.task.user_id,
    people.author.id,
  );
  const pendingCreate = fresh(), app = "team-life-revoke";
  let holder = await pg.hold(
    `select id from taskfold_private.teams where id=${lit(team)} for update`,
  );
  let pending = rpc("editor", "create", pendingCreate, { app });
  await pg.waitForLock(app, holder.pid);
  await holder.release(
    "commit",
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(people.editor.id)},'viewer')`,
  );
  check("revocation while waiting stops create", (await pending).code, "42501");
  check(
    "revoked creation never inserted",
    await row(pendingCreate.task_id),
    null,
  );
  check(
    "revocation also stops old replay",
    (await rpc("editor", "create", original)).code,
    "42501",
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where user_id=${
      lit(people.editor.id)
    }`,
  );
  const overlapping = await deletion(rich.task_id);
  holder = await pg.hold(
    `select id from public.tasks where id=${lit(rich.task_id)} for update`,
  );
  pending = rpc("editor", "delete", overlapping, {
    app: "team-life-delete-conflict",
  });
  await pg.waitForLock("team-life-delete-conflict", holder.pid);
  await holder.release(
    "commit",
    `update public.tasks set title='Newer reviewed design' where id=${
      lit(rich.task_id)
    }`,
  );
  check("waiting deletion catches newer task", (await pending).code, "PT409");
  check(
    "waiting deletion preserves newer text",
    (await row(rich.task_id)).title,
    "Newer reviewed design",
  );
  check(
    "scope always cleaned",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.team_task_edit_scope",
    ),
    0,
  );
  check(
    "link receipts have no task text",
    await pg.scalar(
      `select to_jsonb(not exists(select 1 from taskfold_private.team_task_deleted_links where to_jsonb(team_task_deleted_links)::text like '%occurrence%'))`,
    ),
    true,
  );
  report.advisors = await pg.advisors();
  check(
    "no additional advisor warnings",
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
