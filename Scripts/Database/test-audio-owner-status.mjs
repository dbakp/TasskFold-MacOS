import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamProjectSchema } from "./team-project-schema.mjs";
import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
const report = { checks: {}, deployed: false, realDataChanged: false },
  check = (n, a, b = true) => {
    assert.deepEqual(a, b, n);
    report.checks[n] = true;
  },
  j = (x) => lit(JSON.stringify(x)) + "::jsonb";
let pg, http;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadTeamProjectSchema(pg.raw);
  await pg.raw(
    "alter table storage.buckets add column name text,add column file_size_limit bigint,add column allowed_mime_types text[];alter table storage.buckets enable row level security;alter table storage.objects add column metadata jsonb;create unique index audio_fixture_object_identity on storage.objects(bucket_id,name)",
  );
  for (
    const file of [
      "20261028134424_audio_comment_publication_ledger.sql",
      "20261028145414_audio_comment_gateway_boundary.sql",
      "20261028151901_audio_comment_cleanup_fencing.sql",
      "20261028153218_audio_comment_upload_recovery.sql",
      "20261028185429_audio_comment_keyset_pages.sql",
      "20261028191118_audio_comment_shared_reads.sql",
    ]
  ) {
    await pg.raw(
      await readFile(
        new URL("../../supabase/migrations/" + file, import.meta.url),
        "utf8",
      ),
    );
  }
  report.baselineAdvisors = await pg.advisors();
  assert(process.argv[3], "Supply the reviewed owner-status SQL path");
  await pg.raw(await readFile(process.argv[3], "utf8"));
  const actor = randomUUID(),
    session = randomUUID(),
    other = randomUUID(),
    otherSession = randomUUID(),
    task = randomUUID(),
    generation = randomUUID();
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at) values(${
      lit(actor)
    },'owner-status@example.invalid',now()),(${
      lit(other)
    },'other-status@example.invalid',now());insert into auth.sessions(id,user_id) values(${
      lit(session)
    },${lit(actor)}),(${lit(otherSession)},${
      lit(other)
    });insert into public.profiles(user_id) values(${lit(actor)}),(${
      lit(other)
    });insert into public.tasks(id,user_id,task_generation,title) values(${
      lit(task)
    },${lit(actor)},${
      lit(generation)
    },'Synthetic original');update taskfold_private.audio_comment_config set enabled=true`,
  );
  const media = await readFile(
    new URL(
      "../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
      import.meta.url,
    ),
  );
  const intent = () => ({
    version: 1,
    account: actor,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target: { task_id: task, task_generation: generation, project_id: null },
    caption: "Literal cafe\u0301 🪴",
    audio: {
      version: 1,
      mime_type: "audio/mp4",
      byte_count: media.length,
      duration_ms: 1000,
      sha256: createHash("sha256").update(media).digest("hex"),
    },
  });
  const command = (kind, b, a = actor, s = session) =>
    pg.scalar(
      `select public.taskfold_audio_comment_command(${lit(kind)},${lit(a)},${
        lit(s)
      },${j(b)})`,
    );
  const resolve = (i, close = false, a = actor, s = session) =>
    pg.scalar(
      `select public.taskfold_audio_owner_publication(${lit(a)},${lit(s)},${
        j({ intent: i, close })
      })`,
    );
  const absent = intent();
  check(
    "absent check remains uncertain",
    (await resolve(absent)).state,
    "unconfirmed",
  );
  check(
    "read-only check creates no marker",
    await pg.scalar(
      "select to_jsonb(count(*)::int) from taskfold_private.audio_closed_operations",
    ),
    0,
  );
  check(
    "explicit absent close returns exact proof",
    await resolve(absent, true),
    { protocol: 1, intent: absent, state: "closed" },
  );
  check(
    "late reserve cannot resurrect closed absent operation",
    (await command("reserve", absent)).status,
    "retired",
  );
  check(
    "late finalize cannot resurrect closed absent operation",
    (await command("finalize", {
      intent: absent,
      stored_sha256: absent.audio.sha256,
      stored_bytes: media.length,
    })).status,
    "retired",
  );
  check(
    "absent closure allocates no publication or task quota",
    await pg.scalar(
      "select to_jsonb(count(*)::int) from taskfold_private.audio_comment_publications",
    ),
    0,
  );
  check(
    "changed literal intent cannot adopt marker",
    (await resolve({ ...absent, caption: "Literal café 🪴" })).status,
    "conflict",
  );
  const foreign = {
    ...absent,
    account: other,
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target: {
      task_id: randomUUID(),
      task_generation: randomUUID(),
      project_id: null,
    },
  };
  check(
    "actor-qualified marker does not masquerade as another actor proof",
    (await resolve(foreign, false, other, otherSession)).state,
    "unconfirmed",
  );
  await pg.raw(
    `insert into public.tasks(id,user_id,task_generation,title) values(${
      lit(foreign.target.task_id)
    },${lit(other)},${
      lit(foreign.target.task_generation)
    },'Synthetic independent actor')`,
  );
  check(
    "one actor marker cannot block another actor reservation",
    (await command("reserve", foreign, other, otherSession)).state,
    "pending",
  );
  check(
    "original actor still sees only own closure",
    (await resolve(absent, true)).state,
    "closed",
  );
  check(
    "own closure cannot alter another actor same-UUID row",
    await pg.scalar(
      `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
        lit(foreign.operation_id)
      }`,
    ),
    "pending",
  );
  check(
    "wrong actor cannot inspect original intent",
    (await resolve(absent, false, other, otherSession)).status,
    "unavailable",
  );
  const closeWins = intent();
  const closer = await pg.hold(
    `select public.taskfold_audio_owner_publication(${lit(actor)},${
      lit(session)
    },${j({ intent: closeWins, close: true })})`,
  );
  const reserveWorker = pg.value(
    `public.taskfold_audio_comment_command('reserve',${lit(actor)},${
      lit(session)
    },${j(closeWins)})`,
    { app: "owner-status-reserve-race" },
  );
  await pg.waitForLock("owner-status-reserve-race", closer.pid);
  check("late reservation really waits for closing transaction", true);
  await closer.release();
  const reserveReply = await reserveWorker;
  check(
    "closing wins concurrent absent reserve race",
    reserveReply.value?.status,
    "retired",
  );
  const reserveWins = intent(),
    reserver = await pg.hold(
      `select public.taskfold_audio_comment_command('reserve',${lit(actor)},${
        lit(session)
      },${j(reserveWins)})`,
    );
  const closeWorker = pg.value(
    `public.taskfold_audio_owner_publication(${lit(actor)},${lit(session)},${
      j({ intent: reserveWins, close: true })
    })`,
    { app: "owner-status-close-race" },
  );
  await pg.waitForLock("owner-status-close-race", reserver.pid);
  check("closing really waits for reservation transaction", true);
  await reserver.release();
  const closeReply = await closeWorker;
  check(
    "reservation-first race still ends with closed original",
    closeReply.value?.state,
    "closed",
  );
  check(
    "reservation-first race retains retired server fence",
    await pg.scalar(
      `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
        lit(reserveWins.operation_id)
      }`,
    ),
    "retired",
  );
  const liveStop = intent();
  await command("reserve", liveStop);
  check(
    "explicit close retires an unexpired pending send",
    (await resolve(liveStop, true)).state,
    "closed",
  );
  check(
    "closed live pending cannot resume",
    (await command("reserve", liveStop)).status,
    "retired",
  );
  const pending = intent();
  check(
    "ordinary reserve remains available",
    (await command("reserve", pending)).state,
    "pending",
  );
  const lease = await command("upload_begin", {
    operation_id: pending.operation_id,
  });
  check("real upload lease opens", lease.state, "open");
  check(
    "pending check never resumes upload",
    (await resolve(pending)).state,
    "unconfirmed",
  );
  await pg.raw(`delete from public.tasks where id=${lit(task)}`);
  check(
    "owner can close after original task is deleted",
    (await resolve(pending, true)).state,
    "closed",
  );
  check(
    "closing does not settle an unresolved upload",
    await pg.scalar(
      `select to_jsonb(count(*)::int) from taskfold_private.audio_upload_attempts where operation_id=${
        lit(pending.operation_id)
      } and state='open'`,
    ),
    1,
  );
  check(
    "closed original state remains retired",
    await pg.scalar(
      `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
        lit(pending.operation_id)
      }`,
    ),
    "retired",
  );
  check(
    "owner repeated status is stable",
    (await resolve(pending)).state,
    "closed",
  );

  const published = intent();
  published.target = {
    task_id: randomUUID(),
    task_generation: randomUUID(),
    project_id: null,
  };
  await pg.raw(
    `insert into public.tasks(id,user_id,task_generation,title) values(${
      lit(published.target.task_id)
    },${lit(actor)},${
      lit(published.target.task_generation)
    },'Synthetic published original')`,
  );
  http = await createAudioHttpFixture(pg, actor, session);
  const publication = await http.call("publish", {
    intent: published,
    audio_base64: media.toString("base64"),
  });
  check("real gateway publication baseline", publication.status, 200);
  await publication.arrayBuffer();
  const project = randomUUID(),
    sharedTask = randomUUID(),
    sharedGeneration = randomUUID();
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${lit(project)},${
      lit(other)
    },'Synthetic legacy shared');insert into public.tasks(id,user_id,project_id,task_generation,title) values(${
      lit(sharedTask)
    },${lit(other)},${lit(project)},${
      lit(sharedGeneration)
    },'Synthetic revoked source');alter table public.project_collaborators disable trigger taskfold_prepare_invitation;insert into public.project_collaborators(id,project_id,user_id,invited_by,status) values(${
      lit(randomUUID())
    },${lit(project)},${lit(actor)},${
      lit(other)
    },'accepted');alter table public.project_collaborators enable trigger taskfold_prepare_invitation`,
  );
  const shared = intent();
  shared.target = {
    task_id: sharedTask,
    task_generation: sharedGeneration,
    project_id: project,
  };
  check(
    "shared author can reserve before revocation",
    (await command("reserve", shared)).state,
    "pending",
  );
  await pg.raw(
    `delete from public.project_collaborators where project_id=${
      lit(project)
    } and user_id=${lit(actor)}`,
  );
  check(
    "owner status does not require lost project access",
    (await resolve(shared)).state,
    "unconfirmed",
  );
  check(
    "revoked author can stop only original send",
    (await resolve(shared, true)).state,
    "closed",
  );
  check(
    "owner history does not restore task read access",
    await pg.scalar(
      `select to_jsonb(taskfold_private.audio_read_scope(${lit(actor)},${
        lit(sharedTask)
      },${lit(sharedGeneration)},${lit(project)}))`,
    ),
    false,
  );
  const uploads = http.state.uploads;
  await pg.raw(
    "update taskfold_private.audio_comment_config set enabled=false",
  );
  const historical = await http.call("resolve", {
    intent: published,
    close: false,
  });
  check("owner history works with publishing disabled", historical.status, 200);
  check(
    "owner status returns only historical publication",
    (await historical.json()).receipt.operation_id,
    published.operation_id,
  );
  const noRemoval = await http.call("resolve", {
    intent: published,
    close: true,
  });
  check(
    "close cannot remove an already published comment",
    (await noRemoval.json()).receipt.state,
    "published",
  );
  check("status never starts a Storage upload", http.state.uploads, uploads);
  const unknown = intent(),
    stop = await http.call("resolve", { intent: unknown, close: true });
  check(
    "disabled publication still allows explicit cancellation",
    stop.status,
    200,
  );
  check(
    "cancellation returns closed proof",
    (await stop.json()).closed.state,
    "closed",
  );
  const revoked = await resolve(unknown, false, actor, otherSession);
  check(
    "foreign session cannot inspect owner operation",
    revoked.status,
    "unavailable",
  );
  await pg.raw(
    `update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id=${
      lit(session)
    }`,
  );
  check(
    "expired session cannot inspect owner operation",
    (await resolve(unknown)).status,
    "unavailable",
  );
  await pg.raw(
    `update auth.sessions set not_after=null where id=${lit(session)}`,
  );
  for (const role of ["anon", "authenticated"]) {
    check(
      role + " cannot call owner RPC",
      await pg.scalar(
        `select to_jsonb(has_function_privilege(${
          lit(role)
        },'public.taskfold_audio_owner_publication(uuid,uuid,jsonb)','EXECUTE'))`,
      ),
      false,
    );
    check(
      role + " cannot read private markers",
      await pg.scalar(
        `select to_jsonb(has_table_privilege(${
          lit(role)
        },'taskfold_private.audio_closed_operations','SELECT'))`,
      ),
      false,
    );
  }
  check(
    "service cannot bypass marker wrapper",
    await pg.scalar(
      "select to_jsonb(has_function_privilege('service_role','taskfold_private.audio_comment_before_owner_status(text,uuid,uuid,jsonb)','EXECUTE'))",
    ),
    false,
  );
  check(
    "new marker table has RLS",
    await pg.scalar(
      "select to_jsonb(relrowsecurity) from pg_class where oid='taskfold_private.audio_closed_operations'::regclass",
    ),
  );
  await pg.raw("update taskfold_private.audio_comment_config set enabled=true");
  const quotaKnown = intent();
  quotaKnown.target = published.target;
  await command("reserve", quotaKnown);
  await pg.raw(
    `insert into taskfold_private.audio_closed_operations(actor_id,operation_id,request_hash) select ${
      lit(actor)
    },gen_random_uuid(),decode(repeat('ab',32),'hex') from generate_series(1,1000-(select count(*) from taskfold_private.audio_closed_operations where actor_id=${
      lit(actor)
    }))`,
  );
  check(
    "marker quota refuses new absent cancellation without false closure",
    (await resolve(intent(), true)).status,
    "quota",
  );
  check(
    "marker quota does not prevent known pending cancellation",
    (await resolve(quotaKnown, true)).state,
    "closed",
  );
  check(
    "marker quota keeps earlier proof readable",
    (await resolve(absent)).state,
    "closed",
  );
  const deletedActor = randomUUID();
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at) values(${
      lit(deletedActor)
    },'deleted-marker@example.invalid',now());insert into taskfold_private.audio_closed_operations(actor_id,operation_id,request_hash) values(${
      lit(deletedActor)
    },gen_random_uuid(),decode(repeat('ab',32),'hex'));delete from auth.users where id=${
      lit(deletedActor)
    }`,
  );
  check(
    "new owner marker data follows Auth deletion",
    await pg.scalar(
      `select to_jsonb(count(*)::int) from taskfold_private.audio_closed_operations where actor_id=${
        lit(deletedActor)
      }`,
    ),
    0,
  );
  check("gateway fixture has no unexpected SQL errors", http.state.errors, []);
  report.finalAdvisors = await pg.advisors();
  const baseline = new Set(
    report.baselineAdvisors.result.map((x) => JSON.stringify(x)),
  );
  report.addedAdvisors = report.finalAdvisors.result.filter((x) =>
    !baseline.has(JSON.stringify(x))
  );
  check("no added advisor findings", report.addedAdvisors, []);
} finally {
  if (http) await http.close();
  if (pg) report.ownedPostgresContainerRemoved = await pg.close();
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
}
console.log(
  Object.keys(report.checks).length +
    " owner status database/gateway checks passed",
);
