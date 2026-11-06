import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamProjectSchema } from "./team-project-schema.mjs";
const report = {
  checks: {},
  deployed: false,
  storageBytesTransferred: false,
  httpOrNativeAcceptanceClaimed: false,
  realDataChanged: false,
};
const check = (name, actual, expected) => {
  assert.deepEqual(actual, expected, name);
  report.checks[name] = true;
};
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
let source = await readFile(
  new URL(
    "../../supabase/migrations/20261028134424_audio_comment_publication_ledger.sql",
    import.meta.url,
  ),
  "utf8",
);
// The only mutation probe is applied to a fresh owned fixture, never to the
// migration file, hosted schema, app configuration or user records.
report.migrationOnDiskSHA256 = createHash("sha256").update(source).digest(
  "hex",
);
const probe = process.env.TASKFOLD_AUDIO_LEDGER_TEST_PROBE ?? "";
assert(
  ["", "missing-task-quota-lock", "personal-custody"].includes(probe),
  "Unknown fixture probe",
);
if (probe === "missing-task-quota-lock") {
  const line =
    " perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('audio-task:'||t::text,20261028));\n";
  assert(source.includes(line));
  source = source.replace(line, "");
  report.fixtureProbe = probe;
}
if (probe === "personal-custody") {
  const condition =
    "(old.project_id is null and new.user_id is distinct from old.user_id) or ";
  assert(source.includes(condition));
  source = source.replace(condition, "");
  report.fixtureProbe = probe;
}
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  report.postgresVersion = pg.serverVersion;
  await loadTeamProjectSchema(pg.raw);
  report.baselineAdvisors = await pg.advisors();
  await pg.raw(source);
  report.migrationSHA256 = createHash("sha256").update(source).digest("hex");
  const person = async (name) => {
    const p = {
      id: randomUUID(),
      session: randomUUID(),
      email: name + "@example.invalid",
    };
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(p.id)
      },${
        lit(name + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${lit(p.session)},${
        lit(p.id)
      });insert into public.profiles(user_id) values(${lit(p.id)});`,
    );
    return p;
  };
  const owner = await person("audio-owner"),
    member = await person("audio-member"),
    other = await person("audio-other"),
    stranger = await person("audio-outsider");
  const project = async (name) => {
    const id = randomUUID();
    await pg.raw(
      `insert into public.projects(id,user_id,name) values(${lit(id)},${
        lit(owner.id)
      },${lit(name)})`,
    );
    return id;
  };
  const shared = await project("Shared recording review"),
    destination = await project("Other project");
  const admit = async (p, u) =>
    pg.raw(
      `set request.jwt.claim.sub=${
        lit(owner.id)
      };insert into public.project_collaborators(id,project_id,invited_email,invited_by,status) values(${
        lit(randomUUID())
      },${lit(p)},${lit(u.email)},${
        lit(owner.id)
      },'pending');set request.jwt.claim.sub=${
        lit(u.id)
      };update public.project_collaborators set status='accepted' where project_id=${
        lit(p)
      } and user_id=${lit(u.id)}`,
    );
  await admit(shared, member);
  await admit(shared, other);
  const task = async (u, p = null) => {
    const t = {
      task_id: randomUUID(),
      task_generation: randomUUID(),
      project_id: p,
    };
    await pg.raw(
      `insert into public.tasks(id,user_id,project_id,task_generation,title) values(${
        lit(t.task_id)
      },${lit(u.id)},${p ? lit(p) : "null"},${
        lit(t.task_generation)
      },'Synthetic recording target')`,
    );
    return t;
  };
  const own = await task(owner), team = await task(owner, shared);
  const intent = (u, target, changes = {}) => ({
    version: 1,
    account: u.id,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target,
    caption: "  cafe\u0301\nمراجعة 🪴  ",
    audio: {
      version: 1,
      mime_type: "audio/mp4",
      byte_count: 12345,
      duration_ms: 1000,
      sha256: "a".repeat(64),
    },
    ...changes,
  });
  const command = (action, body, u = owner) =>
    pg.value(
      `public.taskfold_audio_comment_command(${lit(action)},${
        u ? lit(u.id) : "null"
      },${u ? lit(u.session) : "null"},${json(body)})`,
    );
  const success = async (action, body, u = owner) => {
    const r = await command(action, body, u);
    assert.equal(r.code, null, JSON.stringify(r));
    return r.value;
  };
  const publish = async (i) => {
    const u = [owner, member, other, stranger].find((p) => p.id === i.account);
    const r = await success("reserve", i, u);
    assert.equal(r.state, "pending");
    return success("finalize", {
      intent: i,
      stored_sha256: i.audio.sha256,
      stored_bytes: i.audio.byte_count,
    }, u);
  };
  const count = () =>
    pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.audio_comment_publications`,
    );
  const i = intent(owner, own);
  check(
    "publishing is disabled by default",
    (await success("reserve", i)).status,
    "disabled",
  );
  check(
    "authenticated cannot call service RPC",
    await pg.scalar(
      `select to_jsonb(has_function_privilege('authenticated','public.taskfold_audio_comment_command(text,uuid,uuid,jsonb)','execute'))`,
    ),
    false,
  );
  check(
    "anonymous cannot call service RPC",
    await pg.scalar(
      `select to_jsonb(has_function_privilege('anon','public.taskfold_audio_comment_command(text,uuid,uuid,jsonb)','execute'))`,
    ),
    false,
  );
  check(
    "service cannot directly rewrite publication ledger",
    await pg.scalar(
      `select to_jsonb(has_table_privilege('service_role','taskfold_private.audio_comment_publications','insert,update,delete'))`,
    ),
    false,
  );
  check(
    "client cannot read private caption rows",
    await pg.scalar(
      `select to_jsonb(has_table_privilege('authenticated','taskfold_private.audio_comment_publications','select'))`,
    ),
    false,
  );
  try {
    await pg.raw(
      `set role authenticated;select public.taskfold_audio_comment_command('reserve',${
        lit(owner.id)
      },${lit(owner.session)},${json(i)})`,
    );
    assert.fail("client RPC executed");
  } catch (e) {
    check("actual authenticated RPC invocation is denied", e.code, "42501");
  }
  check(
    "public service wrapper is security invoker",
    await pg.scalar(
      `select to_jsonb(not prosecdef) from pg_proc where oid='public.taskfold_audio_comment_command(text,uuid,uuid,jsonb)'::regprocedure`,
    ),
    true,
  );
  check(
    "private state and gate use RLS",
    await pg.scalar(
      `select to_jsonb(bool_and(relrowsecurity)) from pg_class where oid in('taskfold_private.audio_comment_publications'::regclass,'taskfold_private.audio_comment_config'::regclass)`,
    ),
    true,
  );
  await pg.raw(`update taskfold_private.audio_comment_config set enabled=true`);
  check(
    "a user command cannot request a cleanup manifest",
    (await command("cleanup", {})).code,
    "22023",
  );
  check(
    "a user command cannot attest physical deletion",
    (await command("purged", {})).code,
    "22023",
  );
  const reserved = await success("reserve", i);
  check("reserve freezes exact literal caption", reserved.caption, i.caption);
  check(
    "server reservation records its actual expiry",
    Math.abs(
      Date.parse(reserved.expires_at) - Date.parse(reserved.reserved_at) -
        86400000,
    ) < 1000,
    true,
  );
  check(
    "reserve keeps immutable current task incarnation",
    reserved.target,
    own,
  );
  check(
    "object path is generated from bound UUIDs",
    reserved.object_name,
    `audio-comments/v1/${own.task_id}/${own.task_generation}/${i.asset_id}.m4a`,
  );
  check(
    "reservation carries no downloadable URL",
    Object.keys(reserved).some((k) => /url/i.test(k)),
    false,
  );
  check(
    "same reserve is stable across retries",
    await success("reserve", i),
    reserved,
  );
  check(
    "pending reservation is not visible as a published comment",
    (await success("list", own)).items,
    [],
  );
  check(
    "pending comment read is unavailable",
    (await success("read", { comment_id: i.comment_id })).status,
    "unavailable",
  );
  check(
    "finalize requires prior reservation",
    (await success("finalize", {
      intent: intent(owner, own),
      stored_sha256: i.audio.sha256,
      stored_bytes: 12345,
    })).status,
    "unavailable",
  );
  check(
    "wrong service-observed digest cannot finalize",
    (await success("finalize", {
      intent: i,
      stored_sha256: "b".repeat(64),
      stored_bytes: 12345,
    })).status,
    "verification_failed",
  );
  check(
    "wrong service-observed byte count cannot finalize",
    (await success("finalize", {
      intent: i,
      stored_sha256: i.audio.sha256,
      stored_bytes: 12346,
    })).status,
    "verification_failed",
  );
  const ack = await success("finalize", {
    intent: i,
    stored_sha256: i.audio.sha256,
    stored_bytes: 12345,
  });
  check(
    "matching service attestation transitions to published",
    ack.state,
    "published",
  );
  check(
    "published acknowledgement records a server timestamp",
    Number.isFinite(Date.parse(ack.published_at)),
    true,
  );
  check(
    "lost-reply reserve returns the original acknowledgement",
    await success("reserve", i),
    ack,
  );
  check(
    "lost-reply finalize returns the original acknowledgement",
    await success("finalize", {
      intent: i,
      stored_sha256: i.audio.sha256,
      stored_bytes: 12345,
    }),
    ack,
  );
  check("retries do not duplicate metadata rows", await count(), 1);
  check(
    "current owner can read bound published metadata",
    await success("read", { comment_id: i.comment_id }),
    ack,
  );
  check(
    "another account cannot read personal metadata",
    (await success("read", { comment_id: i.comment_id }, stranger)).status,
    "unavailable",
  );
  check(
    "same operation with changed caption is refused",
    (await success("reserve", { ...i, caption: "Different" })).status,
    "conflict",
  );
  check(
    "same operation with normalized caption is refused",
    (await success("reserve", { ...i, caption: i.caption.normalize("NFC") }))
      .status,
    "conflict",
  );
  check(
    "claimed account cannot impersonate another session",
    (await success("reserve", { ...i, account: member.id })).status,
    "unavailable",
  );
  check(
    "wrong target generation cannot reserve",
    (await success(
      "reserve",
      intent(owner, { ...own, task_generation: randomUUID() }),
    )).status,
    "unavailable",
  );
  check(
    "wrong target project cannot reserve",
    (await success("reserve", intent(owner, { ...own, project_id: shared })))
      .status,
    "unavailable",
  );
  check(
    "same asset cannot be borrowed for another operation",
    (await command("reserve", { ...intent(owner, own), asset_id: i.asset_id }))
      .code,
    "23505",
  );
  const invalid = [
    { ...i, url: "https://example.invalid/audio" },
    { ...i, version: 2 },
    { ...i, caption: "x".repeat(4001) },
    { ...i, asset_id: "00000000-0000-0000-0000-000000000000" },
    { ...i, target: { ...own, filename: "../../audio" } },
    { ...i, audio: { ...i.audio, byte_count: 8000001 } },
    { ...i, audio: { ...i.audio, duration_ms: 120001 } },
    { ...i, audio: { ...i.audio, mime_type: "video/mp4" } },
    { ...i, audio: { ...i.audio, sha256: "A".repeat(64) } },
    { ...i, audio: { ...i.audio, byte_count: 1.5 } },
    { ...i, target: [] },
    { ...i, caption: null },
  ];
  for (let n = 0; n < invalid.length; n++) {
    check(
      "malformed intent " + n + " is refused without mutation",
      (await command("reserve", invalid[n])).code,
      "22023",
    );
  }
  check(
    "all invalid requests preserve the original row count",
    await count(),
    1,
  );
  const escaped = intent(owner, own, { caption: "\u0001".repeat(4000) });
  check(
    "maximum escaped four-KB caption is preserved",
    (await success("reserve", escaped)).caption,
    escaped.caption,
  );
  await success("remove", { comment_id: escaped.comment_id });
  const bad = { ...owner, session: member.session };
  check(
    "session belonging to another user is rejected",
    (await success("read", { comment_id: i.comment_id }, bad)).status,
    "unavailable",
  );
  await pg.raw(
    `update auth.users set banned_until=clock_timestamp()+interval '1 hour' where id=${
      lit(owner.id)
    }`,
  );
  check(
    "banned account cannot read old acknowledgement",
    (await success("reserve", i)).status,
    "unavailable",
  );
  await pg.raw(
    `update auth.users set banned_until=null where id=${
      lit(owner.id)
    };delete from auth.sessions where id=${lit(owner.session)}`,
  );
  check(
    "removed session cannot reuse an earlier publication",
    (await success("reserve", i)).status,
    "unavailable",
  );
  owner.session = randomUUID();
  await pg.raw(
    `insert into auth.sessions(id,user_id) values(${lit(owner.session)},${
      lit(owner.id)
    })`,
  );
  await pg.raw(
    `insert into taskfold_private.account_removal_receipts(token_hash,account_id) values('${
      "c".repeat(64)
    }',${lit(owner.id)})`,
  );
  check(
    "pending account removal blocks publication metadata reads",
    (await success("read", { comment_id: i.comment_id })).status,
    "unavailable",
  );
  await pg.raw(
    `delete from taskfold_private.account_removal_receipts where account_id=${
      lit(owner.id)
    }`,
  );
  const sharedIntent = intent(member, team),
    sharedAck = await publish(sharedIntent);
  check(
    "accepted legacy collaborator can reserve and attest",
    sharedAck.state,
    "published",
  );
  check(
    "another accepted collaborator can read published metadata",
    (await success("read", { comment_id: sharedIntent.comment_id }, other))
      .caption,
    sharedIntent.caption,
  );
  check(
    "unrelated account cannot read shared metadata",
    (await success("read", { comment_id: sharedIntent.comment_id }, stranger))
      .status,
    "unavailable",
  );
  await pg.raw(
    `set request.jwt.claim.sub=${
      lit(member.id)
    };update public.project_collaborators set status='declined' where project_id=${
      lit(shared)
    } and user_id=${lit(member.id)}`,
  );
  check(
    "removed membership defeats even the original author receipt",
    (await success("reserve", sharedIntent, member)).status,
    "unavailable",
  );
  check(
    "removed author cannot delete through stale authority",
    (await success("remove", { comment_id: sharedIntent.comment_id }, member))
      .status,
    "unavailable",
  );
  check(
    "other collaborator cannot moderate another author",
    (await success("remove", { comment_id: sharedIntent.comment_id }, other))
      .status,
    "unavailable",
  );
  const archivedTask = await task(owner, destination),
    archivedIntent = intent(owner, archivedTask);
  await publish(archivedIntent);
  await pg.raw(
    `update public.projects set is_archived=true where id=${lit(destination)}`,
  );
  check(
    "archiving retains readable published metadata",
    (await success("reserve", archivedIntent)).state,
    "published",
  );
  check(
    "archived project refuses a new reservation",
    (await success("reserve", intent(owner, archivedTask))).status,
    "unavailable",
  );
  await pg.raw(
    `update public.projects set is_archived=false where id=${lit(destination)}`,
  );
  async function refusedSQL(name, sql, code) {
    try {
      await pg.raw(sql);
      assert.fail(name);
    } catch (e) {
      check(name, e.code, code);
    }
  }
  await refusedSQL(
    "personal task ownership cannot retarget a live recording",
    `update public.tasks set user_id=${lit(stranger.id)} where id=${
      lit(own.task_id)
    }`,
    "23514",
  );
  await refusedSQL(
    "task identity cannot orphan a live recording",
    `update public.tasks set id=${lit(randomUUID())} where id=${
      lit(own.task_id)
    }`,
    "23514",
  );
  await refusedSQL(
    "move with live recording is blocked",
    `update public.tasks set project_id=${lit(destination)} where id=${
      lit(team.task_id)
    }`,
    "23514",
  );
  await refusedSQL(
    "generation replacement with live recording is blocked",
    `update public.tasks set task_generation=${lit(randomUUID())} where id=${
      lit(team.task_id)
    }`,
    "23514",
  );
  await pg.raw(`alter table public.tasks add column is_heading boolean`);
  await refusedSQL(
    "heading conversion with live recording is blocked",
    `update public.tasks set is_heading=true where id=${lit(team.task_id)}`,
    "23514",
  );
  check(
    "failed custody changes preserve original task location",
    await pg.scalar(
      `select to_jsonb(project_id) from public.tasks where id=${
        lit(team.task_id)
      }`,
    ),
    shared,
  );
  const heading = await task(owner);
  await pg.raw(
    `update public.tasks set is_heading=true where id=${lit(heading.task_id)}`,
  );
  check(
    "heading is never admitted as an audio target",
    (await success("reserve", intent(owner, heading))).status,
    "unavailable",
  );
  await pg.raw(`delete from auth.users where id=${lit(member.id)}`);
  const surviving = await success("read", {
    comment_id: sharedIntent.comment_id,
  }, other);
  check(
    "published shared recording outlives uploader removal",
    surviving.state,
    "published",
  );
  check(
    "uploader removal clears authorship identity",
    surviving.author_id,
    null,
  );
  check(
    "uploader removal retains shared authored caption",
    surviving.caption,
    sharedIntent.caption,
  );
  check(
    "project owner can explicitly retire another authors recording",
    (await success("remove", { comment_id: sharedIntent.comment_id })).state,
    "retired",
  );
  check(
    "retired recording is no longer readable",
    (await success("read", { comment_id: sharedIntent.comment_id }, other))
      .status,
    "unavailable",
  );
  check(
    "retirement clears authored metadata",
    await pg.scalar(
      `select jsonb_build_array(caption,audio_descriptor) from taskfold_private.audio_comment_publications where comment_id=${
        lit(sharedIntent.comment_id)
      }`,
    ),
    [null, null],
  );
  check(
    "cleanup does not prematurely nominate a fresh retirement",
    (await success("cleanup", {}, null)).items.some((x) =>
      x.asset_id === sharedIntent.asset_id
    ),
    false,
  );
  await pg.raw(
    `update taskfold_private.audio_comment_publications set cleanup_after=clock_timestamp()-interval '1 second' where comment_id=${
      lit(sharedIntent.comment_id)
    }`,
  );
  const cleanup = await success("cleanup", {}, null);
  check(
    "retirement enters a bounded service-only cleanup manifest",
    cleanup.items.some((x) => x.asset_id === sharedIntent.asset_id) &&
      cleanup.items.length <= 25,
    true,
  );
  check(
    "published recording cannot be marked purged",
    (await success("purged", {
      operation_id: i.operation_id,
      asset_id: i.asset_id,
      object_name: reserved.object_name,
    }, null)).purged,
    false,
  );
  check(
    "cleanup acknowledgement rejects another asset",
    (await success("purged", {
      operation_id: sharedIntent.operation_id,
      asset_id: randomUUID(),
      object_name: cleanup.items[0].object_name,
    }, null)).purged,
    false,
  );
  check(
    "exact cleanup acknowledgement preserves a tombstone",
    (await success(
      "purged",
      cleanup.items.map(({ operation_id, asset_id, object_name }) => ({
        operation_id,
        asset_id,
        object_name,
      }))[0],
      null,
    )).purged,
    true,
  );
  const removedOwn = await success("remove", { comment_id: i.comment_id });
  check(
    "author can retire their personal recording",
    removedOwn.state,
    "retired",
  );
  check(
    "retired operation cannot be replayed into a new comment",
    (await success("reserve", i)).status,
    "retired",
  );
  const deletedTask = await task(owner),
    deletedIntent = intent(owner, deletedTask);
  await publish(deletedIntent);
  await pg.raw(`delete from public.tasks where id=${lit(deletedTask.task_id)}`);
  check(
    "explicit task deletion retires rather than forgets media",
    await pg.scalar(
      `select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${
        lit(deletedIntent.operation_id)
      }`,
    ),
    "retired",
  );
  const deletedProject = await project("Delete synthetic project"),
    projectTask = await task(owner, deletedProject),
    projectIntent = intent(owner, projectTask);
  await publish(projectIntent);
  await pg.raw(`delete from public.projects where id=${lit(deletedProject)}`);
  check(
    "explicit project deletion retires media without moving it into Inbox",
    await pg.scalar(
      `select jsonb_build_array(state,project_id,caption) from taskfold_private.audio_comment_publications where operation_id=${
        lit(projectIntent.operation_id)
      }`,
    ),
    ["retired", deletedProject, null],
  );
  const expTask = await task(owner), exp = intent(owner, expTask);
  await success("reserve", exp);
  await pg.raw(
    `update taskfold_private.audio_comment_publications set expires_at=clock_timestamp()-interval '1 second' where operation_id=${
      lit(exp.operation_id)
    }`,
  );
  check(
    "expired reservation cannot publish",
    (await success("finalize", {
      intent: exp,
      stored_sha256: exp.audio.sha256,
      stored_bytes: 12345,
    })).status,
    "expired",
  );
  check(
    "expired reservation does not silently create fresh identities",
    (await success("reserve", exp)).status,
    "retired",
  );
  // Real concurrent service commands: two different actors share one task cap.
  const capTask = await task(owner, shared);
  for (let n = 0; n < 19; n++) {
    const q = intent(owner, capTask);
    await success("reserve", q);
  }
  const finalSlot = intent(owner, capTask),
    secondSlot = intent(other, capTask),
    quotaApp = "audio-task-quota-" + randomUUID().slice(0, 8);
  const slotHolder = await pg.hold(
    `set local role service_role;select public.taskfold_audio_comment_command('reserve',${
      lit(owner.id)
    },${lit(owner.session)},${json(finalSlot)})`,
  );
  const contender = pg.value(
    `public.taskfold_audio_comment_command('reserve',${lit(other.id)},${
      lit(other.session)
    },${json(secondSlot)})`,
    { app: quotaApp },
  );
  let taskLock = false;
  try {
    taskLock =
      (await pg.waitForLock(quotaApp, slotHolder.pid)).event === "advisory";
  } catch {
    /* A removed lock must produce a deterministic failing regression. */
  }
  await slotHolder.release("commit");
  const raced = await contender;
  check(
    "other actor waits for the actual task quota transaction",
    taskLock,
    true,
  );
  check(
    "concurrent actors cannot overbook the final task slot",
    raced.value.status,
    "quota",
  );
  check(
    "task quota remains exactly twenty after the race",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.audio_comment_publications where task_id=${
        lit(capTask.task_id)
      } and state<>'purged'`,
    ),
    20,
  );
  const byteTask = await task(owner);
  for (let n = 0; n < 6; n++) {
    const q = intent(owner, byteTask);
    q.audio.byte_count = 8000000;
    await success("reserve", q);
  }
  const extra = intent(owner, byteTask);
  extra.audio.byte_count = 2000001;
  check(
    "task byte quota includes pending unverified uploads",
    (await success("reserve", extra)).status,
    "quota",
  );
  const beforeRetire = await pg.scalar(
    `select to_jsonb(count(*)) from taskfold_private.audio_comment_publications where task_id=${
      lit(byteTask.task_id)
    }`,
  );
  await pg.raw(
    `update taskfold_private.audio_comment_publications set state='retired',caption=null,audio_descriptor=null,cleanup_after=clock_timestamp() where task_id=${
      lit(byteTask.task_id)
    }`,
  );
  check(
    "retired unpurged bytes still consume quota",
    (await success("reserve", extra)).status,
    "quota",
  );
  check(
    "quota refusal creates no extra reservation",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.audio_comment_publications where task_id=${
        lit(byteTask.task_id)
      }`,
    ),
    beforeRetire,
  );
  // Seed valid private metadata and task identities to test account boundaries.
  // These are SQL-only size declarations, not real media uploads.
  async function seedQuota(u, n, byteCount) {
    await pg.raw(
      `with targets as(insert into public.tasks(id,user_id,title,task_generation) select gen_random_uuid(),${
        lit(u.id)
      },'Synthetic quota target',gen_random_uuid() from generate_series(1,${n}) returning id,task_generation)
  insert into taskfold_private.audio_comment_publications(operation_id,comment_id,asset_id,author_id,task_id,task_generation,request_hash,sha256,byte_count,caption,audio_descriptor)
  select gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),${
        lit(u.id)
      },id,task_generation,extensions.digest('quota fixture','sha256'),'${
        "a".repeat(64)
      }',${byteCount},'',jsonb_build_object('version',1,'mime_type','audio/mp4','byte_count',${byteCount},'duration_ms',1000,'sha256','${
        "a".repeat(64)
      }') from targets`,
    );
  }
  const countUser = await person("audio-count-cap");
  await seedQuota(countUser, 99, 1);
  const lastTarget = await task(countUser),
    beyondTarget = await task(countUser);
  const lastIntent = intent(countUser, lastTarget),
    beyondIntent = intent(countUser, beyondTarget),
    accountApp = "audio-account-quota-" + randomUUID().slice(0, 8);
  const accountHolder = await pg.hold(
    `set local role service_role;select public.taskfold_audio_comment_command('reserve',${
      lit(countUser.id)
    },${lit(countUser.session)},${json(lastIntent)})`,
  );
  const another = pg.value(
    `public.taskfold_audio_comment_command('reserve',${lit(countUser.id)},${
      lit(countUser.session)
    },${json(beyondIntent)})`,
    { app: accountApp },
  );
  let accountLock = false;
  try {
    accountLock =
      (await pg.waitForLock(accountApp, accountHolder.pid)).event ===
        "advisory";
  } catch {
  }
  await accountHolder.release("commit");
  const accountRace = await another;
  check("account quota serializes different task targets", accountLock, true);
  check(
    "account count never passes one hundred",
    accountRace.value.status,
    "quota",
  );
  const sizeUser = await person("audio-byte-cap");
  await seedQuota(sizeUser, 31, 8000000);
  const exactTarget = await task(sizeUser),
    exact = intent(sizeUser, exactTarget);
  exact.audio.byte_count = 2000000;
  check(
    "exact account byte boundary remains usable",
    (await success("reserve", exact, sizeUser)).state,
    "pending",
  );
  const beyond = intent(sizeUser, await task(sizeUser));
  beyond.audio.byte_count = 1;
  check(
    "one byte over account allowance is refused",
    (await success("reserve", beyond, sizeUser)).status,
    "quota",
  );
  const managedProject = await project("Managed team boundary"),
    managedTask = await task(owner, managedProject),
    managedTeam = randomUUID();
  await pg.raw(
    `begin;insert into taskfold_private.teams(id,owner_id,name) values(${
      lit(managedTeam)
    },${
      lit(owner.id)
    },'Synthetic managed team');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(managedTeam)
    },${
      lit(owner.id)
    },'admin');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
      lit(managedProject)
    },${lit(managedTeam)},'team');commit;`,
  );
  check(
    "existing centralized access denies a legacy managed-team shortcut",
    await pg.scalar(
      `select to_jsonb(public.has_project_access(${lit(owner.id)},${
        lit(managedProject)
      }))`,
    ),
    false,
  );
  check(
    "audio does not bypass the managed-team native protocol",
    (await success("reserve", intent(owner, managedTask))).status,
    "unavailable",
  );
  await pg.raw(
    `begin;set local session_replication_role=replica;update public.tasks set project_id=null where id=${
      lit(managedTask.task_id)
    };commit;`,
  );
  check(
    "a managed task cannot bypass custody after legacy project drift",
    (await success(
      "reserve",
      intent(owner, { ...managedTask, project_id: null }),
    )).status,
    "unavailable",
  );
  check(
    "ledger migration does not provision or claim a Storage bucket",
    await pg.scalar(
      `select to_jsonb(count(*)) from storage.buckets where id='taskfold-audio-v1'`,
    ),
    0,
  );
  // A pending request waiting on the account quota must recheck revocation.
  const queuedUser = await person("audio-quota-wait"),
    waitTask = await task(queuedUser),
    waiting = intent(queuedUser, waitTask),
    app = "audio-wait-" + randomUUID().slice(0, 8);
  const holder = await pg.hold(
    `begin;select pg_advisory_xact_lock(hashtextextended('audio-account:'||${
      lit(queuedUser.id)
    },20261028));`,
  );
  const pending = pg.value(
    `public.taskfold_audio_comment_command('reserve',${lit(queuedUser.id)},${
      lit(queuedUser.session)
    },${json(waiting)})`,
    { app },
  );
  check(
    "worker reaches the actual quota advisory lock",
    (await pg.waitForLock(app)).event,
    "advisory",
  );
  // The command holds the live session row; membership-independent gate changes
  // can still commit while the quota is held and must be checked after waiting.
  await pg.raw(
    `insert into taskfold_private.account_removal_receipts(token_hash,account_id) values('${
      "d".repeat(64)
    }',${lit(queuedUser.id)})`,
  );
  await holder.release("rollback");
  check(
    "queued operation rechecks account-removal fence",
    (await pending).value.status,
    "unavailable",
  );
  await pg.raw(
    `delete from taskfold_private.account_removal_receipts where account_id=${
      lit(queuedUser.id)
    }`,
  );
  // Delete the sole config row: absence must fail closed, not enable publishing.
  await pg.raw(`delete from taskfold_private.audio_comment_config`);
  check(
    "missing gate fails closed",
    (await success("reserve", intent(queuedUser, waitTask), queuedUser)).status,
    "disabled",
  );
  report.advisors = await pg.advisors();
  const baselineKeys = new Set(
    report.baselineAdvisors.result.map((x) => x.cache_key),
  );
  report.introducedAdvisors = report.advisors.result.filter((x) =>
    !baselineKeys.has(x.cache_key)
  );
  check(
    "migration introduces no advisor errors or warnings",
    report.introducedAdvisors.filter((x) => ["ERROR", "WARN"].includes(x.level))
      .map((x) => x.name),
    [],
  );
  report.limits = [
    "Actual owned PostgreSQL and unchanged existing team/project/account-removal dependency routines, not a complete hosted Supabase stack.",
    "Metadata-only synthetic reservations and service attestations; no audio bytes, bucket, Storage API, Edge HTTP or native publication flow exists in this checkpoint.",
    "Storage readback, authenticated gateway, late-upload-safe cleanup, rate budgets, scheduled processing and hosted acceptance remain open. No feature exposure or rollout is enabled.",
  ];
} catch (error) {
  report.failure = {
    code: error.code ?? null,
    message: error.message,
    stack: error.stack,
  };
  throw error;
} finally {
  if (pg) report.ownedPostgresContainerRemoved = await pg.close();
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
}
if (process.argv[2]) {
  await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
}
console.log(
  Object.keys(report.checks).length + " actual PostgreSQL ledger checks passed",
);
