import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import {
  createPostgresFixture,
  literal as lit,
  postgresImage,
} from "./postgres-fixture.mjs";
import { loadWebhookOutboxSchema } from "./webhook-outbox-schema.mjs";
const output = process.argv[2],
  summary = {
    date: new Date().toISOString(),
    image: postgresImage,
    checks: {},
    barriers: [],
    realTasksChanged: 0,
    hostedAcceptance: false,
    containerRemoved: false,
  };
let pg, seq = 1000;
const id = (n) => "f0a2cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const a = id(1),
  b = id(2),
  sa = id(11),
  sb = id(12),
  ha = id(21),
  hb = id(22),
  project = id(31),
  member = id(32);
const same = (name, actual, expected = true) => {
  assert.deepEqual(actual, expected, name);
  summary.checks[name] = true;
};
const doc = (v) => lit(JSON.stringify(v)) + "::jsonb";
const scalar = (sql) => pg.scalar("select to_jsonb((" + sql + "))");
const manage = (action, body, owner = a, session = sa) =>
  `public.taskfold_webhooks(${lit(owner)},${lit(session)},${lit(action)},${
    doc(body)
  })`;
const dispatch = (action, body = {}) =>
  `public.taskfold_webhook_dispatch(${lit(action)},${doc(body)})`;
async function call(action, body = {}, app = "taskfold-outbox-worker") {
  const result = await pg.value(dispatch(action, body), { app });
  assert.equal(result.code, null, result.reason);
  return result;
}
async function mint(hook, owner = a, session = sa, extra = {}) {
  const settings = {
    id: hook,
    name: "Synthetic receiver",
    endpoint: "https://receiver.example/events",
    scope: "inbox",
    project_id: null,
    events: [
      "task.created",
      "task.updated",
      "task.completed",
      "task.reopened",
      "task.deleted",
    ],
    ttl_days: 30,
    secret_hash: "a".repeat(64),
    secret_envelope: {
      version: 1,
      keyVersion: "fixture-1",
      nonce: "A".repeat(16),
      ciphertext: "B".repeat(64),
    },
    ...extra,
  };
  for (
    const [action, body] of [["create", settings], ["begin_verify", {
      id: hook,
      attempt_id: id(seq),
    }], ["finish_verify", {
      id: hook,
      attempt_id: id(seq++),
      outcome: "verified",
    }]]
  ) {
    const r = await pg.value(manage(action, body, owner, session));
    assert.equal(r.code, null, r.reason);
  }
}
const sourceWrite = (
  target,
  owner = a,
  p = null,
  title = "Synthetic queued task",
  edit = false,
  app = "taskfold-outbox-source",
) =>
  pg.value(
    `public.taskfold_fixture_source(${lit(target)},${lit(owner)},${
      p ? lit(p) : "null"
    },${lit(title)},${edit})`,
    { app },
  );
