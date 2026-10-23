import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import {
  createPostgresFixture,
  literal as lit,
  postgresImage,
} from "./postgres-fixture.mjs";
import { loadEmailIntakeSchema } from "./email-intake-schema.mjs";
const output = process.argv[2],
  summary = {
    date: new Date().toISOString(),
    image: postgresImage,
    checks: {},
    barriers: [],
    hostedAcceptance: false,
    containerRemoved: false,
  };
const id = (n) => "f0e2cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const a = id(1),
  b = id(2),
  sa = id(11),
  sb = id(12),
  project = id(31),
  member = id(32);
const hash = (n) =>
  createHash("sha256").update("synthetic-race-alias-" + n).digest("hex");
const doc = (v) => lit(JSON.stringify(v)) + "::jsonb",
  stamp = new Date().toISOString();
const draft = (n, extra = {}) => ({
  id: id(n),
  name: "Synthetic race " + n,
  alias_hash: hash(n),
  project_id: null,
  requested_at: stamp,
  ...extra,
});
const manage = (action, body = {}, owner = a, session = sa) =>
  `public.taskfold_email_routes(${lit(owner)},${lit(session)},${lit(action)},${
    doc(body)
  })`;
const content = {
  title: 'Concurrent email 📝 "Review"',
  description: "Whole synthetic note\n  العربية \u0085",
  attachmentCount: 0,
};
const receivedByDelivery = new Map();
const deliver = (n = 21, receipt = "same", extra = {}) => {
  const key = n + ":" + receipt;
  if (!receivedByDelivery.has(key)) {
    receivedByDelivery.set(key, new Date().toISOString());
  }
  return `public.taskfold_email_deliver(${lit(hash(n))},'synthetic-adapter',${
    lit(receipt)
  },${lit(receivedByDelivery.get(key))},'race-a@example.invalid',${
    doc({ ...content, ...extra })
  })`;
};
const app = (prefix) =>
  "email-" + prefix.toLowerCase() + "-" + randomUUID().slice(0, 8);
