// Synthetic-only signed envelope -> real PostgreSQL journal acceptance.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createHash } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadEmailIntakeSchema } from "./email-intake-schema.mjs";
const exec = promisify(execFile), output = process.argv[2];
const summary = {
  checks: {},
  providerDeliveryClaimed: false,
  durableIngressAdmissionClaimed: false,
  deployed: false,
  realDataChanged: false,
  containerRemoved: false,
};
const same = (name, actual, expected) => {
  summary.checks[name] = false;
  assert.deepEqual(actual, expected, name);
  summary.checks[name] = true;
};
const account = "f0e3cafe-0000-4000-8000-000000000001",
  session = "f0e3cafe-0000-4000-8000-000000000011",
  route = "f0e3cafe-0000-4000-8000-000000000021";
const doc = (value) => lit(JSON.stringify(value)) + "::jsonb";
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  summary.postgresVersion = pg.serverVersion;
  await loadEmailIntakeSchema(pg.raw);
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at) values(${
      lit(account)
    },'intake-a@example.invalid',now());insert into auth.sessions(id,user_id) values(${
      lit(session)
    },${lit(account)});insert into public.profiles(user_id) values(${
      lit(account)
    });`,
  );
  const alias = "a".repeat(64) + "@mail.example.invalid";
  const hash = createHash("sha256").update(
    JSON.stringify(["taskfold-email-alias", 1, alias]),
  ).digest("hex");
  const manage = (action, body) =>
    pg.value(
      `public.taskfold_email_routes(${lit(account)},${lit(session)},${
        lit(action)
      },${doc(body)})`,
    );
  const setup = {
    id: route,
    name: "Synthetic signed email",
    alias_hash: hash,
    domain: "mail.example.invalid",
    project_id: null,
    requested_at: new Date().toISOString(),
  };
  same(
    "disabled enrollment remains closed",
    (await manage("create", setup)).code,
    "PT503",
  );
  await pg.raw(
    "update taskfold_private.email_intake_config set enabled=true,provider='synthetic-adapter',domain='mail.example.invalid'",
  );
  const created = await manage("create", setup);
  same("native route enrollment succeeds", created.code, null);
  const prepared = await exec("deno", [
    "run",
    "--cached-only",
    "--config",
    "supabase/functions/_shared/email-ingress/deno.json",
    "supabase/functions/_shared/email-ingress/journal_fixture.ts",
  ], { maxBuffer: 1024 * 1024, timeout: 20000 });
  const args = JSON.parse(prepared.stdout);
  same("signed envelope hashes the actual recipient", args._alias_hash, hash);
  same(
    "MIME From cannot replace verified sender",
    args._verified_sender,
    "intake-a@example.invalid",
  );
  same(
    "MIME Message-ID cannot replace original receipt",
    args._delivery_id,
    "original-receipt-1",
  );
  const delivery = (extra) => {
    const row = { ...args, ...extra };
    return pg.value(
      `public.taskfold_email_deliver_v2(${lit(row._alias_hash)},${
        lit(row._recipient_domain)
      },${lit(row._provider)},${lit(row._delivery_id)},${
        lit(row._received_at)
      },${lit(row._verified_sender)},${doc(row._content)})`,
    );
  };
  const first = await delivery();
  same("actual service journal accepts signed decoded mail", first.code, null);
  same("first acceptance is not replay", first.value, {
    accepted: true,
    replayed: false,
  });
  same("exact delivery retry reuses receipt", (await delivery()).value, {
    accepted: true,
    replayed: true,
  });
  same(
    "one task after repeated delivery",
    Number(await pg.raw("select count(*) from public.tasks")),
    1,
  );
  same(
    "saved task matches decoded words",
    await pg.scalar(
      "select jsonb_build_object('title',title,'description',description,'user_id',user_id,'project_id',project_id) from public.tasks",
    ),
    {
      title: "Review the launch",
      description: "Keep the original words.\n",
      user_id: account,
      project_id: null,
    },
  );
  same(
    "changed decoded content conflicts",
    (await delivery({
      _content: { ...args._content, title: "Changed delivery" },
    })).code,
    "PT409",
  );
  same(
    "changed original receipt time conflicts",
    (await delivery({
      _received_at: new Date(Date.parse(args._received_at) + 1000)
        .toISOString(),
    })).code,
    "PT409",
  );
  same(
    "another verified sender still cannot use route",
    (await delivery({ _verified_sender: "other@example.invalid" })).code,
    "42501",
  );
  same(
    "recipient domain remains independently enforced",
    (await delivery({ _recipient_domain: "other.invalid" })).code,
    "PT404",
  );
  await pg.raw("delete from public.tasks");
  same(
    "deleted-task replay acknowledges original receipt",
    (await delivery()).value,
    { accepted: true, replayed: true },
  );
  same(
    "replay cannot recreate deleted work",
    Number(await pg.raw("select count(*) from public.tasks")),
    0,
  );
  const paused = await manage("pause", {
    id: route,
    revision: created.value.route.revision,
  });
  same("pause route succeeds", paused.code, null);
  same(
    "paused route refuses delivery",
    (await delivery({ _delivery_id: "paused-new" })).code,
    "PT404",
  );
  const resumed = await manage("resume", {
    id: route,
    revision: paused.value.route.revision,
    domain: "mail.example.invalid",
  });
  same("resume route succeeds", resumed.code, null);
  same(
    "old new-receipt mail cannot backfill resumed route",
    (await delivery({
      _delivery_id: "old-new",
      _received_at: new Date(Date.now() - 86400000).toISOString(),
    })).code,
    "22023",
  );
  same(
    "anonymous cannot invoke delivery",
    await pg.scalar(
      "select to_jsonb(has_function_privilege('anon','public.taskfold_email_deliver_v2(text,text,text,text,timestamptz,text,jsonb)','execute'))",
    ),
    false,
  );
  same(
    "authenticated cannot invoke service-only delivery",
    await pg.scalar(
      "select to_jsonb(has_function_privilege('authenticated','public.taskfold_email_deliver_v2(text,text,text,text,timestamptz,text,jsonb)','execute'))",
    ),
    false,
  );
  same(
    "receipt table remains private",
    await pg.scalar(
      "select to_jsonb(has_table_privilege('authenticated','taskfold_private.email_deliveries','select'))",
    ),
    false,
  );
  const revoked = await manage("revoke", {
    id: route,
    revision: resumed.value.route.revision,
  });
  same("revoke route succeeds", revoked.code, null);
  same(
    "revoked route refuses delivery",
    (await delivery({ _delivery_id: "revoked-new" })).code,
    "PT404",
  );
  same(
    "rejected deliveries create no tasks",
    Number(await pg.raw("select count(*) from public.tasks")),
    0,
  );
  summary.advisors = await pg.advisors();
  const findings = summary.advisors.result.filter((f) =>
    /email_|taskfold_email_/.test(
      JSON.stringify(f.metadata ?? {}) + " " + f.detail,
    )
  );
  summary.advisors.emailFindings = findings;
  same(
    "official advisors no email warnings or errors",
    findings.filter((f) => f.level !== "INFO"),
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