const insert = async (target, owner = a, p = null) => {
  const result = await sourceWrite(target, owner, p);
  assert.equal(result.code, null, result.reason);
  return result;
};
async function next() {
  const result = await call("claim");
  if (!result.value.event_id) return null;
  const ref = {
    event_id: result.value.event_id,
    lease_id: result.value.lease_id,
  };
  return { ref, packet: (await call("prepare", ref)).value };
}
async function complete(row) {
  if (row?.packet.ready) {
    same("authorize-" + seq++, (await call("authorize", row.ref)).value.ready);
    await call("ack", { ...row.ref, outcome: "delivered", status: 204 });
  }
}
async function drain() {
  for (let n = 0; n < 30; n++) {
    const row = await next();
    if (!row) return;
    await complete(row);
  }
  throw Error("Fixture queue did not drain");
}
async function barrier(app, holder) {
  summary.barriers.push({ app, ...await pg.waitForLock(app, holder.pid) });
}
try {
  pg = await createPostgresFixture();
  summary.postgresVersion = pg.serverVersion;
  await loadWebhookOutboxSchema(pg.raw);
  await pg.raw(
    `create function public.taskfold_fixture_source(target uuid,owner_id uuid,project uuid,label text,editing boolean) returns jsonb language plpgsql security definer set search_path='' as $fixture$ begin if editing then update public.tasks set title=label where id=target;else insert into public.tasks(id,user_id,project_id,title) values(target,owner_id,project,label);end if;return jsonb_build_object('id',target);end $fixture$;revoke all on function public.taskfold_fixture_source(uuid,uuid,uuid,text,boolean) from public;grant execute on function public.taskfold_fixture_source(uuid,uuid,uuid,text,boolean) to service_role;`,
  );
  await pg.raw(
    `insert into auth.users(id,email)values(${
      lit(a)
    },'outbox-a@example.invalid'),(${
      lit(b)
    },'outbox-b@example.invalid');insert into auth.sessions(id,user_id)values(${
      lit(sa)
    },${lit(a)}),(${lit(sb)},${
      lit(b)
    });insert into public.profiles(user_id)values(${lit(a)}),(${lit(b)});`,
  );
  await mint(ha);
  await mint(hb, b, sb);
  await insert(id(101));
  await insert(id(102), b);
  let holder = await pg.hold(
    `select 1 from taskfold_private.webhook_budgets where subscription_id=${
      lit(ha)
    } for update`,
  );
  const started = Date.now(), skipped = await next();
  same(
    "busy-budget-is-skipped-for-another-account",
    skipped.packet.subscription_id,
    hb,
  );
  same("claim-does-not-wait-on-busy-budget", Date.now() - started < 2000);
  summary.barriers.push({
    case: "skip-locked-budget",
    holderPid: holder.pid,
    claimedAccount: b,
    observedBeforeRelease: true,
  });
  await complete(skipped);
  await holder.release("commit");
  const raced = await Promise.all(
    Array.from(
      { length: 8 },
      (_, i) => call("claim", {}, "taskfold-outbox-claim-" + i),
    ),
  );
  const claimed = raced.filter((r) => r.value.event_id);
  same("eight-workers-claim-one-subscription-once", claimed.length, 1);
  same(
    "claims-use-independent-backends",
    new Set(raced.map((r) => r.pid)).size >= 2,
  );
  let row = {
    ref: {
      event_id: claimed[0].value.event_id,
      lease_id: claimed[0].value.lease_id,
    },
  };
  row.packet = (await call("prepare", row.ref)).value;
  const before = Date.now();
  const edit = await sourceWrite(
    id(101),
    a,
    null,
    "Edited while receiver is pending",
    true,
  );
  same("task-edit-saves-with-an-outstanding-network-lease", edit.code, null);
  same("network-lease-holds-no-task-lock", Date.now() - before < 2000);
  const previous = row.packet.body;
  await pg.raw(
    `update taskfold_private.webhook_outbox set lease_until=clock_timestamp()-interval '1 second' where id=${
      lit(row.ref.event_id)
    };update taskfold_private.webhook_budgets set lease_until=clock_timestamp()-interval '1 second' where subscription_id=${
      lit(ha)
    }`,
  );
  const recovered = await next();
  same(
    "expired-lease-recovers-with-identical-body",
    recovered.packet.body,
    previous,
  );
  same("recovered-lease-is-new", recovered.ref.lease_id !== row.ref.lease_id);
  same(
    "stale-worker-cannot-consume-a-recovered-lease",
    (await call("ack", { ...row.ref, outcome: "delivered", status: 204 })).value
      .applied,
    false,
  );
  await complete(recovered);
  await drain();
  // Actual native API journal retries must not create a second capture.
  const key = id(50),
    hash = "c".repeat(64),
    target = id(150),
    gen = id(151),
    request = id(152);
  await pg.raw(
    `insert into taskfold_private.automation_keys(id,user_id,name,token_hash,scopes,ttl_days,expires_at)values(${
      lit(key)
    },${lit(a)},'Synthetic tool',${
      lit(hash)
    },array['tasks:read','tasks:create','tasks:complete'],30,clock_timestamp()+interval '1 day')`,
  );
  const input = {
    id: target,
    task_generation: gen,
    request_id: request,
    time_zone: "UTC",
    fields: {
      title: "Recurring queue proof",
      due_date: "2026-10-23",
      is_recurring: true,
      recurrence_pattern: { type: "daily" },
    },
  };
  const write = (action, body) =>
    `public.taskfold_automation_write(${lit(key)},${lit(hash)},${lit(action)},${
      doc(body)
    })`;
  const created = await pg.value(write("create", input));
  same("actual-api-create-commits-with-capture", created.code, null);
  same(
    "actual-api-create-retry-commits",
    (await pg.value(write("create", input))).code,
    null,
  );
  same(
    "actual-api-create-retry-has-one-event",
    await scalar(
      `select count(*)::int from taskfold_private.webhook_outbox where task_id=${
        lit(target)
      }`,
    ),
    1,
  );
  const read = await pg.value(
    `public.taskfold_automation_read(${lit(key)},${lit(hash)},'get',${
      doc({ id: target })
    })`,
  );
  same("actual-api-baseline-readable", read.code, null);
  const completeBody = {
    id: target,
    task_generation: gen,
    request_id: id(153),
    time_zone: "UTC",
    base: read.value.task,
  };
  same(
    "actual-recurring-completion-commits",
    (await pg.value(write("complete", completeBody))).code,
    null,
  );
  same(
    "actual-recurring-retry-commits",
    (await pg.value(write("complete", completeBody))).code,
    null,
  );
  same(
    "recurring-root-has-create-update-complete-once",
    await scalar(
      `select count(*)::int from taskfold_private.webhook_outbox where task_id=${
        lit(target)
      }`,
    ),
    3,
  );
  same(
    "recurring-successor-captured-once",
    await scalar(
      `select count(*)::int from taskfold_private.webhook_outbox x join public.tasks t on t.id=x.task_id where t.recurrence_parent_id=${
        lit(target)
      }`,
    ),
    1,
  );
  await drain();
  // The final capture slot serializes while all source task transactions save.
  holder = await pg.hold(
    `update taskfold_private.webhook_budgets set day_events=499 where subscription_id=${
      lit(ha)
    }`,
  );
  const beforeEvents = await scalar(
    `select count(*)::int from taskfold_private.webhook_outbox where subscription_id=${
      lit(ha)
    }`,
  );
  const captures = Array.from(
    { length: 8 },
    (_, i) =>
      sourceWrite(
        id(201 + i),
        a,
        null,
        "Quota source task",
        false,
        "taskfold-outbox-capture-" + i,
      ),
  );
  let captureWait;
  for (let n = 0; n < 80 && !captureWait; n++) {
    captureWait = await pg.scalar(
      `select coalesce((select jsonb_build_object('pid',pid,'app',application_name,'blockers',pg_blocking_pids(pid)) from pg_stat_activity where application_name like 'taskfold-outbox-capture-%' and ${holder.pid}=any(pg_blocking_pids(pid)) limit 1),'null'::jsonb)`,
    );
    if (!captureWait) await new Promise((r) => setTimeout(r, 25));
  }
  if (!captureWait) {
    await holder.release("rollback");
    throw Error(
      "Capture lock not observed: " +
        JSON.stringify(await Promise.all(captures)),
    );
  }
  summary.barriers.push({ case: "capture-limit", ...captureWait });
  await holder.release("commit");
  const results = await Promise.all(captures);
  same(
    "all-eight-source-tasks-save-at-capture-limit",
    results.every((r) => r.code === null),
  );
  same(
    "only-one-final-capture-slot-is-used",
    await scalar(
      `select count(*)::int from taskfold_private.webhook_outbox where subscription_id=${
        lit(ha)
      }`,
    ),
    beforeEvents + 1,
  );
  same(
    "other-seven-captures-have-durable-warning",
    await scalar(
      `select missed from taskfold_private.webhook_budgets where subscription_id=${
        lit(ha)
      }`,
    ),
    7,
  );
  await drain();
  await pg.raw(
    `update taskfold_private.webhook_budgets set day_events=0 where subscription_id=${
      lit(ha)
    }`,
  );
  await pg.raw(
    `insert into public.projects(id,user_id,name)values(${lit(project)},${
      lit(b)
    },'Scope proof');select set_config('request.jwt.claim.sub',${
      lit(b)
    },false);insert into public.project_collaborators(id,project_id,invited_by,invited_email,status)values(${
      lit(member)
    },${lit(project)},${
      lit(b)
    },'outbox-a@example.invalid','pending');select set_config('request.jwt.claim.sub',${
      lit(a)
    },false);update public.project_collaborators set status='accepted' where id=${
      lit(member)
    }`,
  );
  await mint(id(24), a, sa, { scope: "project", project_id: project });
  await insert(id(301), a, project);
  row = await next();
  same("project-packet-prepared-before-access-removal", row.packet.ready);
  holder = await pg.hold(
    `select set_config('request.jwt.claim.sub',${
      lit(a)
    },false);update public.project_collaborators set status='pending' where id=${
      lit(member)
    }`,
  );
  const removed = call("authorize", row.ref, "taskfold-outbox-access");
  await barrier("taskfold-outbox-access", holder);
  await holder.release("commit");
  same(
    "committed-membership-removal-blocks-final-write",
    (await removed).value.ready,
    false,
  );
  same(
    "inaccessible-snapshot-is-erased",
    await scalar(
      `select payload is null from taskfold_private.webhook_outbox where id=${
        lit(row.ref.event_id)
      }`,
    ),
  );
  await insert(id(302));
  row = await next();
  holder = await pg.hold(`select ${manage("revoke", { id: ha })}`);
  const revoked = call("authorize", row.ref, "taskfold-outbox-revoke");
  await barrier("taskfold-outbox-revoke", holder);
  await holder.release("commit");
  same(
    "revocation-wins-before-the-write-callback",
    (await revoked).value.ready,
    false,
  );
  await insert(id(303), b);
  row = await next();
  same("other-account-packet-still-prepares", row.packet.account, b);
  holder = await pg.hold(
    `select public.taskfold_account_removal_begin(${lit(b)},${lit(sb)},${
      lit("d".repeat(64))
    })`,
  );
  const removing = call("authorize", row.ref, "taskfold-outbox-removal");
  await barrier("taskfold-outbox-removal", holder);
  await holder.release("commit");
  same(
    "account-removal-blocks-the-final-write",
    (await removing).value.ready,
    false,
  );
  await pg.raw(`delete from auth.users where id=${lit(b)}`);
  same(
    "physical-auth-delete-cleans-queue-and-budget",
    await scalar(
      `select (select count(*) from taskfold_private.webhook_outbox where user_id=${
        lit(b)
      })::int+(select count(*) from taskfold_private.webhook_budgets where user_id=${
        lit(b)
      })::int`,
    ),
    0,
  );
  summary.passed = true;
} catch (error) {
  summary.passed = false;
  summary.failure = { message: error.message, code: error.code };
  process.exitCode = 1;
} finally {
  if (pg) summary.containerRemoved = await pg.close();
  if (output) await writeFile(output, JSON.stringify(summary, null, 2) + "\n");
  console.log(JSON.stringify(summary));
}