const same = (name, actual, expected = true) => {
  summary.checks[name] = false;
  assert.deepEqual(actual, expected, name);
  summary.checks[name] = true;
};
let pg;
async function ok(expression) {
  const r = await pg.value(expression);
  assert.equal(r.code, null, r.reason);
  return r.value;
}
async function barrier(label, holder, expression, expectedCode) {
  const application = app(label),
    pending = pg.value(expression, { app: application });
  summary.barriers.push({
    label,
    ...await pg.waitForLock(application, holder.pid),
  });
  await holder.release();
  const result = await pending;
  same(label + " result", result.code, expectedCode);
  return result;
}
try {
  pg = await createPostgresFixture({ advisors: true });
  summary.postgresVersion = pg.serverVersion;
  await loadEmailIntakeSchema(pg.raw);
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at)values(${
      lit(a)
    },'race-a@example.invalid',now()),(${
      lit(b)
    },'race-b@example.invalid',now());insert into auth.sessions(id,user_id)values(${
      lit(sa)
    },${lit(a)}),(${lit(sb)},${
      lit(b)
    });insert into public.profiles(user_id)values(${lit(a)}),(${
      lit(b)
    });update taskfold_private.email_intake_config set enabled=true,provider='synthetic-adapter'`,
  );
  await ok(manage("create", draft(21)));
  const workers = await Promise.all(
    Array.from({ length: 12 }, () => pg.value(deliver())),
  );
  same(
    "all exact concurrent retries accepted",
    workers.every((r) => r.code === null),
  );
  same(
    "exactly one worker creates",
    workers.filter((r) => r.value?.replayed === false).length,
    1,
  );
  same(
    "eleven workers acknowledge original",
    workers.filter((r) => r.value?.replayed === true).length,
    11,
  );
  same(
    "concurrent retry task count",
    await pg.scalar("select to_jsonb(count(*)) from public.tasks"),
    1,
  );
  same(
    "concurrent retry journal count",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.email_deliveries",
    ),
    1,
  );
  const changed = await Promise.all([
    pg.value(deliver(21, "changed", { description: "A" })),
    pg.value(deliver(21, "changed", { description: "B" })),
  ]);
  same(
    "conflicting concurrent replay has one winner",
    changed.filter((r) => r.code === null).length,
    1,
  );
  same(
    "conflicting concurrent replay refuses loser",
    changed.filter((r) => r.code === "PT409").length,
    1,
  );
  same(
    "conflict cannot duplicate task",
    await pg.scalar("select to_jsonb(count(*)) from public.tasks"),
    2,
  );
  const expectedKey = createHash("sha256").update(
    JSON.stringify([
      "taskfold-email-delivery",
      1,
      "synthetic-adapter",
      "same",
      id(21),
    ]),
  ).digest("hex");
  same(
    "actual PostgreSQL key matches JS contract",
    await pg.scalar(
      `select to_jsonb(delivery_key) from taskfold_private.email_deliveries where route_id=${
        lit(id(21))
      } and delivery_key=${lit(expectedKey)}`,
    ),
    expectedKey,
  );
  same(
    "actual PostgreSQL Unicode fingerprint matches JS contract",
    await pg.scalar(
      `select to_jsonb(content_fingerprint) from taskfold_private.email_deliveries where route_id=${
        lit(id(21))
      } and delivery_key=${lit(expectedKey)}`,
    ),
    createHash("sha256").update(
      JSON.stringify([
        "taskfold-email-content",
        1,
        content.title,
        content.description,
        0,
      ]),
    ).digest("hex"),
  );
  // A failure after the task INSERT must roll back its generation and journal too.
  await pg.raw(
    "create function public.email_fixture_refuse_journal() returns trigger language plpgsql as $$begin raise exception 'Synthetic journal failure';end$$;create trigger email_fixture_refuse_journal before insert on taskfold_private.email_deliveries for each row execute function public.email_fixture_refuse_journal()",
  );
  const before = await pg.scalar(
    "select jsonb_build_array((select count(*) from public.tasks),(select count(*) from taskfold_private.task_generations),(select count(*) from taskfold_private.email_deliveries))",
  );
  same(
    "journal failure refuses whole transaction",
    (await pg.value(deliver(21, "rollback"))).code,
    "P0001",
  );
  same(
    "task generation and receipt all rolled back",
    await pg.scalar(
      "select jsonb_build_array((select count(*) from public.tasks),(select count(*) from taskfold_private.task_generations),(select count(*) from taskfold_private.email_deliveries))",
    ),
    before,
  );
  await pg.raw(
    "drop trigger email_fixture_refuse_journal on taskfold_private.email_deliveries;drop function public.email_fixture_refuse_journal()",
  );
  same(
    "same request can retry after rollback",
    (await ok(deliver(21, "rollback"))).replayed,
    false,
  );
  let holder = await pg.hold(
    "select " + manage("revoke", { id: id(23), revision: 0 }),
  );
  await barrier(
    "cancel-before-create",
    holder,
    manage("create", draft(23)),
    "PT409",
  );
  same(
    "cancelled race creates no route",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.email_routes where id=${
        lit(id(23))
      }`,
    ),
    0,
  );
  holder = await pg.hold(
    "select " + manage("pause", { id: id(21), revision: 1 }),
  );
  await barrier(
    "pause-before-delivery",
    holder,
    deliver(21, "paused"),
    "PT404",
  );
  await ok(manage("resume", { id: id(21), revision: 2 }));
  holder = await pg.hold("select " + deliver(21, "delivery-first"));
  await barrier(
    "delivery-before-pause",
    holder,
    manage("pause", { id: id(21), revision: 3 }),
    null,
  );
  same(
    "committed delivery precedes later pause",
    await pg.scalar("select to_jsonb(count(*)) from public.tasks"),
    4,
  );
  same(
    "later replay sees paused state",
    (await pg.value(deliver(21, "delivery-first"))).code,
    "PT404",
  );
  await ok(manage("resume", { id: id(21), revision: 4 }));
  await pg.raw(
    `insert into public.projects(id,user_id,name)values(${lit(project)},${
      lit(b)
    },'Synthetic shared destination');select set_config('request.jwt.claim.sub',${
      lit(b)
    },false);insert into public.project_collaborators(id,project_id,invited_by,invited_email,status)values(${
      lit(member)
    },${lit(project)},${
      lit(b)
    },'race-a@example.invalid','pending');select set_config('request.jwt.claim.sub',${
      lit(a)
    },false);update public.project_collaborators set status='accepted' where id=${
      lit(member)
    }`,
  );
  await ok(manage("create", draft(22, { project_id: project })));
  holder = await pg.hold(
    `delete from public.project_collaborators where id=${lit(member)}`,
  );
  await barrier(
    "membership-removal-before-delivery",
    holder,
    deliver(22, "member-lost"),
    "PT404",
  );
  same(
    "membership race creates no Inbox fallback",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.tasks where project_id=${
        lit(project)
      }`,
    ),
    0,
  );
  await pg.raw(
    `update public.projects set user_id=${lit(a)} where id=${lit(project)}`,
  );
  holder = await pg.hold(
    `update public.projects set is_archived=true where id=${lit(project)}`,
  );
  await barrier(
    "archive-before-delivery",
    holder,
    deliver(22, "archive"),
    "PT409",
  );
  await pg.raw(
    `update public.projects set is_archived=false where id=${lit(project)}`,
  );
  holder = await pg.hold(
    `delete from public.projects where id=${lit(project)}`,
  );
  await barrier(
    "project-delete-before-delivery",
    holder,
    deliver(22, "removed-project"),
    "PT404",
  );
  holder = await pg.hold(
    `update auth.users set email='changed@example.invalid' where id=${lit(a)}`,
  );
  await barrier(
    "Auth-email-change-before-delivery",
    holder,
    deliver(21, "email-change"),
    "42501",
  );
  await pg.raw(
    `update auth.users set email='race-a@example.invalid' where id=${lit(a)}`,
  );
  holder = await pg.hold(
    `update auth.users set email_confirmed_at=null where id=${lit(a)}`,
  );
  await barrier(
    "verification-removal-before-delivery",
    holder,
    deliver(21, "verification-change"),
    "42501",
  );
  await pg.raw(
    `update auth.users set email_confirmed_at=now() where id=${lit(a)}`,
  );
  holder = await pg.hold(
    `update auth.sessions set not_after=now()-interval '1 second' where id=${
      lit(sa)
    }`,
  );
  await barrier(
    "session-expiry-before-management",
    holder,
    manage("list"),
    "28000",
  );
  same(
    "provider capture independent of native sign-in expiry",
    (await ok(deliver(21, "native-session-expired"))).accepted,
    true,
  );
  await pg.raw(`update auth.sessions set not_after=null where id=${lit(sa)}`);
  holder = await pg.hold(
    `select public.taskfold_account_removal_begin(${lit(a)},${lit(sa)},${
      lit(hash(999))
    })`,
  );
  await barrier(
    "account-removal-before-delivery",
    holder,
    deliver(21, "removal"),
    "28000",
  );
  await pg.raw(
    `delete from taskfold_private.account_removal_receipts where account_id=${
      lit(a)
    }`,
  );
  // Two independent deliveries contend for the final route-hour slot.
  await pg.raw(
    `insert into taskfold_private.email_deliveries(route_id,user_id,delivery_key,content_fingerprint,received_at,task_id,task_generation) select ${
      lit(id(21))
    },${
      lit(a)
    },md5(n::text)||md5(('quota-'||n)::text),repeat('a',64),now(),gen_random_uuid(),gen_random_uuid() from generate_series(1,49-(select count(*)::int from taskfold_private.email_deliveries where route_id=${
      lit(id(21))
    })) n`,
  );
  const finalSlot = await Promise.all([
    pg.value(deliver(21, "final-slot-a")),
    pg.value(deliver(21, "final-slot-b")),
  ]);
  same(
    "quota race has one accepted final slot",
    finalSlot.filter((r) => r.code === null).length,
    1,
  );
  same(
    "quota race refuses other final slot",
    finalSlot.filter((r) => r.code === "PT429").length,
    1,
  );
  same(
    "quota race exact receipt bound",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.email_deliveries where route_id=${
        lit(id(21))
      }`,
    ),
    50,
  );
  summary.advisors = await pg.advisors();
  const emailFindings = summary.advisors.result.filter((finding) =>
    /email_|taskfold_email_/.test(
      JSON.stringify(finding.metadata ?? {}) + " " + finding.detail,
    )
  );
  summary.advisors.emailFindings = emailFindings;
  same(
    "official advisors no new email warnings or errors",
    emailFindings.filter((finding) => finding.level !== "INFO"),
    [],
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
