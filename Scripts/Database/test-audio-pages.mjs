import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamProjectSchema } from "./team-project-schema.mjs";
const report = { checks: {}, deployed: false },
  check = (name, a, b = true) => {
    assert.deepEqual(a, b, name);
    report.checks[name] = true;
  };
let pg, http;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadTeamProjectSchema(pg.raw);
  await pg.raw(
    `alter table storage.buckets add column name text,add column file_size_limit bigint,add column allowed_mime_types text[];alter table storage.buckets enable row level security;alter table storage.objects add column metadata jsonb;create unique index audio_fixture_object_identity on storage.objects(bucket_id,name)`,
  );
  for (
    const name of [
      "20261028134424_audio_comment_publication_ledger.sql",
      "20261028145414_audio_comment_gateway_boundary.sql",
      "20261028151901_audio_comment_cleanup_fencing.sql",
      "20261028153218_audio_comment_upload_recovery.sql",
    ]
  ) {
    await pg.raw(
      await readFile(
        new URL("../../supabase/migrations/" + name, import.meta.url),
        "utf8",
      ),
    );
  }
  const baseline = await pg.advisors();
  await pg.raw(
    await readFile(
      process.argv[3] ??
        new URL(
          "../../supabase/migrations/20261028185429_audio_comment_keyset_pages.sql",
          import.meta.url,
        ),
      "utf8",
    ),
  );
  const actor = randomUUID(),
    session = randomUUID(),
    task = randomUUID(),
    generation = randomUUID(),
    target = { task_id: task, task_generation: generation, project_id: null };
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at) values(${
      lit(actor)
    },'pages@example.invalid',now());insert into auth.sessions(id,user_id) values(${
      lit(session)
    },${lit(actor)});insert into public.profiles(user_id) values(${
      lit(actor)
    });insert into public.tasks(id,user_id,task_generation,title) values(${
      lit(task)
    },${lit(actor)},${
      lit(generation)
    },'Synthetic pages');update taskfold_private.audio_comment_config set enabled=true`,
  );
  await pg.raw(
    `insert into taskfold_private.audio_comment_publications(operation_id,comment_id,asset_id,author_id,task_id,task_generation,request_hash,sha256,byte_count,caption,audio_descriptor,state,created_at,expires_at,published_at)
 select gen_random_uuid(),('aa000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,gen_random_uuid(),${
      lit(actor)
    },${lit(task)},${
      lit(generation)
    },decode(repeat('ab',32),'hex'),repeat('c',64),1,'Recording '||n,jsonb_build_object('version',1,'mime_type','audio/mp4','byte_count',1,'duration_ms',1000,'sha256',repeat('c',64)),'published','2026-10-28T12:00:00Z','2026-10-29T12:00:00Z',case when n<=25 then '2026-10-28T12:01:00.123456Z'::timestamptz else '2026-10-28T12:01:00.123457Z'::timestamptz end from generate_series(1,45) n`,
  );
  const call = (
    after = null,
    who = actor,
    sess = session,
    t = target,
    role = "service_role",
  ) =>
    pg.value(
      `public.taskfold_audio_comment_page(${lit(who)},${lit(sess)},${
        lit(JSON.stringify({ target: t, after }))
      }::jsonb)`,
      { role },
    );
  http = await createAudioHttpFixture(pg, actor, session);
  const gateway = async (after) => {
    const response = await fetch(http.nativeEndpoint + "/?action=page", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + http.nativeToken,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ target, after }),
    });
    return { status: response.status, body: await response.json() };
  };
  const first = (await call()).value;
  check(
    "first page has 20 ordered records",
    first.items.map((x) => x.caption),
    Array.from({ length: 20 }, (_, n) => "Recording " + (n + 1)),
  );
  check(
    "cursor keeps full microseconds",
    first.next.published_at,
    "2026-10-28T12:01:00.123456+00:00",
  );
  check("cursor is exact final item", {
    published_at: first.items[19].published_at,
    comment_id: first.items[19].comment_id,
  }, first.next);
  const firstHTTP = await gateway(null);
  check(
    "actual gateway returns twenty and exact cursor",
    firstHTTP.body.next,
    first.next,
  );
  check(
    "actual gateway strips custody paths",
    firstHTTP.body.items.every((x) =>
      !("object_name" in x) && !("bucket" in x)
    ),
  );
  check("actual gateway first page status", firstHTTP.status, 200);
  await pg.raw(
    `delete from taskfold_private.audio_comment_publications where comment_id=${
      lit(first.next.comment_id)
    }`,
  );
  const second = (await call(first.next)).value;
  check(
    "deleted cursor row does not lose following rows",
    second.items.map((x) => x.caption),
    Array.from({ length: 20 }, (_, n) => "Recording " + (n + 21)),
  );
  const secondHTTP = await gateway(first.next);
  check(
    "actual gateway continues after deleted cursor",
    secondHTTP.body.items.map((x) => x.comment_id),
    second.items.map((x) => x.comment_id),
  );
  const third = (await call(second.next)).value;
  check(
    "final page crosses microsecond boundary without skips",
    third.items.map((x) => x.caption),
    Array.from({ length: 5 }, (_, n) => "Recording " + (n + 41)),
  );
  check("final page has no next", third.next, null);
  const ids = [...first.items, ...second.items, ...third.items].map((x) =>
    x.comment_id
  );
  check("three pages contain 45 distinct identities", new Set(ids).size, 45);
  check(
    "replayed cursor gives stable same page",
    (await call(first.next)).value,
    second,
  );
  check(
    "forged session cannot use cursor",
    (await call(first.next, actor, randomUUID())).value.status,
    "unavailable",
  );
  check(
    "foreign actor cannot use cursor",
    (await call(first.next, randomUUID(), session)).value.status,
    "unavailable",
  );
  check(
    "cursor does not authorize another task generation",
    (await call(first.next, actor, session, {
      ...target,
      task_generation: randomUUID(),
    })).value.status,
    "unavailable",
  );
  for (const role of ["anon", "authenticated"]) {
    let refused = false;
    try {
      await pg.raw(
        `set role ${role};select public.taskfold_audio_comment_page(${
          lit(actor)
        },${lit(session)},${
          lit(JSON.stringify({ target, after: null }))
        }::jsonb)`,
      );
    } catch (error) {
      refused = error.code === "42501";
    }
    check(role + " cannot call service wrapper", refused);
  }

  for (
    const after of [{ ...first.next, extra: true }, {
      ...first.next,
      published_at: "infinity",
    }, { ...first.next, comment_id: "not-a-uuid" }]
  ) {
    check(
      "malformed cursor " + JSON.stringify(after),
      (await call(after)).code,
      "22023",
    );
  }
  const intent = {
    version: 1,
    account: actor,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target,
    caption: "Paged reservation",
    audio: {
      version: 1,
      mime_type: "audio/mp4",
      byte_count: 1,
      duration_ms: 1000,
      sha256: "c".repeat(64),
    },
  };
  const reserve = () =>
    pg.value(
      `public.taskfold_audio_comment_command('reserve',${lit(actor)},${
        lit(session)
      },${lit(JSON.stringify(intent))}::jsonb)`,
    );
  check(
    "task can reserve after forty-four published recordings",
    (await reserve()).value.state,
    "pending",
  );
  const peer=randomUUID();await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(peer)},'page-peer@example.invalid',now())`);
  await pg.raw(
    `insert into taskfold_private.audio_comment_publications(operation_id,comment_id,asset_id,author_id,task_id,task_generation,request_hash,sha256,byte_count,caption,audio_descriptor) select gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),${
      lit(peer)
    },${lit(task)},${
      lit(generation)
    },decode(repeat('ab',32),'hex'),repeat('c',64),1,'Quota fixture','${
      JSON.stringify(intent.audio)
    }'::jsonb from generate_series(1,55)`,
  );
  intent.operation_id = randomUUID();
  intent.comment_id = randomUUID();
  intent.asset_id = randomUUID();
  check(
    "task quota still enforces one hundred independently of author quota",
    (await reserve()).value.status,
    "quota",
  );
  await pg.raw(`delete from auth.sessions where id=${lit(session)}`);
  check(
    "revocation between pages is enforced",
    (await call(first.next)).value.status,
    "unavailable",
  );
  check("gateway adapter has no routing or SQL errors", http.state.errors, []);
  const end = await pg.advisors();
  check(
    "no added advisor findings",
    end.result.filter((x) =>
      !baseline.result.some((y) => y.cache_key === x.cache_key)
    ),
    [],
  );
  report.advisors = end;
} finally {
  if (http) await http.close();
  if (pg) report.ownedPostgresContainerRemoved = await pg.close();
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
}
console.log(
  Object.keys(report.checks).length + " PostgreSQL pagination checks passed",
);
