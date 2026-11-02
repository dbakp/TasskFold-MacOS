// Real local PostgreSQL/Storage and production gateway; controlled synthetic Auth.
// Certified recording deletion/Undo with exact preserved provider identity.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createTaskFileProviderDatabase } from "./task-file-provider-schema.mjs";
import { loadTaskFileWorkspaceFixture } from "./task-file-workspace-fixture.mjs";
import {
  audioProjectCustodyMigration,
  audioProjectLedgerDependencies,
  migrationSQL,
} from "./audio-project-custody-schema.mjs";
import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
import { literal as lit } from "./postgres-fixture.mjs";
const [output] = process.argv.slice(2);
assert(output?.startsWith("/tmp/taskfold-") && output.endsWith(".json"));
const account = "ec240000-0000-4000-8000-000000000001",
  creator = "ec240000-0000-4000-8000-000000000099",
  task = "ec240000-0000-4000-8000-000000000002",
  project = "ec240000-0000-4000-8000-000000000003",
  team = "ec240000-0000-4000-8000-000000000004",
  generation = "ec240000-0000-4000-8000-000000000071";
const report = {
  checks: {},
  maintenance: [],
  actualLocalStorage: true,
  genuineAuth: false,
  deployed: false,
  normalUseEnabled: false,
};
const check = (name, a, b = true) => {
  assert.deepEqual(a, b, name);
  report.checks[name] = true;
  console.log("passed:", name);
};
let pg, storage, http;
try {
  execFileSync("python3", ["Scripts/check_test_storage.py", "--path", "/tmp"]);
  ({ pg, storage } = await createTaskFileProviderDatabase());
  for (
    const file of [
      ...audioProjectLedgerDependencies,
      audioProjectCustodyMigration,
    ]
  ) await pg.raw(await migrationSQL(file));
  const baseline = await pg.advisors();
  await pg.raw(
    await migrationSQL("20261102175200_reviewed_audio_generation_restore.sql"),
  );
  await loadTaskFileWorkspaceFixture(pg);
  const users = {
    actor: { id: account, session: randomUUID() },
    creator: { id: creator, session: randomUUID() },
  };
  for (const user of Object.values(users)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(user.id)
      },${
        lit(user.id + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${
        lit(user.session)
      },${lit(user.id)});insert into public.profiles(user_id) values(${
        lit(user.id)
      })`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(creator)
    },'Native audio workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(account)},'member'),(${lit(team)},${
      lit(creator)
    },'admin');insert into public.projects(id,user_id,name) values(${
      lit(project)
    },${
      lit(creator)
    },'Design workshop');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
      lit(project)
    },${
      lit(team)
    },'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${
      lit(project)
    },${lit(team)},${
      lit(account)
    },'editor');insert into public.tasks(id,user_id,project_id,task_generation,title,description,subtasks,attachments) values(${
      lit(task)
    },${lit(creator)},${lit(project)},${
      lit(generation)
    },'Team editor proof','Native audio service original','[]','[]');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_task_types_enabled=true;update taskfold_private.audio_comment_config set enabled=true,team_publication_enabled=true`,
  );
  const original = await pg.scalar(
    `select coalesce((select to_jsonb(t) from public.tasks t where id=${
      lit(task)
    }),'null'::jsonb)`,
  );
  http = await createAudioHttpFixture(pg, account, users.actor.session, {
    storage,
  });
  const media = await readFile(
    new URL(
      "../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
      import.meta.url,
    ),
  );
  const j = (x) => lit(JSON.stringify(x)) + "::jsonb";
  const run = (expr, who = "actor", beforeSQL = "") => {
    const u = users[who];
    return pg.scalar(
      `begin;${beforeSQL};create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated;set local role authenticated;set local request.jwt.claim.sub=${
        lit(u.id)
      };set local request.jwt.claims=${
        lit(JSON.stringify({ sub: u.id, session_id: u.session }))
      };do $r$begin begin insert into result values(to_jsonb(${expr}),null,null);exception when others then insert into result values(null,sqlstate,sqlerrm);end;end$r$;select to_jsonb(r) from result r;${
        beforeSQL ? "rollback" : "commit"
      };`,
    );
  };
  const ok = async (action, b) => {
    const r = await run(
      `public.taskfold_team_task_lifecycle(${lit(action)},${j(b)})`,
    );
    if (r.code) throw Error(JSON.stringify(r));
    return r.value;
  };
  const refused = async (
    name,
    action,
    b,
    code = "PT409",
    who = "actor",
    beforeSQL = "",
  ) => {
    const r = await run(
      `public.taskfold_team_task_lifecycle(${lit(action)},${j(b)})`,
      who,
      beforeSQL,
    );
    if (r.code !== code) report.lastUnexpected = r;
    check(name, r.code, code);
  };
  const root = () =>
    pg.scalar(
      `select coalesce((select to_jsonb(t) from public.tasks t where id=${
        lit(task)
      }),'null'::jsonb)`,
    );
  const live = () =>
    pg.scalar(
      `select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${
        lit(i.operation_id)
      }`,
    );
  const custody = () =>
    pg.scalar(
      `select to_jsonb(c) from taskfold_private.audio_comment_custody c where operation_id=${
        lit(i.operation_id)
      }`,
    );
  const i = {
    version: 1,
    account,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target: { task_id: task, task_generation: generation, project_id: project },
    caption: "Keep café 🌿 exactly",
    audio: {
      version: 1,
      mime_type: "audio/mp4",
      byte_count: media.length,
      duration_ms: 1000,
      sha256: createHash("sha256").update(media).digest("hex"),
    },
  };
  check(
    "restoration defaults disabled",
    await pg.scalar(
      "select to_jsonb(restoration_enabled) from taskfold_private.audio_comment_config",
    ),
    false,
  );
  const published = await http.call("publish", {
    intent: i,
    audio_base64: media.toString("base64"),
  });
  check("real provider publication succeeds", published.status, 200);
  const immutable = await live(), binding = await custody();
  await pg.raw(
    "update taskfold_private.audio_comment_config set restoration_enabled=true",
  );
  const ack = { policy: "published_restore_v1", count: 1, retention_days: 30 };
  const deletion = {
    team_id: team,
    project_id: project,
    task_id: task,
    task_generation: generation,
    task_type_lifecycle_protocol: 1,
    request_id: randomUUID(),
    record: await root(),
  };
  await refused(
    "old client must review recording retention",
    "delete",
    deletion,
  );
  await refused("wrong recording count cannot delete", "delete", {
    ...deletion,
    audio_restoration_ack: { ...ack, count: 2 },
  });
  const held = await pg.hold(
    `select 1 from taskfold_private.audio_comment_custody where operation_id=${
      lit(i.operation_id)
    } for update`,
  );
  try {
    await refused("busy recording prevents deletion", "delete", {
      ...deletion,
      audio_restoration_ack: ack,
    });
  } finally {
    await held.release("rollback");
  }
  // Direct SQL is also fenced; a user-set GUC cannot substitute for a reviewed scope.
  const directDelete = await pg.scalar(
    `begin;create temp table result(code text) on commit drop;set local request.jwt.claim.sub=${
      lit(account)
    };do $r$begin begin delete from public.tasks where id=${
      lit(task)
    };insert into result values(null);exception when others then insert into result values(sqlstate);end;end$r$;select to_jsonb(code) from result;commit;`,
  );
  check(
    "existing native guard blocks uncertified deletion",
    directDelete,
    "PT503",
  );
  const acceptedDelete = { ...deletion, audio_restoration_ack: ack };
  await ok("delete", acceptedDelete);
  check("certified deletion removes only root", await root(), null);
  check("deleted recording is retired", (await live()).state, "retired");
  check("deleted metadata cleared from public receipt ledger", [
    (await live()).caption,
    (await live()).audio_descriptor,
  ], [null, null]);
  check(
    "private deletion inventory retains exact caption",
    await pg.scalar(
      `select inventory->0->'publication'->'caption' from taskfold_private.audio_task_deletions where request_id=${
        lit(deletion.request_id)
      }`,
    ),
    i.caption,
  );
  const archived = await pg.scalar(
    `select to_jsonb(d) from taskfold_private.audio_task_deletions d where request_id=${
      lit(deletion.request_id)
    }`,
  );
  check(
    "retention and cleanup share exact deadline",
    (await live()).cleanup_after,
    archived.expires_at,
  );
  const deletedRead = await http.call("download", { comment_id: i.comment_id });
  check("deleted generation cannot read recording", deletedRead.status, 404);
  const maintenance = await http.maintain();
  check(
    "retained recording not claimed for early cleanup",
    (await maintenance.json()).claimed,
    0,
  );
  check(
    "retained bytes still consume quota",
    await pg.scalar(
      "select coalesce(sum(byte_count),0)::int from taskfold_private.audio_comment_publications where state<>'purged'",
    ),
    media.length,
  );
  await ok("delete", acceptedDelete);
  check(
    "delete acknowledgement replay preserves one inventory",
    await pg.scalar(
      "select count(*)::int from taskfold_private.audio_task_deletions",
    ),
    1,
  );
  const renewed = randomUUID(),
    restore = {
      ...acceptedDelete,
      request_id: randomUUID(),
      restore_from: deletion.request_id,
      task_generation: renewed,
      record: {
        ...deletion.record,
        task_generation: renewed,
        completion_version: 0,
      },
    };
  const noAck = { ...restore };
  delete noAck.audio_restoration_ack;
  await refused("restore needs matching explicit review", "restore", noAck);
  // Observe an actually changed provider row inside a transaction, then roll
  // that synthetic mutation back. Real Storage also changes updated_at; setting
  // only the old version back must never count as an unchanged object.
  await refused(
    "changed stored object refuses restoration",
    "restore",
    restore,
    "PT409",
    "actor",
    `update storage.objects set version='changed-after-delete' where id=${
      lit(binding.object_id)
    }`,
  );
  check("failed restore leaves old custody exact", await custody(), binding);
  await pg.raw(
    `update taskfold_private.team_project_grants set role='viewer' where user_id=${
      lit(account)
    } and project_id=${lit(project)}`,
  );
  await refused(
    "revoked editor cannot restore recordings",
    "restore",
    restore,
    "42501",
  );
  await pg.raw(
    `update taskfold_private.team_project_grants set role='editor' where user_id=${
      lit(account)
    } and project_id=${lit(project)}`,
  );
  // Fail after scope, ledger and custody renewal: every mutation must roll back.
  await pg.raw(
    "create function taskfold_private.fixture_audio_restore_failure() returns trigger language plpgsql as $$begin if new.operation='restore' then raise exception using errcode='23514',message='synthetic late failure';end if;return new;end$$;create trigger fixture_audio_restore_failure before insert on taskfold_private.team_task_edits for each row execute function taskfold_private.fixture_audio_restore_failure()",
  );
  await refused(
    "late failure rolls back complete restoration",
    "restore",
    restore,
    "23514",
  );
  check("late failure leaves root absent", await root(), null);
  check("late failure retains retired ledger", (await live()).state, "retired");
  check("late failure retains old binding", await custody(), binding);
  check(
    "late failure leaves no private scope",
    await pg.scalar(
      "select count(*)::int from taskfold_private.audio_task_restore_scope",
    ),
    0,
  );
  await pg.raw(
    "drop trigger fixture_audio_restore_failure on taskfold_private.team_task_edits;drop function taskfold_private.fixture_audio_restore_failure()",
  );
  await ok("restore", restore);
  check("restoration preserves exact task content", await root(), {
    ...original,
    task_generation: renewed,
    completion_version: 0,
  });
  check(
    "restored task gets new generation",
    (await root()).task_generation,
    renewed,
  );
  check(
    "recording audience follows certified generation",
    (await custody()).task_generation,
    renewed,
  );
  check("restored recording metadata exact", [
    (await live()).state,
    (await live()).caption,
    (await live()).audio_descriptor,
  ], ["published", i.caption, i.audio]);
  check("immutable original recording identity and path preserved", [
    (await live()).task_generation,
    (await live()).object_name,
    (await live()).request_hash,
  ], [
    immutable.task_generation,
    immutable.object_name,
    immutable.request_hash,
  ]);
  check("no media reupload on restore", http.state.uploads, 1);
  check(
    "successful restoration consumes private caption inventory",
    await pg.scalar(
      "select count(*)::int from taskfold_private.audio_task_deletions",
    ),
    0,
  );
  const newTarget = { ...i.target, task_generation: renewed };
  const list = await http.call("list", newTarget);
  check("restored list succeeds", list.status, 200);
  const listed = (await list.json()).items;
  check("live recipient receives new generation", listed[0].target, newTarget);
  check(
    "internal Storage generation never reaches public receipt",
    Object.hasOwn(listed[0], "storage_task_generation"),
    false,
  );
  const download = await http.call("download", { comment_id: i.comment_id });
  check("new generation downloads original object", download.status, 200);
  check(
    "restored downloaded bytes exact",
    Buffer.from(await download.arrayBuffer()),
    media,
  );
  check(
    "old generation cannot list restored audio",
    (await http.call("list", i.target)).status,
    404,
  );
  const status = await http.call("resolve", { intent: i, close: false });
  check(
    "sender status retains original frozen target",
    (await status.json()).receipt.target,
    i.target,
  );
  await ok("restore", restore);
  check("restore reply replay leaves exact new binding", await custody(), {
    ...binding,
    task_generation: renewed,
  });
  check(
    "restore retires all private scopes",
    await pg.scalar(
      "select count(*)::int from taskfold_private.audio_task_restore_scope",
    ),
    0,
  );
  // The renewed generation must also support later certified delete/Undo.
  const secondDelete = {
    ...acceptedDelete,
    request_id: randomUUID(),
    task_generation: renewed,
    record: await root(),
  };
  await ok("delete", secondDelete);
  const secondGen = randomUUID(),
    secondRestore = {
      ...secondDelete,
      request_id: randomUUID(),
      restore_from: secondDelete.request_id,
      task_generation: secondGen,
      record: {
        ...secondDelete.record,
        task_generation: secondGen,
        completion_version: 0,
      },
    };
  await ok("restore", secondRestore);
  check(
    "second deletion Undo renews audience again",
    (await custody()).task_generation,
    secondGen,
  );
  check(
    "multiple generations retain single original object",
    (await live()).object_name,
    immutable.object_name,
  );
  const removed = await http.call("remove", { comment_id: i.comment_id });
  check("current author removes restored recording", removed.status, 200);
  check(
    "removal after restore retires ledger",
    (await live()).state,
    "retired",
  );
  await pg.raw(
    `update taskfold_private.audio_comment_publications set cleanup_after=clock_timestamp()-interval '1 second' where operation_id=${
      lit(i.operation_id)
    }`,
  );
  const cleaned = await http.maintain();
  check(
    "existing fenced worker purges restored original",
    (await cleaned.json()).purged,
    1,
  );
  check(
    "cleanup releases quota after explicit removal",
    await pg.scalar(
      "select coalesce(sum(byte_count),0)::int from taskfold_private.audio_comment_publications where state<>'purged'",
    ),
    0,
  );
  const expiryIntent = {
    ...i,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target: { ...i.target, task_generation: secondGen },
  };
  check(
    "new publication on renewed generation succeeds",
    (await http.call("publish", {
      intent: expiryIntent,
      audio_base64: media.toString("base64"),
    })).status,
    200,
  );
  const expiryDelete = {
    ...acceptedDelete,
    request_id: randomUUID(),
    task_generation: secondGen,
    record: await root(),
  };
  await ok("delete", expiryDelete);
  const expiryGeneration = randomUUID(),
    expiryRestore = {
      ...expiryDelete,
      request_id: randomUUID(),
      restore_from: expiryDelete.request_id,
      task_generation: expiryGeneration,
      record: {
        ...expiryDelete.record,
        task_generation: expiryGeneration,
        completion_version: 0,
      },
    };
  await pg.raw(
    `update taskfold_private.audio_task_deletions set expires_at=clock_timestamp()-interval '1 second' where request_id=${
      lit(expiryDelete.request_id)
    };update taskfold_private.audio_comment_publications r set cleanup_after=d.expires_at from taskfold_private.audio_task_deletions d where r.operation_id=any(d.operations) and d.request_id=${
      lit(expiryDelete.request_id)
    }`,
  );
  await refused(
    "expired recovery period refuses restoration",
    "restore",
    expiryRestore,
  );
  await refused("expired omission needs confirmed cleanup", "restore", {
    ...expiryRestore,
    audio_restoration_ack: {
      policy: "expired_recordings_omitted_v1",
      count: 1,
      retention_days: 30,
    },
  });
  const expiredClean = await http.maintain();
  check(
    "expired recording cleanup uses existing fenced worker",
    (await expiredClean.json()).purged,
    1,
  );
  check(
    "expired private caption inventory is pruned",
    await pg.scalar(
      `select coalesce(inventory,'null'::jsonb) from taskfold_private.audio_task_deletions where request_id=${
        lit(expiryDelete.request_id)
      }`,
    ),
    null,
  );
  await refused(
    "pruned expired capsule cannot silently restore without audio",
    "restore",
    expiryRestore,
  );
  check(
    "expired cleanup releases remaining quota",
    await pg.scalar(
      "select coalesce(sum(byte_count),0)::int from taskfold_private.audio_comment_publications where state<>'purged'",
    ),
    0,
  );
  check(
    "all real uploads remain separate immutable identities",
    http.state.uploads,
    2,
  );
  for (const table of ["audio_task_deletions", "audio_task_restore_scope"]) {
    for (const role of ["anon", "authenticated", "service_role"]) {
      check(
        table + " private to " + role,
        await pg.scalar(
          `select to_jsonb(has_table_privilege(${lit(role)},${
            lit("taskfold_private." + table)
          },'select,insert,update,delete'))`,
        ),
        false,
      );
    }
  }
  const omitted = {
    ...expiryRestore,
    audio_restoration_ack: {
      policy: "expired_recordings_omitted_v1",
      count: 1,
      retention_days: 30,
    },
  };
  await ok("restore", omitted);
  check(
    "explicit expired-media choice recovers task",
    (await root()).task_generation,
    expiryGeneration,
  );
  const omittedList = await http.call("list", {
    ...i.target,
    task_generation: expiryGeneration,
  });
  check(
    "recovered task never resurrects expired recordings",
    (await omittedList.json()).items,
    [],
  );
  check(
    "explicit omission consumes only expired recovery inventory",
    await pg.scalar(
      "select count(*)::int from taskfold_private.audio_task_deletions",
    ),
    0,
  );
  check("expired omission uploads no replacement bytes", http.state.uploads, 2);
  const findings = await pg.advisors();
  check(
    "no added advisor findings",
    findings.result.filter((x) =>
      !baseline.result.some((y) => y.cache_key === x.cache_key)
    ),
    [],
  );
} catch (error) {
  report.error = { message: error.message };
  throw error;
} finally {
  report.checkCount = Object.keys(report.checks).length;
  report.cleanupErrors = [];
  if (http) report.provider = http.state.providerResults;
  for (
    const [resource, key] of [
      [http, "httpClosed"],
      [storage, "storageRemoved"],
      [pg, "databaseRemoved"],
    ]
  ) {
    try {
      if (resource) {
        await resource.close();
        report[key] = true;
      }
    } catch (e) {
      report.cleanupErrors.push(e.message);
    }
  }
  await writeFile(output, JSON.stringify(report, null, 2) + "\n");
}
assert.deepEqual(report.cleanupErrors, []);
console.log(
  JSON.stringify({ checks: report.checkCount, cleanup: report.cleanupErrors }),
);
