import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamProjectSchema } from "./team-project-schema.mjs";
const report = {
  checks: {},
  deployed: false,
  providerStorageAcceptance: false,
  realDataChanged: false,
};
const check = (name, actual, expected) => {
  assert.deepEqual(actual, expected, name);
  report.checks[name] = true;
};
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  report.postgresVersion = pg.serverVersion;
  await loadTeamProjectSchema(pg.raw);
  // Provider-owned columns/RLS absent from the deliberately minimal dependency fixture.
  await pg.raw(
    `alter table storage.buckets add column name text,add column file_size_limit bigint,add column allowed_mime_types text[];
 alter table storage.buckets enable row level security;
 alter table storage.objects add column metadata jsonb;
 create unique index audio_fixture_object_identity on storage.objects(bucket_id,name);
 grant usage on schema storage to anon,authenticated;
 grant select,insert,update,delete on storage.objects,storage.buckets to anon,authenticated;
 create policy audio_fixture_broad_objects on storage.objects for all to anon,authenticated using(true) with check(true);
 create policy audio_fixture_broad_buckets on storage.buckets for all to anon,authenticated using(true) with check(true);`,
  );
  for (
    const file of [
      "20261028134424_audio_comment_publication_ledger.sql",
      "20261028145414_audio_comment_gateway_boundary.sql",
      "20261028151901_audio_comment_cleanup_fencing.sql",
      "20261028153218_audio_comment_upload_recovery.sql",
    ]
  ) {
    const source = await readFile(
      new URL("../../supabase/migrations/" + file, import.meta.url),
      "utf8",
    );
    report[file] = createHash("sha256").update(source).digest("hex");
    if (file.includes("gateway")) report.baselineAdvisors = await pg.advisors();
    await pg.raw(source);
  }
  const actor = randomUUID(),
    session = randomUUID(),
    task = randomUUID(),
    generation = randomUUID();
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at) values(${
      lit(actor)
    },'gateway@example.invalid',now());insert into auth.sessions(id,user_id) values(${
      lit(session)
    },${lit(actor)});insert into public.profiles(user_id) values(${
      lit(actor)
    });insert into public.tasks(id,user_id,task_generation,title) values(${
      lit(task)
    },${lit(actor)},${lit(generation)},'Synthetic gateway target')`,
  );
  const admit = (action, clock = null) =>
    pg.value(
      clock
        ? `taskfold_private.audio_admit_at(${lit(actor)},${lit(session)},${
          lit(action)
        },${lit(clock)}::timestamptz)`
        : `public.taskfold_audio_comment_admit(${lit(actor)},${lit(session)},${
          lit(action)
        })`,
      clock ? { role: "postgres" } : {},
    );
  const value = async (p) => {
    const r = await p;
    assert.equal(r.code, null, JSON.stringify(r));
    return r.value;
  };
  check("default off", (await value(admit("publish"))).status, "disabled");
  check(
    "private service-created bucket",
    await pg.scalar(
      `select to_jsonb(row(public,file_size_limit,allowed_mime_types)) from storage.buckets where id='taskfold-audio-v1'`,
    ),
    { f1: false, f2: 8000000, f3: ["audio/mp4"] },
  );
  check(
    "old ledger cannot bypass Storage",
    await pg.scalar(
      `select to_jsonb(has_function_privilege('service_role','taskfold_private.audio_comment_ledger_v1(text,uuid,uuid,jsonb)','execute'))`,
    ),
    false,
  );
  check(
    "service cannot choose budget clock",
    await pg.scalar(
      `select to_jsonb(has_function_privilege('service_role','taskfold_private.audio_admit_at(uuid,uuid,text,timestamptz)','execute'))`,
    ),
    false,
  );
  check(
    "anonymous cannot admit",
    await pg.scalar(
      `select to_jsonb(has_function_privilege('anon','public.taskfold_audio_comment_admit(uuid,uuid,text)','execute'))`,
    ),
    false,
  );
  check(
    "authenticated cannot command",
    await pg.scalar(
      `select to_jsonb(has_function_privilege('authenticated','public.taskfold_audio_comment_command(text,uuid,uuid,jsonb)','execute'))`,
    ),
    false,
  );
  await pg.raw(`update taskfold_private.audio_comment_config set enabled=true`);
  const clock = "2026-10-28T16:00:00Z";
  const parallel = await Promise.all(
    Array.from({ length: 16 }, () => value(admit("publish", clock))),
  );
  check(
    "concurrent workers share twelve publication slots",
    parallel.filter((r) => r.allowed).length,
    12,
  );
  check(
    "excess workers receive bounded retry",
    parallel.filter((r) => r.status === "rate_limited" && r.retry_after === 60)
      .length,
    4,
  );
  check(
    "next server minute opens budget",
    (await value(admit("publish", "2026-10-28T16:01:00Z"))).allowed,
    true,
  );
  for (let n = 0; n < 30; n++) {
    assert.equal((await value(admit("download", clock))).allowed, true);
  }
  check(
    "download budget independent of publication",
    (await value(admit("download", clock))).status,
    "rate_limited",
  );
  for (let n = 0; n < 60; n++) {
    assert.equal(
      (await value(admit(n % 2 ? "list" : "remove", clock))).allowed,
      true,
    );
  }
  check(
    "list and remove share metadata budget",
    (await value(admit("list", clock))).status,
    "rate_limited",
  );
  const intent = {
    version: 1,
    account: actor,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target: { task_id: task, task_generation: generation, project_id: null },
    caption: "Synthetic recording",
    audio: {
      version: 1,
      mime_type: "audio/mp4",
      byte_count: 12345,
      duration_ms: 1000,
      sha256: "a".repeat(64),
    },
  };
  const command = (action, body) =>
    value(
      pg.value(
        `public.taskfold_audio_comment_command(${lit(action)},${lit(actor)},${
          lit(session)
        },${json(body)})`,
      ),
    );
  const finalize = () =>
    command("finalize", {
      intent,
      stored_sha256: intent.audio.sha256,
      stored_bytes: intent.audio.byte_count,
    });
  check("reserve pending", (await command("reserve", intent)).state, "pending");
  check(
    "metadata attestation alone cannot publish",
    (await finalize()).status,
    "verification_failed",
  );
  const name = `audio-comments/v1/${task}/${generation}/${intent.asset_id}.m4a`,
    objectID = randomUUID();
  await pg.raw(
    `insert into storage.objects(id,bucket_id,name,metadata) values(${
      lit(objectID)
    },'taskfold-audio-v1',${
      lit(name)
    },'{"size":12344,"mimetype":"audio/mp4"}')`,
  );
  check(
    "wrong stored size refused",
    (await finalize()).status,
    "verification_failed",
  );
  await pg.raw(
    `update storage.objects set metadata='{"size":12345,"mimetype":"application/octet-stream"}' where id=${
      lit(objectID)
    }`,
  );
  check(
    "wrong stored type refused",
    (await finalize()).status,
    "verification_failed",
  );
  await pg.raw(
    `update storage.objects set metadata='{"size":12345,"mimetype":"audio/mp4"}',owner_id=${
      lit(actor)
    } where id=${lit(objectID)}`,
  );
  check(
    "client-owned upload refused",
    (await finalize()).status,
    "verification_failed",
  );
  await pg.raw(
    `update storage.objects set owner_id=null where id=${
      lit(objectID)
    };update storage.buckets set public=true where id='taskfold-audio-v1'`,
  );
  check(
    "unsafe bucket refused",
    (await finalize()).status,
    "verification_failed",
  );
  await pg.raw(
    `update storage.buckets set public=false where id='taskfold-audio-v1'`,
  );
  check(
    "matching Storage facts allow finalization",
    (await finalize()).state,
    "published",
  );
  // Broad permissive policies deliberately coexist: restrictive policies must win.
  for (const role of ["anon", "authenticated"]) {
    check(
      role + " cannot see protected bytes",
      await pg.scalar(
        `begin;set local role ${role};select to_jsonb(count(*)) from storage.objects where bucket_id='taskfold-audio-v1';commit`,
      ),
      0,
    );
    check(
      role + " cannot see protected bucket",
      await pg.scalar(
        `begin;set local role ${role};select to_jsonb(count(*)) from storage.buckets where id='taskfold-audio-v1';commit`,
      ),
      0,
    );
    await assert.rejects(
      pg.raw(
        `begin;set local role ${role};insert into storage.objects(id,bucket_id,name) values(${
          lit(randomUUID())
        },'taskfold-audio-v1','forged');commit`,
      ),
      (e) => e.code === "42501",
    );
    report.checks[role + " direct insert blocked"] = true;
    await pg.raw(
      `begin;set local role ${role};update storage.objects set name='tampered' where id=${
        lit(objectID)
      };delete from storage.objects where id=${
        lit(objectID)
      };update storage.buckets set public=true where id='taskfold-audio-v1';delete from storage.buckets where id='taskfold-audio-v1';commit`,
    );
    check(
      role + " direct mutations cannot change protected object",
      await pg.scalar(
        `select to_jsonb(name) from storage.objects where id=${lit(objectID)}`,
      ),
      name,
    );
    check(
      role + " other buckets stay visible",
      await pg.scalar(
        `begin;set local role ${role};select to_jsonb(count(*)) from storage.buckets where id='avatars';commit`,
      ),
      1,
    );
  }
  await pg.raw(
    `update taskfold_private.audio_comment_config set enabled=false`,
  );
  check(
    "disabled gateway still admits removal",
    (await value(admit("remove"))).allowed,
    true,
  );
  check(
    "disabled publication stays blocked",
    (await value(admit("publish"))).status,
    "disabled",
  );
  check(
    "removal retires publication",
    (await command("remove", { comment_id: intent.comment_id })).state,
    "retired",
  );
  await pg.raw(`delete from auth.sessions where id=${lit(session)}`);
  check(
    "revoked session cannot admit",
    (await value(admit("remove"))).status,
    "unavailable",
  );
  // Retire during a durable open upload: time passing cannot free its quota.
  const late = {
    ...intent,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
  };
  await pg.raw(
    `insert into auth.sessions(id,user_id) values(${lit(session)},${
      lit(actor)
    });update taskfold_private.audio_comment_config set enabled=true`,
  );
  check(
    "late-upload target reserved",
    (await command("reserve", late)).state,
    "pending",
  );
  const ticket = await command("upload_begin", {
    operation_id: late.operation_id,
  });
  check("upload has durable open ticket", ticket.state, "open");
  check(
    "concurrent retry cannot start another write",
    (await command("upload_begin", { operation_id: late.operation_id })).status,
    "upload_unresolved",
  );
  await command("remove", { comment_id: late.comment_id });
  await pg.raw(
    `update taskfold_private.audio_comment_publications set cleanup_after=clock_timestamp()-interval '1 day' where operation_id in(${
      lit(late.operation_id)
    },${lit(intent.operation_id)})`,
  );
  const maintenance = (action, body) =>
    value(
      pg.value(
        `public.taskfold_audio_comment_maintenance(${lit(action)},${
          json(body)
        })`,
      ),
    );
  let claimed = await maintenance("claim", {});
  check(
    "elapsed time never releases an unknown upload",
    claimed.items.some((r) => r.operation_id === late.operation_id),
    false,
  );
  check("maintenance reports unresolved uploads", claimed.blocked_uploads, 1);
  check(
    "legacy unfenced purge is blocked",
    (await pg.value(
      `public.taskfold_audio_comment_command('purged',null,null,'{}')`,
    )).code,
    "22023",
  );
  check(
    "retired ticket cannot start another write",
    (await command("upload_begin", { operation_id: late.operation_id })).status,
    "unavailable",
  );
  await pg.raw(`delete from auth.sessions where id=${lit(session)}`);
  check(
    "settlement remains possible after session revocation",
    (await command("upload_settle", {
      operation_id: late.operation_id,
      ticket_id: ticket.ticket_id,
    })).settled,
    true,
  );
  await pg.raw(
    `insert into auth.sessions(id,user_id) values(${lit(session)},${
      lit(actor)
    })`,
  );
  claimed = await maintenance("claim", {});
  const c = claimed.items.find((r) => r.operation_id === late.operation_id);
  check("settled retired upload becomes claimable", !!c, true);
  check(
    "active claim excludes another worker",
    (await maintenance("claim", {})).items.some((r) =>
      r.operation_id === late.operation_id
    ),
    false,
  );
  check(
    "wrong claim token cannot purge",
    (await maintenance("confirm", {
      operation_id: c.operation_id,
      asset_id: c.asset_id,
      object_name: c.object_name,
      token: randomUUID(),
    })).purged,
    false,
  );
  await pg.raw(
    `insert into storage.objects(id,bucket_id,name,metadata) values(${
      lit(randomUUID())
    },'taskfold-audio-v1',${
      lit(c.object_name)
    },'{"size":12345,"mimetype":"audio/mp4"}')`,
  );
  check(
    "remaining Storage metadata prevents quota release",
    (await maintenance("confirm", {
      operation_id: c.operation_id,
      asset_id: c.asset_id,
      object_name: c.object_name,
      token: c.token,
    })).purged,
    false,
  );
  // Controlled provider fixture only: real worker deletes via Storage HTTP, never SQL.
  await pg.raw(
    `delete from storage.objects where bucket_id='taskfold-audio-v1' and name=${
      lit(c.object_name)
    };update taskfold_private.audio_cleanup_claims set expires_at=clock_timestamp()-interval '1 second' where operation_id=${
      lit(c.operation_id)
    }`,
  );
  check(
    "expired cleanup token cannot confirm",
    (await maintenance("confirm", {
      operation_id: c.operation_id,
      asset_id: c.asset_id,
      object_name: c.object_name,
      token: c.token,
    })).purged,
    false,
  );
  const renewed = (await maintenance("claim", {})).items.find((r) =>
    r.operation_id === late.operation_id
  );
  check("retry rotates cleanup token", renewed.token !== c.token, true);
  check(
    "new claim confirms absent settled object",
    (await maintenance("confirm", {
      operation_id: renewed.operation_id,
      asset_id: renewed.asset_id,
      object_name: renewed.object_name,
      token: renewed.token,
    })).purged,
    true,
  );
  check(
    "purged upload never reopens",
    (await command("upload_begin", { operation_id: late.operation_id })).status,
    "unavailable",
  );
  check(
    "maintenance unavailable to clients",
    await pg.scalar(
      `select to_jsonb(has_function_privilege('authenticated','public.taskfold_audio_comment_maintenance(text,jsonb)','execute'))`,
    ),
    false,
  );
  check(
    "old gateway helper cannot bypass fence",
    await pg.scalar(
      `select to_jsonb(has_function_privilege('service_role','taskfold_private.audio_comment_gateway_v2(text,uuid,uuid,jsonb)','execute'))`,
    ),
    false,
  );
  const recoverable = {
    ...intent,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
  };
  await command("reserve", recoverable);
  const recoveryTicket = await command("upload_begin", {
    operation_id: recoverable.operation_id,
  });
  await command("remove", { comment_id: recoverable.comment_id });
  const recoveryPath =
    `audio-comments/v1/${task}/${generation}/${recoverable.asset_id}.m4a`;
  const probes = await Promise.all([
    maintenance("probe", {}),
    maintenance("probe", {}),
  ]);
  check(
    "cold recovery workers claim open attempt once",
    probes.flatMap((x) => x.items).filter((x) =>
      x.operation_id === recoverable.operation_id
    ).length,
    1,
  );
  check(
    "probe backoff prevents immediate repetition",
    (await maintenance("probe", {})).items.some((x) =>
      x.operation_id === recoverable.operation_id
    ),
    false,
  );
  const evidence = {
    operation_id: recoverable.operation_id,
    asset_id: recoverable.asset_id,
    object_name: recoveryPath,
    ticket_id: recoveryTicket.ticket_id,
    stored_sha256: recoverable.audio.sha256,
    stored_bytes: recoverable.audio.byte_count,
  };
  check(
    "absence never settles a retired upload",
    (await maintenance("reconcile", evidence)).settled,
    false,
  );
  await pg.raw(
    `insert into storage.objects(id,bucket_id,name,metadata) values(${
      lit(randomUUID())
    },'taskfold-audio-v1',${
      lit(recoveryPath)
    },'{"size":12345,"mimetype":"audio/mp4"}')`,
  );
  check(
    "wrong readback digest cannot settle",
    (await maintenance("reconcile", {
      ...evidence,
      stored_sha256: "f".repeat(64),
    })).settled,
    false,
  );
  check(
    "wrong ticket cannot settle",
    (await maintenance("reconcile", { ...evidence, ticket_id: randomUUID() }))
      .settled,
    false,
  );
  check(
    "matching attestation and metadata settle sole retired upload",
    (await maintenance("reconcile", evidence)).settled,
    true,
  );
  check(
    "reconciliation cannot run twice",
    (await maintenance("reconcile", evidence)).settled,
    false,
  );
  check(
    "old fenced helper not service callable",
    await pg.scalar(
      `select to_jsonb(has_function_privilege('service_role','taskfold_private.audio_maintenance_fenced_v3(text,jsonb)','execute'))`,
    ),
    false,
  );
  // Real loopback HTTP through the production handler; PostgreSQL is real,
  // Auth identity and Storage's bytes/metadata are a controlled local adapter.
  const httpActor = randomUUID(),
    httpSession = randomUUID(),
    httpTask = randomUUID(),
    httpGeneration = randomUUID();
  await pg.raw(
    `update taskfold_private.audio_comment_config set enabled=true;insert into auth.users(id,email,email_confirmed_at) values(${
      lit(httpActor)
    },'http-gateway@example.invalid',now());insert into auth.sessions(id,user_id) values(${
      lit(httpSession)
    },${lit(httpActor)});insert into public.profiles(user_id) values(${
      lit(httpActor)
    });insert into public.tasks(id,user_id,task_generation,title) values(${
      lit(httpTask)
    },${lit(httpActor)},${lit(httpGeneration)},'Synthetic HTTP target')`,
  );
  const http = await createAudioHttpFixture(pg, httpActor, httpSession);
  try {
    const audio = await readFile(
      new URL(
        "../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
        import.meta.url,
      ),
    );
    const makeIntent = () => ({
      version: 1,
      account: httpActor,
      operation_id: randomUUID(),
      comment_id: randomUUID(),
      asset_id: randomUUID(),
      target: {
        task_id: httpTask,
        task_generation: httpGeneration,
        project_id: null,
      },
      caption: "  café\nمراجعة 🪴  ",
      audio: {
        version: 1,
        mime_type: "audio/mp4",
        byte_count: audio.length,
        duration_ms: 1000,
        sha256: createHash("sha256").update(audio).digest("hex"),
      },
    });
    const i = makeIntent(),
      publish = (i) =>
        http.call("publish", {
          intent: i,
          audio_base64: audio.toString("base64"),
        });
    let r = await publish(i);
    check("HTTP publishes after byte readback", r.status, 200);
    const ack = await r.json();
    check("HTTP keeps frozen comment ID", ack.receipt.comment_id, i.comment_id);
    check(
      "HTTP hides bucket/object path",
      "object_name" in ack.receipt || "bucket" in ack.receipt,
      false,
    );
    r = await publish(i);
    check("HTTP retry succeeds", r.status, 200);
    await r.body.cancel();
    check("HTTP retry does not overwrite", http.state.uploads, 1);
    r = await http.call("download", { comment_id: i.comment_id });
    check("HTTP download succeeds", r.status, 200);
    check(
      "HTTP downloaded bytes match original",
      Buffer.from(await r.arrayBuffer()).equals(audio),
      true,
    );
    r = await http.call("list", i.target);
    check("HTTP lists current publication", (await r.json()).items.length, 1);
    r = await publish({ ...i, caption: "Changed retry caption" });
    check(
      "HTTP changed retry cannot replace frozen publication",
      r.status,
      409,
    );
    await r.body.cancel();
    check("HTTP changed retry causes no overwrite", http.state.uploads, 1);
    http.state.lostAck = true;
    const lost = makeIntent();
    r = await publish(lost);
    check("HTTP dropped upload acknowledgement reconciles", r.status, 200);
    await r.body.cancel();
    http.state.lostAck = false;
    http.state.noWrite = true;
    const absent = makeIntent();
    r = await publish(absent);
    check("HTTP upload ACK without bytes cannot finalize", r.status, 503);
    await r.body.cancel();
    http.state.noWrite = false;
    const uncertain = makeIntent();
    http.state.noWrite = true;
    http.state.lostAck = true;
    r = await publish(uncertain);
    check("HTTP unknown no-byte upload stays unresolved", r.status, 503);
    await r.body.cancel();
    http.state.noWrite = false;
    http.state.lostAck = false;
    const uploadsBeforeRetry = http.state.uploads;
    r = await publish(uncertain);
    check("HTTP uncertain retry cannot issue another upload", r.status, 503);
    await r.body.cancel();
    check(
      "HTTP uncertain retry preserves single attempt",
      http.state.uploads,
      uploadsBeforeRetry,
    );
    await pg.raw(
      `update taskfold_private.audio_comment_publications set expires_at=clock_timestamp()-interval '1 minute' where operation_id=${
        lit(uncertain.operation_id)
      }`,
    );
    http.state.corrupt = true;
    const corrupt = makeIntent();
    r = await publish(corrupt);
    check("HTTP corrupt readback cannot finalize", r.status, 503);
    await r.body.cancel();
    http.state.corrupt = false;
    check(
      "HTTP failed readbacks stay pending",
      await pg.scalar(
        `select to_jsonb(count(*)) from taskfold_private.audio_comment_publications where operation_id in(${
          lit(absent.operation_id)
        },${lit(corrupt.operation_id)}) and state='pending'`,
      ),
      2,
    );
    const storedName =
      `audio-comments/v1/${httpTask}/${httpGeneration}/${i.asset_id}.m4a`;
    http.state.objects.delete(storedName);
    const before = http.state.uploads;
    r = await publish(i);
    check("HTTP missing published bytes never recreated", r.status, 503);
    await r.body.cancel();
    check(
      "HTTP missing published object causes no upload",
      http.state.uploads,
      before,
    );
    r = await http.call("remove", { comment_id: i.comment_id });
    check("HTTP removal retires saved publication", r.status, 200);
    check(
      "HTTP removal acknowledgement is retired",
      (await r.json()).state,
      "retired",
    );
    r = await http.call("download", { comment_id: i.comment_id });
    check("HTTP retired media cannot be downloaded", r.status, 404);
    await r.body.cancel();
    http.state.afterGet = async () => {
      await pg.raw(`delete from auth.sessions where id=${lit(httpSession)}`);
      http.state.afterGet = null;
    };
    r = await http.call("download", { comment_id: lost.comment_id });
    check(
      "HTTP rechecks live session after stored bytes return",
      r.status,
      404,
    );
    await r.body.cancel();
    // Retire a known terminal upload; worker deletes through the local Storage
    // API adapter, verifies GET absence, then confirms through actual SQL.
    await pg.raw(
      `update taskfold_private.audio_comment_publications set state='retired',caption=null,audio_descriptor=null,cleanup_after=clock_timestamp()-interval '1 minute' where operation_id=${
        lit(lost.operation_id)
      }`,
    );
    http.state.deleteFails = true;
    r = await http.maintain();
    let sweep = await r.json();
    check("HTTP worker failed deletion does not purge", sweep.purged, 0);
    check("worker exposes unresolved retired upload", sweep.blocked_uploads, 1);
    check(
      "failed Storage removal retains quota",
      await pg.scalar(
        `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
          lit(lost.operation_id)
        }`,
      ),
      "retired",
    );
    http.state.deleteFails = false;
    await pg.raw(
      `update taskfold_private.audio_cleanup_claims set expires_at=clock_timestamp()-interval '1 second'`,
    );
    r = await http.maintain();
    sweep = await r.json();
    check(
      "HTTP worker removes and confirms settled media",
      sweep.purged >= 1,
      true,
    );
    check(
      "HTTP Storage bytes actually removed",
      http.state.objects.has(
        `audio-comments/v1/${httpTask}/${httpGeneration}/${lost.asset_id}.m4a`,
      ),
      false,
    );
    check(
      "verified removal releases quota state",
      await pg.scalar(
        `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
          lit(lost.operation_id)
        }`,
      ),
      "purged",
    );
    check(
      "unknown retired upload still retains quota after worker",
      await pg.scalar(
        `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
          lit(uncertain.operation_id)
        }`,
      ),
      "retired",
    );
    // A provider write arrives after the response was lost and the task retired.
    const latePath =
      `audio-comments/v1/${httpTask}/${httpGeneration}/${uncertain.asset_id}.m4a`;
    http.state.objects.set(latePath, audio);
    await pg.raw(
      `insert into storage.objects(id,bucket_id,name,metadata) values(${
        lit(randomUUID())
      },'taskfold-audio-v1',${lit(latePath)},${
        json({ size: audio.length, mimetype: "audio/mp4" })
      });update taskfold_private.audio_upload_attempts set next_probe_at=clock_timestamp()-interval '1 second' where operation_id=${
        lit(uncertain.operation_id)
      };update taskfold_private.audio_comment_publications set cleanup_after=clock_timestamp()-interval '1 second' where operation_id=${
        lit(uncertain.operation_id)
      }`,
    );
    r = await http.maintain();
    sweep = await r.json();
    check(
      "HTTP full-byte recovery settles late retired upload",
      sweep.recovered,
      1,
    );
    check(
      "HTTP recovered retired upload releases quota after deletion",
      await pg.scalar(
        `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
          lit(uncertain.operation_id)
        }`,
      ),
      "purged",
    );
    check(
      "HTTP late-arriving bytes actually removed",
      http.state.objects.has(latePath),
      false,
    );
    check("HTTP adapter has no SQL or route errors", http.state.errors, []);
    report.loopbackHTTP = {
      productionHandler: true,
      realPostgres: true,
      controlledAuth: true,
      controlledStorageBytes: true,
      realProviderAcceptance: false,
    };
  } finally {
    await http.close();
  }
  report.finalAdvisors = await pg.advisors();
  const baseline = new Set(
    report.baselineAdvisors.result.map((r) => r.cache_key),
  );
  const added = report.finalAdvisors.result.filter((r) =>
    !baseline.has(r.cache_key)
  );
  check("no new advisor findings", added, []);
} finally {
  if (pg) report.ownedPostgresContainerRemoved = await pg.close();
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
}
console.log(
  Object.keys(report.checks).length +
    " actual PostgreSQL gateway boundary checks passed",
);
