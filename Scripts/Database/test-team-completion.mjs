import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import {
  loadTeamCompletionSchema,
  teamCompletionMigration,
} from "./team-completion-schema.mjs";
if (process.env.TASKFOLD_TEAM_BATCH_RECOVERY_REGRESSION === '1') process.env.TASKFOLD_TEAM_COMPLETION_BATCH_REGRESSION = '1';
if (process.env.TASKFOLD_TEAM_COMPLETION_BATCH_REGRESSION === '1') { process.env.TASKFOLD_TEAM_REBASE_REGRESSION = '1'; process.env.TASKFOLD_TEAM_PROVISIONAL_REGRESSION = '1'; }
const report = {
  checks: {},
  deployed: false,
  realDataChanged: false,
  nativeTeamUIEnabled: false,
};
const check = (name, a, b = true) => {
  assert.deepEqual(a, b, name);
  report.checks[name] = true;
};
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
const users = Object.fromEntries(
  ["owner", "editor", "viewer", "outsider"].map(
    (n) => [n, { id: randomUUID(), session: randomUUID() }],
  ),
);
const team = randomUUID(), project = randomUUID();
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadTeamCompletionSchema(pg.raw);
  if(process.env.TASKFOLD_TEAM_COMPLETION_REVIEW_REGRESSION === '1' || (process.env.TASKFOLD_TEAM_CANCELLATION_REGRESSION === '1' || process.env.TASKFOLD_TEAM_REBASE_REGRESSION === '1')) {
    const { loadTeamCompletionReviewSchema,teamCompletionReviewMigration }=await import('./team-completion-review-schema.mjs');
    await loadTeamCompletionReviewSchema(pg.raw,{base:false});
    report.reviewMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamCompletionReviewMigration,import.meta.url))).digest('hex');
  }
  if((process.env.TASKFOLD_TEAM_CANCELLATION_REGRESSION === '1' || process.env.TASKFOLD_TEAM_REBASE_REGRESSION === '1')) {
    const {loadTeamCompletionCancellationSchema,teamCompletionCancellationMigration}=await import('./team-completion-cancellation-schema.mjs');
    await loadTeamCompletionCancellationSchema(pg.raw,{base:false});
    report.cancellationMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamCompletionCancellationMigration,import.meta.url))).digest('hex');
  }
  if(process.env.TASKFOLD_TEAM_REBASE_REGRESSION === '1') {
    const {loadTeamCompletionRebaseSchema,teamCompletionRebaseMigration}=await import('./team-completion-rebase-schema.mjs');
    await loadTeamCompletionRebaseSchema(pg.raw,{base:false});
    report.rebaseMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamCompletionRebaseMigration,import.meta.url))).digest('hex');
  }
  if(process.env.TASKFOLD_TEAM_PROVISIONAL_REGRESSION === '1') {
    if(!report.rebaseMigrationSHA256)throw new Error('Load rebase capabilities before provisional retirement regression');
    const {loadTeamProvisionalRetirementSchema,teamProvisionalRetirementMigration}=await import('./team-provisional-retirement-schema.mjs');
    await loadTeamProvisionalRetirementSchema(pg.raw,{base:false});
    report.retirementMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamProvisionalRetirementMigration,import.meta.url))).digest('hex');
  }
  if (process.env.TASKFOLD_TEAM_COMPLETION_BATCH_REGRESSION === '1') {
    const {loadTeamCompletionBatchSchema, teamCompletionBatchMigration}=await import('./team-completion-batch-schema.mjs');
    await loadTeamCompletionBatchSchema(pg.raw,{base:false});
    report.batchMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamCompletionBatchMigration,import.meta.url))).digest('hex');
  }
  if (process.env.TASKFOLD_TEAM_BATCH_RECOVERY_REGRESSION === '1') {
    const {loadTeamCompletionBatchRecoverySchema,teamCompletionBatchRecoveryMigration}=await import('./team-completion-batch-recovery-schema.mjs');
    await loadTeamCompletionBatchRecoverySchema(pg.raw,{base:false});
    report.batchRecoveryMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamCompletionBatchRecoveryMigration,import.meta.url))).digest('hex');
  }
  report.completionMigrationSHA256 = createHash("sha256").update(
    await readFile(
      new URL(
        "../../supabase/migrations/" + teamCompletionMigration,
        import.meta.url,
      ),
    ),
  ).digest("hex");
  for (const [n, u] of Object.entries(users)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${
        lit(n + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${
        lit(u.id)
      })`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(users.owner.id)
    },'Completion team');` + Object.entries(users).filter(([n]) =>
      n !== "outsider"
    ).map(([n, u]) =>
      `insert into taskfold_private.team_members(team_id,user_id,role) values(${
        lit(team)
      },${lit(u.id)},${lit(n === "owner" ? "admin" : "member")});`
    ).join(""),
  );
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${lit(project)},${
      lit(users.owner.id)
    },'Completion project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
      lit(project)
    },${
      lit(team)
    },'team');insert into taskfold_private.team_project_grants values(${
      lit(project)
    },${lit(team)},${lit(users.viewer.id)},'viewer')`,
  );
  const run = (who, expression, opts = {}) => {
    const u = users[who];
    return pg.scalar(
      `begin;set application_name=${
        lit(opts.app ?? "completion-" + randomUUID().slice(0, 8))
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
      };do $r$begin begin insert into result values((${expression}),null,null);exception when others then insert into result values(null,sqlstate,left(sqlerrm,160));end;end$r$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`,
    );
  };
  const rpc = (action, b, who = "editor", opts = {}) =>
    run(
      who,
      `public.taskfold_complete_team_task(${lit(action)},${json(b)})`,
      opts,
    );
  const row = (id) =>
    pg.scalar(
      `select coalesce((select to_jsonb(t) from public.tasks t where id=${
        lit(id)
      }),'null')`,
    );
  const create = async (extra = {}) => {
    const r = {
      id: randomUUID(),
      user_id: users.owner.id,
      project_id: project,
      title: "Recurring team task",
      description: "Shared instructions",
      task_generation: randomUUID(),
      completed: false,
      completion_version: 0,
      created_at: "2026-10-24T00:00:00Z",
      priority: 2,
      due_date: "2026-10-24",
      due_time: "09:00",
      time_zone: "Europe/Copenhagen",
      is_recurring: true,
      recurrence_pattern: { type: "daily", interval: 1, count: 3 },
      ...extra,
    };
    await pg.raw(
      `insert into public.tasks select (jsonb_populate_record(null::public.tasks,${
        json({
          labels: [],
          subtasks: [],
          comments: [],
          attachments: [],
          reminders: [],
          reminder_specs: [],
          source_metadata: {},
          ...r,
        })
      })).*`,
    );
    return row(r.id);
  };
  const body = async (source, extra = {}) => {
    const clock = extra.completed_at ?? "2026-10-24T12:00:00Z",
      zone = extra.input_zone ?? "Europe/Copenhagen";
    const plan = await pg.scalar(
      `select coalesce(taskfold_private.automation_recurrence_plan(${
        json(source)
      },${lit(clock)}::timestamptz,${lit(zone)}),'null')`,
    );
    const series = plan
        ? (source.recurrence_parent_id ?? source.id)
        : source.id,
      parent = series === source.id ? source : await row(series);
    return {
      team_id: team,
      project_id: project,
      task_id: source.id,
      task_generation: source.task_generation,
      request_id: randomUUID(),
      record: source,
      completed_at: clock,
      input_zone: zone,
      next_generation: randomUUID(),
      planned_next_id: plan?.id ?? null,
      series_id: series,
      series_generation: parent.task_generation,
      series_project_id: parent.project_id,
      ...extra,
    };
  };
  const ok = (name, result) => {
    check(name, { code: result.code, reason: result.reason }, {
      code: null,
      reason: null,
    });
    return result.value;
  };
  const reject = async (
    name,
    action,
    b,
    code = "PT409",
    who = "editor",
    opts = {},
  ) => {
    const before = await row(b.task_id);
    check(name, (await rpc(action, b, who, opts)).code, code);
    check(name + " preserves source", await row(b.task_id), before);
  };
  const source = await create({
    attachments: [{
      id: "original-file",
      url: "https://files.example.invalid/instructions",
    }],
    comments: [{ body: "Original occurrence discussion" }],
    source_metadata: { future: { keep: true } },
    subtasks: [{
      id: "nested",
      title: "Nested review",
      completed: true,
      completed_at: "2026-10-01T08:00:00Z",
      subtasks: [],
      taskfold_completion_v1: { epoch: randomUUID(), version: 3 },
      attachments: [{ id: "nested-file" }],
      comments: [{ body: "Previous nested discussion" }],
      future_state: { keep: true },
      reminder_specs: [{
        id: randomUUID(),
        version: 99,
        kind: "private-device-setting",
        opaque: { keep: true },
      }],
    }],
  });
  const b = await body(source);
  await reject("completion defaults closed", "complete", b, "PT503");
  await pg.raw(
    "update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true",
  );
  await reject("viewer cannot complete", "complete", b, "42501", "viewer");
  await reject("outsider cannot complete", "complete", b, "42501", "outsider");
  for (const role of ["anon", "service_role"]) {
    await reject(
      role + " cannot call native completion",
      "complete",
      b,
      "42501",
      "editor",
      { role },
    );
  }
  await reject("expired session rejected", "complete", b, "28000", "editor", {
    session: randomUUID(),
  });
  const forged = structuredClone(b);
  forged.record.attachments = [{ url: "https://forged.example.invalid/file" }];
  await reject(
    "source attachment baseline cannot be forged",
    "complete",
    forged,
  );
  const author = structuredClone(b);
  author.record.user_id = users.editor.id;
  await reject("source creator baseline cannot be forged", "complete", author);
  await reject("successor ID cannot be chosen by caller", "complete", {
    ...b,
    planned_next_id: randomUUID(),
  });
  await reject("series generation cannot be rebound", "complete", {
    ...b,
    series_generation: randomUUID(),
  });
  await reject("unknown command fields rejected", "complete", {
    ...b,
    admin: true,
  }, "22023");
  await reject(
    "forged role metadata does not grant writes",
    "complete",
    b,
    "42501",
    "viewer",
    {
      claims: {
        user_metadata: { role: "owner" },
        app_metadata: { role: "owner" },
      },
    },
  );
  const noopID = randomUUID();
  ok(
    "shared nonce setup",
    await run(
      "editor",
      `public.taskfold_edit_team_task(${
        json({
          team_id: team,
          project_id: project,
          task_id: source.id,
          task_generation: source.task_generation,
          request_id: noopID,
          base: {
            project_id: project,
            task_generation: source.task_generation,
            title: source.title,
          },
          changes: { title: source.title },
        })
      })`,
    ),
  );
  await reject("completion cannot reuse ordinary edit nonce", "complete", {
    ...b,
    request_id: noopID,
  });
  const complete = ok(
    "completion creates next occurrence atomically",
    await rpc("complete", b),
  );
  check("source completed", complete.task.completed, true);
  check("source revision advanced", complete.task.completion_version, 1);
  check("successor created", complete.created_successor, true);
  check("successor identity", complete.successor.id, b.planned_next_id);
  check(
    "successor generation",
    complete.successor.task_generation,
    b.next_generation,
  );
  check(
    "successor creator is actor",
    complete.successor.user_id,
    users.editor.id,
  );
  check("original creator preserved", complete.task.user_id, users.owner.id);
  check(
    "shared file reference carried",
    complete.successor.attachments,
    source.attachments,
  );
  check(
    "source metadata preserved",
    complete.successor.source_metadata.future,
    source.source_metadata.future,
  );
  check(
    "new occurrence has no old discussion",
    complete.successor.comments,
    [],
  );
  check("nested discussion reset", complete.successor.subtasks[0].comments, []);
  check(
    "nested file carried",
    complete.successor.subtasks[0].attachments,
    source.subtasks[0].attachments,
  );
  check(
    "private reminder carried",
    complete.successor.subtasks[0].reminder_specs,
    source.subtasks[0].reminder_specs,
  );
  check(
    "nested completion reset",
    complete.successor.subtasks[0].taskfold_completion_v1.version,
    0,
  );
  check(
    "nested completion new epoch",
    complete.successor.subtasks[0].taskfold_completion_v1.epoch !==
      source.subtasks[0].taskfold_completion_v1.epoch,
  );
  check(
    "repeat count decremented",
    complete.successor.recurrence_pattern.count,
    2,
  );
  const fixture = { account: users.editor.id, body: b, reply: complete };
  const retry = ok(
    "lost completion response retries",
    await rpc("complete", b),
  );
  check("completion replay marked", retry.replayed, true);
  check(
    "completion replay same successor",
    retry.successor_generation,
    b.next_generation,
  );
  await reject(
    "different actor cannot reuse nonce",
    "complete",
    b,
    "PT409",
    "owner",
  );
  await reject("nonce payload cannot change", "complete", {
    ...b,
    completed_at: "2026-10-24T13:00:00Z",
  });
  await reject("stale second completion conflicts", "complete", {
    ...b,
    request_id: randomUUID(),
  });
  const undo = { ...b, request_id: randomUUID(), undoes: b.request_id };
  const undone = ok(
    "Undo removes only owned unchanged occurrence",
    await rpc("undo", undo),
  );
  fixture.undo_body = undo;
  fixture.undo_reply = undone;
  check("Undo reopens source", undone.task.completed, false);
  check("Undo root revision", undone.task.completion_version, 2);
  check("Undo removes owned successor", undone.removed_successor, true);
  check("Undo successor gone", await row(b.planned_next_id), null);
  check(
    "Undo replay",
    ok("Undo retries", await rpc("undo", undo)).replayed,
    true,
  );
  check(
    "old completion cannot recreate after Undo",
    ok("old completion acknowledged after Undo", await rpc("complete", b))
      .successor,
    null,
  );
  const redo = await body(await row(source.id), { redo_of: undo.request_id });
  const redone = ok(
    "Redo recreates own removed occurrence",
    await rpc("complete", redo),
  );
  fixture.redo_body = redo;
  fixture.redo_reply = redone;
  check(
    "Redo uses fresh generation",
    redone.successor_generation !== b.next_generation,
  );
  check("Redo root revision", redone.task.completion_version, 3);
  await reject("old Undo cannot run again", "undo", {
    ...undo,
    request_id: randomUUID(),
  });
  await pg.raw(
    `update public.tasks set title='A collaborator edited the occurrence' where id=${
      lit(redone.successor_id)
    }`,
  );
  const keepUndo = {
    ...redo,
    request_id: randomUUID(),
    undoes: redo.request_id,
  };
  delete keepUndo.redo_of;
  const kept = ok("Undo keeps edited successor", await rpc("undo", keepUndo));
  fixture.kept_body = keepUndo;
  fixture.kept_reply = kept;
  check(
    "edited successor preserved",
    kept.successor.title,
    "A collaborator edited the occurrence",
  );
  check("edited successor not deleted", kept.removed_successor, false);
  check("source still reopened", kept.task.completed, false);
  // Existing occurrences, including legacy IDs, belong to their existing creator.
  const existingSource = await create(),
    existingBody = await body(existingSource),
    legacy = await create({
      recurrence_parent_id: existingSource.id,
      due_date: "2026-10-25",
      title: "Existing occurrence",
    });
  const existing = ok(
    "existing occurrence reused",
    await rpc("complete", existingBody),
  );
  check("existing successor not claimed", existing.created_successor, false);
  check("legacy successor identity retained", existing.successor_id, legacy.id);
  check("existing author retained", existing.successor.user_id, users.owner.id);
  const existingUndo = {
    ...existingBody,
    request_id: randomUUID(),
    undoes: existingBody.request_id,
  };
  check(
    "Undo never deletes preexisting occurrence",
    ok("existing occurrence Undo", await rpc("undo", existingUndo))
      .removed_successor,
    false,
  );
  const removedSource = await create(), removedBody = await body(removedSource);
  ok("removed occurrence setup", await rpc("complete", removedBody));
  await pg.raw(
    `update public.tasks set completed=false,completed_at=null where id=${
      lit(removedSource.id)
    };delete from public.tasks where id=${lit(removedBody.planned_next_id)}`,
  );
  const noRestore = ok(
    "ordinary completion does not resurrect deletion",
    await rpc("complete", await body(await row(removedSource.id))),
  );
  check(
    "deliberately removed occurrence stays gone",
    noRestore.successor,
    null,
  );
  check("deliberate deletion not claimed", noRestore.created_successor, false);
  const commentSource = await create(), commentBody = await body(commentSource);
  const commentNext = ok(
    "discussion preservation setup",
    await rpc("complete", commentBody),
  );
  await pg.raw(
    `insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body) values(${
      lit(randomUUID())
    },${lit(commentNext.successor_id)},${
      lit(commentNext.successor_generation)
    },${lit(project)},${lit(users.owner.id)},'New discussion')`,
  );
  const commentUndo = {
    ...commentBody,
    request_id: randomUUID(),
    undoes: commentBody.request_id,
  };
  check(
    "Undo preserves new shared discussion",
    ok("discussion-preserving Undo", await rpc("undo", commentUndo)).successor
      .id,
    commentNext.successor_id,
  );
  const abaSource = await create(),
    abaBody = await body(abaSource),
    aba = ok("edit cycle setup", await rpc("complete", abaBody));
  const originalNext = aba.successor;
  await pg.raw(
    `update public.tasks set title='Temporary collaborator edit' where id=${
      lit(aba.successor_id)
    };update public.tasks set title=${lit(originalNext.title)} where id=${
      lit(aba.successor_id)
    }`,
  );
  check(
    "edit cycle returns identical visible task",
    await row(aba.successor_id),
    originalNext,
  );
  const abaUndo = {
    ...abaBody,
    request_id: randomUUID(),
    undoes: abaBody.request_id,
  };
  check(
    "Undo preserves edit and revert activity",
    ok("edit cycle Undo", await rpc("undo", abaUndo)).removed_successor,
    false,
  );
  // Force a root-update failure after insertion; all rows, scopes and receipts roll back.
  const failedSource = await create(), failed = await body(failedSource);
  await pg.raw(
    `create function public.fixture_fail_completion() returns trigger language plpgsql as $$begin if new.id=${
      lit(failedSource.id)
    }::uuid and new.completed then raise exception 'Synthetic completion interruption';end if;return new;end$$;create trigger fixture_fail_completion after update on public.tasks for each row execute function public.fixture_fail_completion()`,
  );
  await reject("atomic root failure", "complete", failed, "P0001");
  check(
    "failed completion has no successor",
    await row(failed.planned_next_id),
    null,
  );
  check(
    "failed completion has no receipt",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_task_edits where team_id=${
        lit(team)
      } and request_id=${lit(failed.request_id)}`,
    ),
    0,
  );
  check(
    "failed generation insertion rolled back",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.task_generations where task_id=${
        lit(failed.planned_next_id)
      }`,
    ),
    0,
  );
  await pg.raw(
    "drop trigger fixture_fail_completion on public.tasks;drop function public.fixture_fail_completion()",
  );
  const failedComplete = ok(
    "exact interrupted completion retries",
    await rpc("complete", failed),
  );
  const failUndo = {
    ...failed,
    request_id: randomUUID(),
    undoes: failed.request_id,
  };
  await pg.raw(
    `create function public.fixture_fail_undo() returns trigger language plpgsql as $$begin if new.id=${
      lit(failedSource.id)
    }::uuid and not new.completed then raise exception 'Synthetic Undo interruption';end if;return new;end$$;create trigger fixture_fail_undo after update on public.tasks for each row execute function public.fixture_fail_undo()`,
  );
  await reject("atomic Undo failure", "undo", failUndo, "P0001");
  check(
    "failed Undo retains successor",
    (await row(failed.planned_next_id))?.task_generation,
    failed.next_generation,
  );
  check(
    "failed Undo does not consume completion",
    await pg.scalar(
      `select to_jsonb(undone_by is null) from taskfold_private.team_task_completions where team_id=${
        lit(team)
      } and request_id=${lit(failed.request_id)}`,
    ),
    true,
  );
  await pg.raw(
    "drop trigger fixture_fail_undo on public.tasks;drop function public.fixture_fail_undo()",
  );
  ok("exact interrupted Undo retries", await rpc("undo", failUndo));
  const invalidRedo = await body(await row(failedSource.id), {
    redo_of: failUndo.request_id,
    next_generation: failed.next_generation,
  });
  await reject("Redo cannot reuse deleted generation", "complete", invalidRedo);
  const beforeLaterDelete = await row(failedSource.id);
  const noopDelete = {
    team_id: team,
    project_id: project,
    task_id: failed.planned_next_id,
    task_generation: failed.next_generation,
    request_id: randomUUID(),
    record: failedComplete.successor,
  };
  ok(
    "later deletion records its intent",
    await run(
      "owner",
      `public.taskfold_team_task_lifecycle('delete',${json(noopDelete)})`,
    ),
  );
  const olderRedo = await body(beforeLaterDelete, {
    redo_of: failUndo.request_id,
  });
  await reject(
    "older Redo cannot override a later deletion",
    "complete",
    olderRedo,
  );
  const finalSource = await create({
    recurrence_pattern: { type: "daily", interval: 1, count: 1 },
  });
  const finalBody = await body(finalSource);
  check("ended series has no next ID", finalBody.planned_next_id, null);
  check(
    "last occurrence completes without creation",
    ok("last occurrence completion", await rpc("complete", finalBody))
      .successor,
    null,
  );
  const monthlySource = await create({
    due_date: "2027-01-31",
    recurrence_pattern: { type: "monthly", interval: 1, count: 3 },
  });
  const monthly = ok(
    "monthly short-month completion",
    await rpc(
      "complete",
      await body(monthlySource, { completed_at: "2027-01-31T12:00:00Z" }),
    ),
  );
  check("month clamps to February", monthly.successor.due_date, "2027-02-28");
  check(
    "requested calendar day retained",
    monthly.successor.recurrence_pattern.dayOfMonth,
    31,
  );
  const waitingSource = await create(), waiting = await body(waitingSource);
  let hold = await pg.hold(
    `select id from taskfold_private.teams where id=${lit(team)} for update`,
  );
  let pending = rpc("complete", waiting, "editor", {
    app: "completion-permission-wait",
  });
  await pg.waitForLock("completion-permission-wait", hold.pid);
  await hold.release(
    "commit",
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(users.editor.id)},'viewer')`,
  );
  check(
    "permission loss during wait denies completion",
    (await pending).code,
    "42501",
  );
  check(
    "permission loss leaves source open",
    (await row(waitingSource.id)).completed,
    false,
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where project_id=${
      lit(project)
    } and user_id=${lit(users.editor.id)}`,
  );
  hold = await pg.hold(
    `select id from public.tasks where id=${lit(waitingSource.id)} for update`,
  );
  pending = rpc("complete", waiting, "editor", {
    app: "completion-content-wait",
  });
  await pg.waitForLock("completion-content-wait", hold.pid);
  await hold.release(
    "commit",
    `update public.tasks set title='Newer source title' where id=${
      lit(waitingSource.id)
    }`,
  );
  check(
    "source edit while waiting denies stale clone",
    (await pending).code,
    "PT409",
  );
  const series = await create({
      id: "00000000-0000-4000-8000-000000000100",
      due_date: "2026-10-23",
    }),
    one = await create({ recurrence_parent_id: series.id }),
    two = await create({ recurrence_parent_id: series.id });
  const oneBody = await body(one), twoBody = await body(two);
  check(
    "converging sources plan same successor",
    oneBody.planned_next_id,
    twoBody.planned_next_id,
  );
  hold = await pg.hold(
    `select pg_advisory_xact_lock(hashtextextended(${lit(series.id)},78137))`,
  );
  const pa = rpc("complete", oneBody, "editor", {
      app: "completion-converge-one",
    }),
    pb = rpc("complete", twoBody, "owner", { app: "completion-converge-two" });
  await pg.waitForLock("completion-converge-one", hold.pid);
  await pg.waitForLock("completion-converge-two", hold.pid);
  await hold.release();
  const results = await Promise.all([pa, pb]);
  results.forEach((r, i) => ok("concurrent converged completion " + i, r));
  check(
    "exactly one concurrent creator",
    results.filter((r) => r.value.created_successor).length,
    1,
  );
  check(
    "converging successor is shared",
    results[0].value.successor_generation,
    results[1].value.successor_generation,
  );
  check(
    "one persisted converged occurrence",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.tasks where recurrence_parent_id=${
        lit(series.id)
      } and due_date='2026-10-25'`,
    ),
    1,
  );
  check(
    "private completion receipt RLS",
    await pg.scalar(
      "select to_jsonb(relrowsecurity) from pg_class where oid='taskfold_private.team_task_completions'::regclass",
    ),
    true,
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    check(
      role + " cannot read completion receipts",
      await pg.scalar(
        `select to_jsonb(has_table_privilege(${
          lit(role)
        },'taskfold_private.team_task_completions','SELECT'))`,
      ),
      false,
    );
  }
  check(
    "completion scopes cleaned",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.team_task_edit_scope",
    ),
    0,
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    check(
      role + " cannot read durable task revisions",
      await pg.scalar(
        `select to_jsonb(has_table_privilege(${
          lit(role)
        },'taskfold_private.team_task_write_epochs','SELECT'))`,
      ),
      false,
    );
  }
  if (process.env.TASKFOLD_TEAM_COMPLETION_BATCH_REGRESSION === '1') {
    const {completionBatchChecks}=await import('./team-completion-batch-checks.mjs');
    report.batchFixture=await completionBatchChecks({pg,lit,json,check,run,rpc,row,create,body,users,team,project});
  }
  if (process.env.TASKFOLD_TEAM_BATCH_RECOVERY_REGRESSION === '1') {
    const {completionBatchRecoveryChecks}=await import('./team-completion-batch-recovery-checks.mjs');
    report.batchRecoveryFixture=await completionBatchRecoveryChecks({pg,lit,json,check,run,rpc,row,create,body,users,team,project});
  }
  await pg.raw(`delete from auth.users where id=${lit(users.editor.id)}`);
  check(
    "departed actor completion receipts erased",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_task_completions c join taskfold_private.team_task_edits e using(team_id,request_id) where e.actor_id=${
        lit(users.editor.id)
      }`,
    ),
    0,
  );
  await pg.raw(
    `update taskfold_private.teams set state='deleted',name=null,owner_id=null where id=${
      lit(team)
    }`,
  );
  check(
    "team deletion purges completion receipts",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_task_completions where team_id=${
        lit(team)
      }`,
    ),
    0,
  );
  check(
    "team deletion purges durable task revisions",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_task_write_epochs where team_id=${
        lit(team)
      }`,
    ),
    0,
  );
  if (process.env.TASKFOLD_TEAM_COMPLETION_BATCH_REGRESSION === '1') {
    check('completion batch actor/team cascade removed group receipts',await pg.scalar("select to_jsonb(count(*)) from taskfold_private.team_task_batches where operation in('complete','undo_complete')"),0);
    check('completion batch private scopes remain empty',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_completion_batch_scope'),0);
  }
  if (process.env.TASKFOLD_TEAM_BATCH_RECOVERY_REGRESSION === '1') check('completion group cancellations removed after actor/team deletion',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_completion_batch_cancellations'),0);
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
    await writeFile(process.argv[3], JSON.stringify(fixture, null, 2) + "\n");
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
