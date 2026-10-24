import { createHash, randomUUID } from "node:crypto";
import { literal as lit } from "./postgres-fixture.mjs";
const json = (x) => lit(JSON.stringify(x)) + "::jsonb",
  key = "taskfold_completion_v1";
const index = (tree) =>
  Object.fromEntries(
    tree.flatMap(
      (n) => [[n.id, n], ...Object.entries(index(n.subtasks ?? []))],
    ),
  );
const token = () => ({ epoch: randomUUID(), version: 0 });
function preparing(tree, before) {
  const old = index(before);
  const walk = (rows) =>
    rows.map((n) => {
      const b = old[n.id],
        changed = b && (b.completed ?? false) !== (n.completed ?? false);
      const t = b?.[key]
        ? { ...b[key], version: b[key].version + (changed ? 1 : 0) }
        : n[key]?.version === 0 && !b
        ? n[key]
        : { ...token(), version: changed ? 1 : 0 };
      return {
        ...n,
        [key]: t,
        ...(n.subtasks ? { subtasks: walk(n.subtasks) } : {}),
      };
    });
  return walk(tree);
}
function freshEpoch(request, id) {
  const h = createHash("sha256").update(
    "com.taskfold.recurrence.v1|team-checklist:" + request + "|" + id,
  ).digest("hex");
  return h.slice(0, 8) + "-" + h.slice(8, 12) + "-5" + h.slice(13, 16) + "-a" +
    h.slice(17, 20) + "-" + h.slice(20, 32);
}
export async function checkTeamChecklist(
  { pg, check, rpc, run, row, body, people, team, project, task },
) {
  const a = {
    id: "parent-check",
    title: "Checklist parent",
    completed: false,
    subtasks: [],
    [key]: token(),
  };
  const b = {
    id: "child-check",
    title: "Keep original history",
    completed: true,
    completed_at: "2026-10-01T09:00:00+00:00",
    subtasks: [],
    [key]: token(),
    comments: [{ id: "legacy-comment", text: "Original discussion" }],
    attachments: [{
      id: "legacy-file",
      url: "https://files.example.invalid/original",
    }],
    source_metadata: { legacy: "original" },
    future_state: { keep: true },
    reminder_specs: [{
      id: randomUUID(),
      version: 99,
      kind: "private-device-setting",
      opaque: { keep: true },
    }, {
      id: randomUUID(),
      version: 1,
      kind: "relative",
      anchor: "planned",
      offset_minutes: -15,
      channels: ["local"],
      future_choice: { keep: true },
    }],
  };
  a.subtasks = [b];
  await pg.raw(
    `update public.tasks set subtasks=${json([a])} where id=${lit(task)}`,
  );
  const make = async (tree, extra = {}) => {
    const current = await row();
    const result = {
      ...await body({ subtasks: preparing(tree, current.subtasks) }),
      ...extra,
    };
    if (extra.checklist_restore_from) {
      const previous = index(current.subtasks);
      for (const node of Object.values(index(result.changes.subtasks))) {
        if (!previous[node.id]) {
          node[key] = {
            epoch: freshEpoch(result.request_id, node.id),
            version: 0,
          };
        }
      }
    }
    return result;
  };
  const tree = async () => structuredClone((await row()).subtasks);
  const denied = async (name, b, code = "22023", who = "editor") => {
    const before = await row();
    check("checklist " + name, (await rpc(who, b)).code, code);
    check("checklist " + name + " leaves task intact", await row(), before);
  };
  let desired = await tree();
  desired[0].title = "Reviewed checklist";
  desired[0].subtasks[0].completed = false;
  desired[0].subtasks[0].completed_at = null;
  desired.push({
    id: "next-check",
    title: "Next step",
    completed: false,
    subtasks: [],
    [key]: token(),
  });
  const draft = await make(desired),
    before = await row(),
    reply = await rpc("editor", draft);
  check("checklist native edit accepted", reply.code, null);
  check(
    "checklist parent renamed",
    reply.value?.task.subtasks[0].title,
    "Reviewed checklist",
  );
  check(
    "checklist child reopened",
    reply.value?.task.subtasks[0].subtasks[0].completed,
    false,
  );
  check(
    "checklist child completion revision",
    reply.value?.task.subtasks[0].subtasks[0][key].version,
    1,
  );
  check(
    "checklist original comment retained",
    reply.value?.task.subtasks[0].subtasks[0].comments,
    b.comments,
  );
  check(
    "checklist original attachment retained",
    reply.value?.task.subtasks[0].subtasks[0].attachments,
    b.attachments,
  );
  const fixture = {
    body: draft,
    reply: reply.value,
    before,
    account: people.editor.id,
  };
  let current = await tree();
  current[0].title = "Newer parent";
  check(
    "checklist later parent edit",
    (await rpc("editor", await make(current))).code,
    null,
  );
  const replay = await rpc("editor", draft);
  check("checklist prior action is replay", replay.value?.replayed, true);
  check(
    "checklist retry preserves newer content",
    replay.value?.task.subtasks[0].title,
    "Newer parent",
  );
  // Changes to different existing nodes merge; competing structure changes require review.
  const concurrent = await make(
    (await tree()).map((n) =>
      n.id === a.id ? { ...n, title: "Local parent" } : n
    ),
  );
  current = await tree();
  current[1].title = "Remote next";
  check(
    "checklist independent remote edit",
    (await rpc("editor", await make(current))).code,
    null,
  );
  const merged = await rpc("editor", concurrent);
  check("checklist independent merge accepted", merged.code, null);
  check(
    "checklist independent remote retained",
    merged.value?.task.subtasks[1].title,
    "Remote next",
  );
  const layoutDraft = await make((await tree()).slice().reverse());
  current = await tree();
  current.push({
    id: "remote-added",
    title: "Remote added",
    completed: false,
    subtasks: [],
    [key]: token(),
  });
  check(
    "checklist remote layout edit",
    (await rpc("editor", await make(current))).code,
    null,
  );
  await denied("competing layout conflicts", layoutDraft, "P0001");
  const delayedTree = await tree();
  delayedTree[0].subtasks[0].completed = true;
  delayedTree[0].subtasks[0].completed_at = "2026-10-24T00:00:00Z";
  const delayedBeforeDeletion = await make(delayedTree);
  const oldTextTree = await tree();
  oldTextTree[0].subtasks[0].title = "Delayed old text";
  const delayedText = await make(oldTextTree);
  const oldDeleteTree = await tree();
  oldDeleteTree[0].subtasks = [];
  const delayedDelete = await make(oldDeleteTree);
  // Delete one rich nested node, then certify its original history through Undo.
  current = await tree();
  const originalChild = current[0].subtasks[0];
  current[0].subtasks = [];
  const deletion = await make(current);
  check("checklist nested delete", (await rpc("editor", deletion)).code, null);
  const privateRow = await pg.scalar(
    `select to_jsonb(d) from taskfold_private.team_checklist_deleted_nodes d where task_id=${
      lit(task)
    } and node_id=${lit(b.id)}`,
  );
  check(
    "checklist recovery has no discussion plaintext",
    JSON.stringify(privateRow).includes("Original discussion"),
    false,
  );
  check(
    "checklist recovery has no attachment URL",
    JSON.stringify(privateRow).includes("files.example.invalid"),
    false,
  );
  const restoring = async (extra = {}) => {
    const t = await tree();
    const restored = { ...structuredClone(originalChild), [key]: token() };
    t[0].subtasks = [restored];
    return make(t, { checklist_restore_from: deletion.request_id, ...extra });
  };
  const without = await restoring();
  delete without.checklist_restore_from;
  await denied("deleted identity needs receipt", without, "PT409");
  await denied(
    "wrong restoration receipt",
    await restoring({ checklist_restore_from: randomUUID() }),
    "PT409",
  );
  await denied(
    "another actor cannot restore receipt",
    await restoring(),
    "PT409",
    "owner",
  );
  const forged = await restoring();
  forged.changes.subtasks[0].subtasks[0].comments = [{
    id: "forged",
    text: "Forged history",
  }];
  await denied("recovery cannot forge comments", forged, "PT409");
  const forgedReminder = await restoring();
  forgedReminder.changes.subtasks[0].subtasks[0].reminder_specs[0].opaque = {
    keep: false,
  };
  await denied(
    "recovery cannot forge private reminders",
    forgedReminder,
    "PT409",
  );
  const oldEpoch = await restoring();
  oldEpoch.changes.subtasks[0].subtasks[0][key] = {
    ...structuredClone(originalChild)[key],
    version: 0,
  };
  await denied("recovery requires fresh completion epoch", oldEpoch, "PT409");
  const undo = await restoring(), restored = await rpc("editor", undo);
  check("checklist rich node restored", restored.code, null);
  const restoredChild = restored.value?.task.subtasks[0].subtasks[0];
  check(
    "checklist restored comment exact",
    restoredChild?.comments,
    originalChild.comments,
  );
  check(
    "checklist restored attachment exact",
    restoredChild?.attachments,
    originalChild.attachments,
  );
  check(
    "checklist restored unknown fields",
    restoredChild?.future_state,
    originalChild.future_state,
  );
  check(
    "checklist recovery uses new completion epoch",
    restoredChild?.[key].epoch !== originalChild[key].epoch,
    true,
  );
  check(
    "checklist recorded recovery consumed",
    await pg.scalar(
      `select to_jsonb(restored_request=${
        lit(undo.request_id)
      }::uuid) from taskfold_private.team_checklist_deleted_nodes where task_id=${
        lit(task)
      } and node_id=${lit(b.id)}`,
    ),
    true,
  );
  await denied(
    "old completion cannot target restored item",
    delayedBeforeDeletion,
    "PT409",
  );
  await denied(
    "old text edit cannot target restored item",
    delayedText,
    "PT409",
  );
  await denied(
    "old delete cannot target restored item",
    delayedDelete,
    "PT409",
  );
  fixture.recovery_body = undo;
  fixture.recovery_reply = restored.value;
  check(
    "checklist recovery preserves private and portable reminders",
    restoredChild?.reminder_specs,
    originalChild.reminder_specs,
  );
  // A second delete owns its tombstone; the first Undo can never resurrect it.
  current = await tree();
  current[0].subtasks = [];
  const secondDelete = await make(current);
  check(
    "checklist second delete",
    (await rpc("editor", secondDelete)).code,
    null,
  );
  await denied(
    "old Undo cannot cross later deletion",
    await restoring(),
    "PT409",
  );
  const latestRestore = await restoring({
    checklist_restore_from: secondDelete.request_id,
  });
  check(
    "checklist latest Undo restores",
    (await rpc("editor", latestRestore)).code,
    null,
  );
  // Completion incarnation/revision detects a complete/reopen ABA cycle.
  current = await tree();
  current[0].subtasks[0].completed = true;
  current[0].subtasks[0].completed_at = "2026-10-24T00:00:00Z";
  const stale = await make(current);
  check("checklist complete child", (await rpc("editor", stale)).code, null);
  current = await tree();
  current[0].subtasks[0].completed = false;
  current[0].subtasks[0].completed_at = null;
  check(
    "checklist reopen child",
    (await rpc("editor", await make(current))).code,
    null,
  );
  stale.request_id = randomUUID();
  await denied("ABA completion needs review", stale, "PT409");
  // Offline next completion may carry the optimistic timestamp from its predecessor.
  current = await tree();
  current[0].subtasks[0].completed = true;
  current[0].subtasks[0].completed_at = "2026-10-24T01:00:00Z";
  const complete = await make(current);
  const accepted = await rpc("editor", complete);
  check("checklist server stamps completion", accepted.code, null);
  const optimistic = complete.changes.subtasks;
  const offline = structuredClone(optimistic);
  offline[0].subtasks[0].completed = false;
  offline[0].subtasks[0].completed_at = null;
  const queued = await body({ subtasks: preparing(offline, optimistic) });
  queued.base.subtasks = optimistic;
  check(
    "checklist queued optimistic completion timestamp normalized",
    (await rpc("editor", queued)).code,
    null,
  );
  const edit = await make(await tree());
  edit.changes.subtasks[0].subtasks[0].future_state = { keep: false };
  await denied("existing opaque metadata cannot be rewritten", edit);
  const stamp = await make(await tree());
  stamp.changes.subtasks[0].subtasks[0].completed_at = "2020-01-01T00:00:00Z";
  await denied("completion history cannot be forged", stamp);
  const counter = await make(await tree());
  counter.changes.subtasks[0].subtasks[0][key].version += 10;
  await denied("completion counter cannot jump", counter, "PT409");
  const assigned = await make(await tree());
  assigned.changes.subtasks[0].subtasks[0].assigned_to = people.viewer.id;
  await denied("viewer cannot receive nested assignment", assigned, "42501");
  const malformed = await body({ subtasks: null });
  await denied("null tree rejected", malformed);
  const duplicate = await make(await tree());
  duplicate.changes.subtasks.push(
    structuredClone(duplicate.changes.subtasks[0]),
  );
  await denied("duplicate node ID rejected", duplicate);
  const enormous = await body({
    subtasks: Array.from(
      { length: 1001 },
      (_, i) => ({ id: "node-" + i, title: "Bounded" }),
    ),
  });
  await denied("too many nodes rejected", enormous);
  const deeply = () => {
    let result = [];
    for (let i = 0; i < 25; i++) {
      result = [{
        id: "depth-" + i,
        title: "Deep",
        subtasks: result,
        [key]: token(),
      }];
    }
    return result;
  };
  await denied("excessive depth rejected", await body({ subtasks: deeply() }));
  const optimisticTree = await tree();
  optimisticTree[0].subtasks[0].completed = true;
  optimisticTree[0].subtasks[0].completed_at = "2026-10-24T02:00:00Z";
  const optimisticComplete = await make(optimisticTree),
    serverComplete = await rpc("editor", optimisticComplete);
  check("checklist completed recovery setup", serverComplete.code, null);
  const serverStamp =
    serverComplete.value.task.subtasks[0].subtasks[0].completed_at;
  current = await tree();
  current[0].subtasks = [];
  const completedDelete = await make(current);
  check(
    "checklist completed node deletion",
    (await rpc("editor", completedDelete)).code,
    null,
  );
  current = await tree();
  current[0].subtasks = [{
    ...optimisticComplete.changes.subtasks[0].subtasks[0],
    [key]: token(),
  }];
  const completedUndo = await make(current, {
    checklist_restore_from: completedDelete.request_id,
  });
  const completedUndoReply = await rpc("editor", completedUndo);
  check("checklist completed node recovery", completedUndoReply.code, null);
  check(
    "checklist recovery retains server completion stamp",
    completedUndoReply.value?.task.subtasks[0].subtasks[0].completed_at,
    serverStamp,
  );
  // A later task write error must roll back private deletion recovery and receipt.
  current = await tree();
  current[0].subtasks = [];
  const failing = await make(current),
    ledgerBefore = await pg.scalar(
      `select coalesce(jsonb_agg(to_jsonb(d) order by node_id),'[]') from taskfold_private.team_checklist_deleted_nodes d where task_id=${
        lit(task)
      }`,
    );
  await pg.raw(
    `create function public.fixture_fail_checklist() returns trigger language plpgsql as $$begin if new.id=${
      lit(task)
    }::uuid then raise exception 'Synthetic checklist failure';end if;return new;end$$;create trigger fixture_fail_checklist after update on public.tasks for each row execute function public.fixture_fail_checklist()`,
  );
  await denied("write failure rolls back task", failing, "P0001");
  check(
    "checklist write failure rolls back tombstone",
    await pg.scalar(
      `select coalesce(jsonb_agg(to_jsonb(d) order by node_id),'[]') from taskfold_private.team_checklist_deleted_nodes d where task_id=${
        lit(task)
      }`,
    ),
    ledgerBefore,
  );
  check(
    "checklist failed request has no receipt",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_task_edits where team_id=${
        lit(team)
      } and request_id=${lit(failing.request_id)}`,
    ),
    0,
  );
  await pg.raw(
    "drop trigger fixture_fail_checklist on public.tasks;drop function public.fixture_fail_checklist()",
  );
  check(
    "checklist exact failed request retries",
    (await rpc("editor", failing)).code,
    null,
  );
  check(
    "checklist scopes cleaned",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.team_task_edit_scope",
    ),
    0,
  );
  check(
    "checklist private ledger has RLS",
    await pg.scalar(
      "select to_jsonb(relrowsecurity) from pg_class where oid='taskfold_private.team_checklist_deleted_nodes'::regclass",
    ),
    true,
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    check(
      "checklist " + role + " cannot read recovery",
      await pg.scalar(
        `select to_jsonb(has_table_privilege(${
          lit(role)
        },'taskfold_private.team_checklist_deleted_nodes','SELECT'))`,
      ),
      false,
    );
  }
  const whole = {
    ...await row(),
    id: randomUUID(),
    task_generation: randomUUID(),
  };
  whole.subtasks = [{ ...b, [key]: { epoch: randomUUID(), version: 3 } }];
  await pg.raw(
    `insert into public.tasks select (jsonb_populate_record(null::public.tasks,${
      json(whole)
    })).*`,
  );
  const rootBefore = await pg.scalar(
    `select to_jsonb(t) from public.tasks t where id=${lit(whole.id)}`,
  );
  const rootDelete = {
    team_id: team,
    project_id: project,
    task_id: whole.id,
    task_generation: whole.task_generation,
    request_id: randomUUID(),
    record: rootBefore,
  };
  check(
    "checklist whole task delete with nested history",
    (await run(
      "editor",
      `public.taskfold_team_task_lifecycle('delete',${json(rootDelete)})`,
    )).code,
    null,
  );
  const rootRecord = {
    ...rootBefore,
    task_generation: randomUUID(),
    completion_version: 0,
  };
  const rootUndo = {
    ...rootDelete,
    task_generation: rootRecord.task_generation,
    request_id: randomUUID(),
    restore_from: rootDelete.request_id,
    record: rootRecord,
  };
  const rootReply = await run(
    "editor",
    `public.taskfold_team_task_lifecycle('restore',${json(rootUndo)})`,
  );
  check("checklist whole task Undo accepted", rootReply.code, null);
  check(
    "checklist whole task Undo preserves exact nested history",
    rootReply.value?.task.subtasks,
    rootBefore.subtasks,
  );
  fixture.root_recovery_body = rootUndo;
  fixture.root_recovery_reply = rootReply.value;
  await pg.raw(`delete from auth.users where id=${lit(people.editor.id)}`);
  check(
    "checklist removed actor receipts erased",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_task_edits where actor_id=${
        lit(people.editor.id)
      }`,
    ),
    0,
  );
  const formerRestore = await make(
    (await tree()).map((n) =>
      n.id === a.id
        ? {
          ...n,
          subtasks: [{ ...structuredClone(originalChild), [key]: token() }],
        }
        : n
    ),
    { checklist_restore_from: failing.request_id },
  );
  await denied(
    "departed actor receipt cannot restore",
    formerRestore,
    "PT409",
    "owner",
  );
  await pg.raw(
    `update taskfold_private.teams set state='deleted',name=null,owner_id=null where id=${
      lit(team)
    }`,
  );
  check(
    "checklist team deletion erases recovery",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_checklist_deleted_nodes where team_id=${
        lit(team)
      }`,
    ),
    0,
  );
  return fixture;
}
