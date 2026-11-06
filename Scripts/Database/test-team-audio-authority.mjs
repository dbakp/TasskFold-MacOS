import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadTeamProjectSchema } from "./team-project-schema.mjs";
import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
const migration = "20261102143104_team_audio_write_authority.sql";
const candidate = await readFile(
  new URL("../../supabase/migrations/" + migration, import.meta.url),
  "utf8",
);
const output = process.argv[2];
assert(output?.startsWith("/tmp/taskfold-") && !output.includes(".."));
const report = {
  checks: {},
  runnerSHA256: createHash("sha256").update(
    await readFile(new URL(import.meta.url)),
  ).digest("hex"),
  candidateSHA256: createHash("sha256").update(candidate).digest("hex"),
  deployed: false,
  normalUseEnabled: false,
  genuineAuthOrStorage: false,
};
const check = (name, actual, expected = true) => {
  assert.deepEqual(actual, expected, name);
  report.checks[name] = true;
};
const j = (x) => lit(JSON.stringify(x)) + "::jsonb";
let pg, http, primaryError;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadTeamProjectSchema(pg.raw);
  await pg.raw(
    await readFile(
      new URL(
        "../../supabase/migrations/20261024040403_team_task_edits.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  await pg.raw(
    "alter table storage.buckets add column name text,add column file_size_limit bigint,add column allowed_mime_types text[];alter table storage.buckets enable row level security;alter table storage.objects add column metadata jsonb;create unique index audio_fixture_object_identity on storage.objects(bucket_id,name)",
  );
  for (
    const f of [
      "20261028134424_audio_comment_publication_ledger.sql",
      "20261028145414_audio_comment_gateway_boundary.sql",
      "20261028151901_audio_comment_cleanup_fencing.sql",
      "20261028153218_audio_comment_upload_recovery.sql",
      "20261028185429_audio_comment_keyset_pages.sql",
      "20261028191118_audio_comment_shared_reads.sql",
      "20261028212632_audio_owner_publication_status.sql",
    ]
  ) {
    await pg.raw(
      await readFile(
        new URL("../../supabase/migrations/" + f, import.meta.url),
        "utf8",
      ),
    );
  }
  report.baselineAdvisors = await pg.advisors();
  const oldScopeOID = await pg.scalar(
    "select to_jsonb('taskfold_private.audio_scope(uuid,uuid,uuid,uuid,boolean)'::regprocedure::oid::int)",
  );
  await pg.raw(candidate);
  check(
    "existing scope function identity retained",
    await pg.scalar(
      "select to_jsonb('taskfold_private.audio_scope(uuid,uuid,uuid,uuid,boolean)'::regprocedure::oid::int)",
    ),
    oldScopeOID,
  );
  const people = Object.fromEntries(
    ["owner", "editor", "peer", "viewer", "creator", "outside", "implicit"].map(
      (k) => [k, { id: randomUUID(), session: randomUUID() }],
    ),
  );
  for (const u of Object.values(people)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${
        lit(u.id + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${
        lit(u.id)
      });insert into public.profiles(user_id) values(${lit(u.id)})`,
    );
  }
  const team = randomUUID(),
    project = randomUUID(),
    task = randomUUID(),
    generation = randomUUID(),
    personal = randomUUID(),
    personalGen = randomUUID();
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${lit(project)},${
      lit(people.creator.id)
    },'Audio workshop');insert into public.tasks(id,user_id,project_id,task_generation,title) values(${
      lit(task)
    },${lit(people.creator.id)},${lit(project)},${
      lit(generation)
    },'Shared recording task'),(${lit(personal)},${
      lit(people.editor.id)
    },null,${
      lit(personalGen)
    },'Personal recording task');insert into taskfold_private.teams(id,owner_id,name) values(${
      lit(team)
    },${
      lit(people.owner.id)
    },'Audio team');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(people.owner.id)},'admin'),(${lit(team)},${
      lit(people.editor.id)
    },'member'),(${lit(team)},${lit(people.peer.id)},'member'),(${lit(team)},${
      lit(people.viewer.id)
    },'guest'),(${lit(team)},${
      lit(people.implicit.id)
    },'member');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
      lit(project)
    },${
      lit(team)
    },'private');insert into taskfold_private.team_content_tasks(task_id,generation,team_id,project_id) values(${
      lit(task)
    },${lit(generation)},${lit(team)},${
      lit(project)
    }) on conflict do nothing;insert into taskfold_private.team_project_grants values(${
      lit(project)
    },${lit(team)},${lit(people.editor.id)},'editor'),(${lit(project)},${
      lit(team)
    },${lit(people.peer.id)},'editor'),(${lit(project)},${lit(team)},${
      lit(people.viewer.id)
    },'viewer');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true;update taskfold_private.audio_comment_config set enabled=true`,
  );
  const media = await readFile(
    new URL(
      "../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
      import.meta.url,
    ),
  );
  const descriptor = {
    version: 1,
    mime_type: "audio/mp4",
    byte_count: media.length,
    duration_ms: 1000,
    sha256: createHash("sha256").update(media).digest("hex"),
  };
  const intent = (
    who = "editor",
    target = {
      task_id: task,
      task_generation: generation,
      project_id: project,
    },
  ) => ({
    version: 1,
    account: people[who].id,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target,
    caption: "Team audio cafe\u0301 🌿",
    audio: descriptor,
  });
  const command = async (action, body, who = "editor") => {
    const u = people[who];
    const r = await pg.value(
      `public.taskfold_audio_comment_command(${lit(action)},${lit(u.id)},${
        lit(u.session)
      },${j(body)})`,
    );
    assert.equal(r.code, null, JSON.stringify(r));
    return r.value;
  };
  const reserve = (who = "editor", i = intent(who)) =>
    command("reserve", i, who);
  const remove = (i, who = "editor") =>
    command("remove", { comment_id: i.comment_id }, who);
  const count = () =>
    pg.scalar(
      "select to_jsonb(count(*)::int) from taskfold_private.audio_comment_publications",
    );
  check(
    "team publication defaults off",
    await pg.scalar(
      "select to_jsonb(team_publication_enabled) from taskfold_private.audio_comment_config",
    ),
    false,
  );
  check(
    "disabled team reservation refused",
    (await reserve()).status,
    "unavailable",
  );
  check("disabled reservation allocates no ledger", await count(), 0);
  await pg.raw(
    "update taskfold_private.audio_comment_config set team_publication_enabled=true",
  );
  for (const who of ["viewer", "creator", "outside", "implicit"]) {
    check(
      who + " cannot reserve private project",
      (await reserve(who)).status,
      "unavailable",
    );
  }
  check("refused actors allocate no media", await count(), 0);
  check(
    "wrong generation refuses",
    (await reserve(
      "editor",
      intent("editor", {
        task_id: task,
        task_generation: randomUUID(),
        project_id: project,
      }),
    )).status,
    "unavailable",
  );
  check(
    "wrong project refuses",
    (await reserve(
      "editor",
      intent("editor", {
        task_id: task,
        task_generation: generation,
        project_id: randomUUID(),
      }),
    )).status,
    "unavailable",
  );
  const scope = (who) =>
    `taskfold_private.audio_team_scope(${lit(people[who].id)},${lit(task)},${
      lit(generation)
    },${lit(project)},true)`;
  const lockScope = (who) =>
    pg.hold(
      `do $scope$ begin if not ${
        scope(who)
      } then raise exception 'Expected current team scope'; end if; end $scope$`,
    );
  let holder = await lockScope("editor");
  try {
    try {
      await pg.raw(
        `set lock_timeout='300ms';delete from taskfold_private.team_project_grants where user_id=${
          lit(people.editor.id)
        }`,
      );
      assert.fail("Revocation must serialize");
    } catch (error) {
      check(
        "explicit grant revocation waits for admitted write",
        error.code,
        "55P03",
      );
    }
  } finally {
    await holder.release("rollback");
  }
  check(
    "timed-out revocation leaves grant intact",
    await pg.scalar(
      `select to_jsonb(count(*)::int) from taskfold_private.team_project_grants where user_id=${
        lit(people.editor.id)
      }`,
    ),
    1,
  );
  await pg.raw(
    `update taskfold_private.team_content_projects set visibility='team' where project_id=${
      lit(project)
    }`,
  );
  holder = await lockScope("implicit");
  try {
    try {
      await pg.raw(
        `set lock_timeout='300ms';insert into taskfold_private.team_project_grants values(${
          lit(project)
        },${lit(team)},${lit(people.implicit.id)},'viewer')`,
      );
      assert.fail("New downgrade grant must serialize");
    } catch (error) {
      check(
        "new viewer grant waits for implicit editor write",
        error.code,
        "55P03",
      );
    }
  } finally {
    await holder.release("rollback");
  }
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(people.implicit.id)},'viewer')`,
  );
  check(
    "committed viewer downgrade blocks next reservation",
    (await reserve("implicit")).status,
    "unavailable",
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where user_id=${
      lit(people.implicit.id)
    };update taskfold_private.team_content_projects set visibility='private' where project_id=${
      lit(project)
    }`,
  );
  await pg.raw(
    `update auth.sessions set not_after=now()-interval '1 second' where id=${
      lit(people.editor.session)
    }`,
  );
  check(
    "expired session cannot publish",
    (await reserve()).status,
    "unavailable",
  );
  await pg.raw(
    `update auth.sessions set not_after=null where id=${
      lit(people.editor.session)
    }`,
  );
  await pg.raw(
    `update auth.users set email_confirmed_at=null where id=${
      lit(people.editor.id)
    }`,
  );
  check(
    "unconfirmed member cannot publish",
    (await reserve()).status,
    "unavailable",
  );
  await pg.raw(
    `update auth.users set email_confirmed_at=now() where id=${
      lit(people.editor.id)
    }`,
  );
  const management = await pg.hold(
    `select 1 from taskfold_private.teams where id=${lit(team)} for update`,
  );
  const racedIntent = intent(), app = "audio-admit-" + randomUUID().slice(0, 8);
  const waiting = pg.value(
    `public.taskfold_audio_comment_command('reserve',${lit(people.editor.id)},${
      lit(people.editor.session)
    },${j(racedIntent)})`,
    { app },
  );
  try {
    await pg.waitForLock(app, management.pid);
    check("audio admission waits behind team management", true);
    await management.release(
      "rollback",
      `select 1 from taskfold_private.team_content_projects where project_id=${
        lit(project)
      } for update`,
    );
    const admitted = await waiting;
    check(
      "team management does not deadlock on project binding",
      admitted.code,
      null,
    );
    check(
      "admission resumes after access management",
      admitted.value.state,
      "pending",
    );
  } finally {
    await management.release("rollback");
    await waiting;
  }
  const i = intent();
  check(
    "editor reserves team task",
    (await reserve("editor", i)).state,
    "pending",
  );
  check(
    "exact reservation retry is stable",
    (await reserve("editor", i)).operation_id,
    i.operation_id,
  );
  check(
    "changed caption retry conflicts",
    (await reserve("editor", { ...i, caption: "Changed" })).status,
    "conflict",
  );
  await pg.raw(
    `update taskfold_private.team_project_grants set role='viewer' where user_id=${
      lit(people.editor.id)
    }`,
  );
  check(
    "demoted author cannot remove pending recording",
    (await remove(i)).status,
    "unavailable",
  );
  check(
    "downgrade blocks pending upload",
    (await command("upload_begin", { operation_id: i.operation_id })).status,
    "unavailable",
  );
  await pg.raw(
    `update taskfold_private.team_project_grants set role='editor' where user_id=${
      lit(people.editor.id)
    }`,
  );
  http = await createAudioHttpFixture(
    pg,
    people.editor.id,
    people.editor.session,
  );
  const published = await http.call("publish", {
    intent: i,
    audio_base64: media.toString("base64"),
  });
  check("production gateway publishes editor recording", published.status, 200);
  const receipt = (await published.json()).receipt;
  check("published target stays exact", receipt.target, i.target);
  check("one immutable upload", http.state.uploads, 1);
  const again = await http.call("publish", {
    intent: i,
    audio_base64: media.toString("base64"),
  });
  check("publication retry succeeds", again.status, 200);
  await again.arrayBuffer();
  check("retry does not upload again", http.state.uploads, 1);
  const read = await http.call("download", { comment_id: i.comment_id });
  check("editor downloads recording", read.status, 200);
  check("downloaded audio exact", Buffer.from(await read.arrayBuffer()), media);
  for (const who of ["peer", "viewer", "creator", "outside"]) {
    check(
      who + " cannot remove another author",
      (await remove(i, who)).status,
      "unavailable",
    );
  }
  await pg.raw(
    `update public.projects set is_archived=true where id=${lit(project)}`,
  );
  check(
    "archived project blocks new recording",
    (await reserve()).status,
    "unavailable",
  );
  check(
    "archived project blocks removal",
    (await remove(i)).status,
    "unavailable",
  );
  await pg.raw(
    `update public.projects set is_archived=false where id=${lit(project)}`,
  );
  await pg.raw(
    `update taskfold_private.teams set state='archived' where id=${lit(team)}`,
  );
  check(
    "archived team blocks publication",
    (await reserve()).status,
    "unavailable",
  );
  check(
    "archived team blocks removal",
    (await remove(i, "owner")).status,
    "unavailable",
  );
  await pg.raw(
    `update taskfold_private.teams set state='active' where id=${lit(team)}`,
  );
  for (
    const [table, field] of [
      ["team_project_config", "native_task_edits_enabled"],
      ["team_project_config", "native_reads_enabled"],
      ["team_config", "enabled"],
    ]
  ) {
    await pg.raw(`update taskfold_private.${table} set ${field}=false`);
    check(
      field + " blocks new team audio",
      (await reserve()).status,
      "unavailable",
    );
    check(
      field + " blocks team removal",
      (await remove(i, "owner")).status,
      "unavailable",
    );
    await pg.raw(`update taskfold_private.${table} set ${field}=true`);
  }
  const before = await pg.scalar(
    `select to_jsonb(t) from public.tasks t where id=${lit(task)}`,
  );
  try {
    await pg.raw(
      `update public.tasks set task_generation=gen_random_uuid() where id=${
        lit(task)
      }`,
    );
    assert.fail("Custody must block replacement");
  } catch (error) {
    assert.equal(error.code, "23514");
    report.checks["live recording still blocks task replacement"] = true;
  }
  check(
    "refused replacement leaves task exact",
    await pg.scalar(
      `select to_jsonb(t) from public.tasks t where id=${lit(task)}`,
    ),
    before,
  );
  const revoke = () =>
    pg.raw(
      `delete from taskfold_private.team_project_grants where user_id=${
        lit(people.editor.id)
      }`,
    );
  http.state.afterGet = revoke;
  const withdrawn = await http.call("download", { comment_id: i.comment_id });
  check("grant withdrawn during download refuses bytes", withdrawn.status, 404);
  await withdrawn.arrayBuffer();
  http.state.afterGet = null;
  check(
    "revoked author cannot remove",
    (await remove(i)).status,
    "unavailable",
  );
  await pg.raw(
    "update taskfold_private.audio_comment_config set enabled=false,team_publication_enabled=false",
  );
  check(
    "manager can retire with publishing disabled",
    (await remove(i, "owner")).state,
    "retired",
  );
  check(
    "manager removal retry idempotent",
    (await remove(i, "owner")).state,
    "retired",
  );
  const history = await pg.value(
    `public.taskfold_audio_owner_publication(${lit(people.editor.id)},${
      lit(people.editor.session)
    },${j({ intent: i, close: false })})`,
  );
  check(
    "revoked original sender can reconcile manager removal",
    history.value.state,
    "closed",
  );
  check(
    "sender history retains exact original intent",
    history.value.intent,
    i,
  );
  const retired = await pg.scalar(
    `select jsonb_build_object('caption',caption,'audio',audio_descriptor,'state',state,'cleanup',cleanup_after is not null) from taskfold_private.audio_comment_publications where operation_id=${
      lit(i.operation_id)
    }`,
  );
  check("removal clears public metadata and schedules cleanup", retired, {
    caption: null,
    audio: null,
    state: "retired",
    cleanup: true,
  });
  check("removal retains bytes for fenced cleanup", http.state.objects.size, 1);
  await pg.raw("update taskfold_private.audio_comment_config set enabled=true");
  const personalIntent = intent("editor", {
    task_id: personal,
    task_generation: personalGen,
    project_id: null,
  });
  check(
    "personal publishing unaffected by team switch",
    (await reserve("editor", personalIntent)).state,
    "pending",
  );
  check(
    "personal author can remove pending attempt",
    (await remove(personalIntent)).state,
    "retired",
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    check(
      role + " cannot call scope directly",
      await pg.scalar(
        `select to_jsonb(has_function_privilege(${
          lit(role)
        },'taskfold_private.audio_team_scope(uuid,uuid,uuid,uuid,boolean)','execute'))`,
      ),
      false,
    );
  }
  for (const role of ["anon", "authenticated"]) {
    check(
      role + " cannot invoke service command",
      await pg.scalar(
        `select to_jsonb(has_function_privilege(${
          lit(role)
        },'public.taskfold_audio_comment_command(text,uuid,uuid,jsonb)','execute'))`,
      ),
      false,
    );
  }
  check(
    "service cannot bypass wrapper",
    await pg.scalar(
      "select to_jsonb(has_function_privilege('service_role','taskfold_private.audio_comment_before_team_writes(text,uuid,uuid,jsonb)','execute'))",
    ),
    false,
  );
  check("HTTP adapter has no unexpected SQL errors", http.state.errors, []);
  report.finalAdvisors = await pg.advisors();
  report.addedAdvisors = report.finalAdvisors.result.filter((x) =>
    !report.baselineAdvisors.result.some((y) => x.cache_key === y.cache_key)
  );
  check("no new advisor findings", report.addedAdvisors, []);
  report.checkCount = Object.keys(report.checks).length;
} catch (error) {
  report.error = { message: error.message, code: error.code ?? null };
  primaryError = error;
} finally {
  report.cleanupErrors = [];
  if (http) {
    try {
      await http.close();
      report.httpClosed = true;
    } catch (error) {
      report.cleanupErrors.push({ resource: "http", message: error.message });
    }
  }
  if (pg) {
    try {
      report.ownedPostgresContainerRemoved = await pg.close();
    } catch (error) {
      report.cleanupErrors.push({
        resource: "postgres",
        message: error.message,
      });
    }
  }
  await writeFile(output, JSON.stringify(report, null, 2) + "\n");
}
if (primaryError) throw primaryError;
assert.deepEqual(report.cleanupErrors, []);
console.log(
  JSON.stringify({
    checks: report.checkCount,
    ownedPostgresContainerRemoved: report.ownedPostgresContainerRemoved,
  }),
);
