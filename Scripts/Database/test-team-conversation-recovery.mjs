import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import {
  loadTeamConversationSchema,
  teamConversationMigration as migration,
} from "./team-conversation-schema.mjs";
const report = {
  checks: {},
  deployed: false,
  realDataChanged: false,
  nativeTeamUIEnabled: false,
  hostedAcceptanceClaimed: false,
  linkedBatchComplete: false,
};
const check = (n, a, b = true) => {
  assert.deepEqual(a, b, n);
  report.checks[n] = true;
};
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
const users = Object.fromEntries(
  ["owner", "editor", "author", "reader", "departed", "outsider"].map(
    (k) => [k, { id: randomUUID(), session: randomUUID() }],
  ),
);
const team = randomUUID(),
  project = randomUUID(),
  task = randomUUID(),
  generation = randomUUID();
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadTeamConversationSchema(pg.raw);
  report.migrationSHA256 = createHash("sha256").update(
    await readFile(
      new URL("../../supabase/migrations/" + migration, import.meta.url),
    ),
  ).digest("hex");
  if (process.env.TASKFOLD_TEAM_BATCH_REGRESSION === "1") {
    const { loadTeamBatchSchema, teamBatchMigration } = await import(
      "./team-batch-schema.mjs"
    );
    await loadTeamBatchSchema(pg.raw, { base: false });
    report.batchMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamBatchMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (process.env.TASKFOLD_TEAM_PLANNING_REGRESSION === "1") {
    const { loadTeamPlanningSchema, teamPlanningMigration } = await import(
      "./team-planning-schema.mjs"
    );
    await loadTeamPlanningSchema(pg.raw);
    report.planningMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamPlanningMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (process.env.TASKFOLD_TEAM_CHECKLIST_REGRESSION === "1") {
    if (process.env.TASKFOLD_TEAM_PLANNING_REGRESSION !== "1") {
      throw new Error("Checklist regression requires planning");
    }
    const { loadTeamChecklistSchema, teamChecklistMigration } = await import(
      "./team-checklist-schema.mjs"
    );
    await loadTeamChecklistSchema(pg.raw);
    report.checklistMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamChecklistMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  if (process.env.TASKFOLD_TEAM_COMPLETION_REGRESSION === "1") {
    if (process.env.TASKFOLD_TEAM_CHECKLIST_REGRESSION !== "1") {
      throw new Error("Completion regression requires checklist schema");
    }
    const { loadTeamCompletionSchema, teamCompletionMigration } = await import(
      "./team-completion-schema.mjs"
    );
    await loadTeamCompletionSchema(pg.raw, { base: false });
    report.completionMigrationSHA256 = createHash("sha256").update(
      await readFile(
        new URL(
          "../../supabase/migrations/" + teamCompletionMigration,
          import.meta.url,
        ),
      ),
    ).digest("hex");
  }
  for (const [n, u] of Object.entries(users)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${
        lit(n + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${
        lit(u.id)
      });`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(users.owner.id)
    },'Recovery team');` + Object.entries(users).filter(([n]) =>
      n !== "outsider"
    ).map(([n, u]) =>
      `insert into taskfold_private.team_members(team_id,user_id,role) values(${
        lit(team)
      },${lit(u.id)},${lit(n === "owner" ? "admin" : "member")});`
    ).join("") +
      `insert into public.projects(id,user_id,name) values(${lit(project)},${
        lit(users.owner.id)
      },'Discussion project');insert into taskfold_private.team_content_projects(project_id,team_id) values(${
        lit(project)
      },${
        lit(team)
      });insert into public.tasks(id,user_id,project_id,title,task_generation) values(${
        lit(task)
      },${lit(users.author.id)},${lit(project)},'Restore this discussion',${
        lit(generation)
      });update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true;`,
  );
  await pg.raw(
    `insert into taskfold_private.team_project_grants values('${project}','${team}','${users.reader.id}','viewer')`,
  );
  const run = (who, expr, opts = {}) => {
    const u = users[who];
    return pg.scalar(
      `begin;set application_name=${
        lit(opts.app ?? "team-conversation-" + randomUUID().slice(0, 8))
      };create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated,anon,service_role;set local role ${
        opts.role ?? "authenticated"
      };set local request.jwt.claim.sub=${
        lit(u.id)
      };set local request.jwt.claims=${
        lit(
          JSON.stringify({ sub: u.id, session_id: opts.session ?? u.session }),
        )
      };do $r$begin begin ${
        opts.statement ?? `insert into result values((${expr}),null,null);`
      }exception when others then insert into result values(null,sqlstate,left(sqlerrm,160));end;end$r$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`,
    );
  };
  const rpc = (who, op, b, opts) =>
    run(
      who,
      `public.taskfold_team_task_lifecycle(${lit(op)},${json(b)})`,
      opts,
    );
  const row = (id) =>
    pg.scalar(
      `select coalesce((select to_jsonb(t) from public.tasks t where id=${
        lit(id)
      }),'null'::jsonb)`,
    );
  const deletion = async (id = task) => {
    const r = await row(id);
    return {
      team_id: team,
      project_id: project,
      task_id: id,
      request_id: randomUUID(),
      task_generation: r.task_generation,
      record: r,
    };
  };
  const restore = (d) => {
    const g = randomUUID();
    return {
      ...d,
      request_id: randomUUID(),
      task_generation: g,
      record: { ...d.record, task_generation: g, completion_version: 0 },
      restore_from: d.request_id,
    };
  };
  // UUID arrays use typed SQL rather than JSON's bracket spelling.
  const comment = randomUUID(), soft = randomUUID(), mention = randomUUID();
  await pg.raw(
    `insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body,mention_ids,revision,created_at,updated_at) values(${
      lit(comment)
    },${lit(task)},${lit(generation)},${lit(project)},${
      lit(users.author.id)
    },'Keep the design review discussion',array[${lit(users.reader.id)}::uuid,${
      lit(users.departed.id)
    }::uuid],7,'2026-10-01T08:00:00Z','2026-10-02T08:00:00Z');insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body,mention_ids,revision,created_at,updated_at,deleted_at) values(${
      lit(soft)
    },${lit(task)},${lit(generation)},${
      lit(project)
    },null,'','{}',3,'2026-10-01T09:00:00Z','2026-10-02T09:00:00Z','2026-10-03T09:00:00Z');insert into public.task_mentions(id,comment_id,recipient_id,created_at,read_at,revision) values(${
      lit(mention)
    },${lit(comment)},${
      lit(users.reader.id)
    },'2026-10-01T08:00:00Z','2026-10-02T08:00:00Z',4),(${lit(randomUUID())},${
      lit(comment)
    },${lit(users.departed.id)},'2026-10-01T08:00:00Z',null,1);`,
  );
  const before = await pg.scalar(
    `select jsonb_agg(to_jsonb(c) order by c.id) from public.task_comments c where task_id=${
      lit(task)
    }`,
  );
  const d = await deletion();
  let result = await rpc("editor", "delete", d);
  check("discussion task deletion succeeds", result.code, null);
  check("root deleted", await row(task), null);
  check(
    "live comments removed",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.task_comments where task_id=${
        lit(task)
      }`,
    ),
    0,
  );
  check(
    "encrypted archive preserves both records",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_archive where request_id=${
        lit(d.request_id)
      }`,
    ),
    2,
  );
  check(
    "archive has no plaintext body",
    await pg.scalar(
      `select to_jsonb(not exists(select 1 from taskfold_private.team_conversation_archive where encode(payload,'escape') like '%Keep the design%'))`,
    ),
  );
  check(
    "receipt has no plaintext body",
    await pg.scalar(
      `select to_jsonb(not exists(select 1 from taskfold_private.team_task_edits where to_jsonb(team_task_edits)::text like '%design review discussion%'))`,
    ),
  );
  check(
    "archive state ready",
    await pg.scalar(
      `select to_jsonb(conversation_state) from taskfold_private.team_task_edits where request_id=${
        lit(d.request_id)
      }`,
    ),
    "ready",
  );
  check(
    "recovery lasts thirty days",
    await pg.scalar(
      `select to_jsonb(expires_at between clock_timestamp()+interval '29 days' and clock_timestamp()+interval '31 days') from taskfold_private.team_conversation_keys where request_id=${
        lit(d.request_id)
      }`,
    ),
  );
  check(
    "archive scope cleaned",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.team_conversation_scope",
    ),
    0,
  );
  check(
    "delete replay does not duplicate archive",
    (await rpc("editor", "delete", d)).value.replayed,
    true,
  );
  for (
    const table of [
      "team_conversation_keys",
      "team_conversation_archive",
      "team_conversation_ids",
      "team_conversation_scope",
    ]
  ) {
    check(
      table + " hidden",
      (await run(
        "editor",
        `(select to_jsonb(count(*)) from taskfold_private.${table})`,
      )).code,
      "42501",
    );
  }
  for (
    const fn of [
      `taskfold_private.expire_team_conversations(1)`,
      `taskfold_private.assert_team_conversation_undo(${lit(team)},${
        lit(d.request_id)
      })`,
    ]
  ) {
    check(
      "private helper " + fn.slice(17, 40) + " denied",
      (await run("editor", `to_jsonb(${fn})`)).code,
      "42501",
    );
  }
  check(
    "outsider cannot restore",
    (await rpc("outsider", "restore", restore(d))).code,
    "42501",
  );
  await pg.raw(
    `delete from taskfold_private.team_members where team_id=${
      lit(team)
    } and user_id=${lit(users.departed.id)};delete from auth.users where id=${
      lit(users.author.id)
    }`,
  );
  const undo = restore(d);
  result = await rpc("editor", "restore", undo);
  check("Undo restores task and discussion", result.code, null);
  const after = await pg.scalar(
      `select jsonb_agg(to_jsonb(c) order by c.created_at,c.id) from public.task_comments c where task_id=${
        lit(task)
      }`,
    ),
    active = after.find((c) => !c.deleted_at),
    tombstone = after.find((c) => c.deleted_at);
  check(
    "restored comments have fresh identities",
    after.every((c) => ![comment, soft].includes(c.id)),
  );
  check(
    "restored comments use new generation",
    after.every((c) => c.task_generation === undo.task_generation),
  );
  check("body preserved", active.body, "Keep the design review discussion");
  check("removed author remains anonymous", active.author_id, null);
  check("soft-deleted comment remains tombstone", tombstone.body, "");
  check(
    "tombstone time preserved",
    tombstone.deleted_at,
    "2026-10-03T09:00:00+00:00",
  );
  check(
    "original creation time preserved",
    active.created_at,
    "2026-10-01T08:00:00+00:00",
  );
  check("only current recipient retained", active.mention_ids, [
    users.reader.id,
  ]);
  const messages = await pg.scalar(
    `select jsonb_agg(to_jsonb(m)) from public.task_mentions m join public.task_comments c on c.id=m.comment_id where c.task_id=${
      lit(task)
    }`,
  );
  check("mention identity refreshed", messages[0].id !== mention);
  check(
    "read timestamp preserved",
    messages[0].read_at,
    "2026-10-02T08:00:00+00:00",
  );
  check(
    "mention creation time preserved",
    messages[0].created_at,
    "2026-10-01T08:00:00+00:00",
  );
  check(
    "current viewer can read restored thread",
    (await run(
      "reader",
      `(select to_jsonb(count(*)) from public.task_comments where task_id=${
        lit(task)
      })`,
    )).value,
    2,
  );
  check(
    "outsider cannot read restored thread",
    (await run(
      "outsider",
      `(select to_jsonb(count(*)) from public.task_comments where task_id=${
        lit(task)
      })`,
    )).value,
    0,
  );
  const native = {
    account: users.editor.id,
    project,
    task,
    oldGeneration: generation,
    newGeneration: undo.task_generation,
    before,
    after,
    mentions: messages,
    taskRow: result.value.task,
    undoBody: undo,
    undoReply: result.value,
  };
  check(
    "archive purged after Undo",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_archive where request_id=${
        lit(d.request_id)
      }`,
    ),
    0,
  );
  check(
    "key purged after Undo",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_keys where request_id=${
        lit(d.request_id)
      }`,
    ),
    0,
  );
  check(
    "receipt state restored",
    await pg.scalar(
      `select to_jsonb(conversation_state) from taskfold_private.team_task_edits where request_id=${
        lit(d.request_id)
      }`,
    ),
    "restored",
  );
  check(
    "repeated Undo has no extra discussion",
    (await rpc("editor", "restore", undo)).value.replayed,
    true,
  );
  check(
    "comment count stays two",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.task_comments where task_id=${
        lit(task)
      }`,
    ),
    2,
  );
  check(
    "old comment callback unavailable",
    (await run(
      "owner",
      `public.taskfold_write_comment(${lit(randomUUID())},${lit(comment)},${
        lit(task)
      },${lit(generation)},${lit(project)},7,'Old edit','{}',false)`,
    )).value.status,
    "unavailable",
  );
  check(
    "old mention callback unavailable",
    (await run(
      "reader",
      `public.taskfold_mark_mention(${lit(randomUUID())},${
        lit(mention)
      },4,true)`,
    )).value.status,
    "unavailable",
  );
  // Reusing a retired ID is blocked even for trusted SQL/native personal paths.
  const identity = await pg.value(`(select to_jsonb(1))`, { role: "postgres" });
  check("fixture operator available", identity.code, null);
  let collision = false;
  try {
    await pg.raw(
      `insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body) values(${
        lit(comment)
      },${lit(task)},${lit(undo.task_generation)},${lit(project)},${
        lit(users.owner.id)
      },'Reused old identity')`,
    );
  } catch (e) {
    collision = e.code === "PT409";
  }
  check("old comment identity cannot resurrect", collision);
  const expiredDelete = await deletion();
  check(
    "second discussion deletion works",
    (await rpc("editor", "delete", expiredDelete)).code,
    null,
  );
  await pg.raw(
    `update taskfold_private.team_conversation_keys set expires_at=clock_timestamp()-interval '1 second' where request_id=${
      lit(expiredDelete.request_id)
    }`,
  );
  check(
    "expired discussion prevents silent partial Undo",
    (await rpc("editor", "restore", restore(expiredDelete))).code,
    "PT410",
  );
  check("failed Undo has not recreated root", await row(task), null);
  const expirationHolder = await pg.hold(
    `select request_id from taskfold_private.team_task_edits where request_id=${
      lit(expiredDelete.request_id)
    } for update`,
  );
  check(
    "cleanup skips locked Undo receipt",
    await pg.scalar(
      "select to_jsonb(taskfold_private.expire_team_conversations(1))",
    ),
    0,
  );
  await expirationHolder.release("commit");
  check(
    "cleanup expires one archive",
    await pg.scalar(
      "select to_jsonb(taskfold_private.expire_team_conversations(1))",
    ),
    1,
  );
  check(
    "expired key removed",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_keys where request_id=${
        lit(expiredDelete.request_id)
      }`,
    ),
    0,
  );
  check(
    "expired receipt remains fenced",
    await pg.scalar(
      `select to_jsonb(conversation_state) from taskfold_private.team_task_edits where request_id=${
        lit(expiredDelete.request_id)
      }`,
    ),
    "expired",
  );
  const seedRoot = async (title = "More recovery") => {
    const id = randomUUID(), g = randomUUID();
    await pg.raw(
      `insert into public.tasks(id,user_id,project_id,title,task_generation) values(${
        lit(id)
      },${lit(users.owner.id)},${lit(project)},${lit(title)},${
        lit(g)
      });insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body) values(${
        lit(randomUUID())
      },${lit(id)},${lit(g)},${lit(project)},${
        lit(users.owner.id)
      },'Preserve this additional discussion')`,
    );
    return id;
  };
  const corruptRoot = await seedRoot("Atomic recovery"),
    corruptDelete = await deletion(corruptRoot);
  check(
    "atomic recovery fixture archived",
    (await rpc("editor", "delete", corruptDelete)).code,
    null,
  );
  const ciphertext = await pg.scalar(
    `select to_jsonb(encode(payload,'hex')) from taskfold_private.team_conversation_archive where request_id=${
      lit(corruptDelete.request_id)
    }`,
  );
  await pg.raw(
    `update taskfold_private.team_conversation_archive set payload=decode('00','hex') where request_id=${
      lit(corruptDelete.request_id)
    }`,
  );
  const atomicUndo = restore(corruptDelete);
  check(
    "corrupt recovery fails atomically",
    (await rpc("editor", "restore", atomicUndo)).code !== null,
  );
  check("corrupt recovery has no partial root", await row(corruptRoot), null);
  check(
    "corrupt recovery does not consume receipt",
    await pg.scalar(
      `select to_jsonb(restored_request is null) from taskfold_private.team_task_edits where request_id=${
        lit(corruptDelete.request_id)
      }`,
    ),
  );
  await pg.raw(
    `update taskfold_private.team_conversation_archive set payload=decode(${
      lit(ciphertext)
    },'hex') where request_id=${lit(corruptDelete.request_id)}`,
  );
  await pg.raw(
    `create function taskfold_private.fixture_interrupt_restore() returns trigger language plpgsql set search_path='' as $$begin if new.task_id=${
      lit(corruptRoot)
    }::uuid and new.task_generation<>${
      lit(corruptDelete.task_generation)
    }::uuid then raise exception using errcode='PT409',message='Owned restore interruption';end if;return new;end$$;create trigger z_fixture_interrupt_restore before insert on public.task_comments for each row execute function taskfold_private.fixture_interrupt_restore()`,
  );
  check(
    "write interruption rolls back whole Undo",
    (await rpc("editor", "restore", atomicUndo)).code,
    "PT409",
  );
  check(
    "write interruption leaves no restored root",
    await row(corruptRoot),
    null,
  );
  check(
    "write interruption keeps recovery key",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_keys where request_id=${
        lit(corruptDelete.request_id)
      }`,
    ),
    1,
  );
  check(
    "write interruption keeps Undo unconsumed",
    await pg.scalar(
      `select to_jsonb(restored_request is null) from taskfold_private.team_task_edits where request_id=${
        lit(corruptDelete.request_id)
      }`,
    ),
  );
  await pg.raw(
    "drop trigger z_fixture_interrupt_restore on public.task_comments;drop function taskfold_private.fixture_interrupt_restore()",
  );
  check(
    "repaired archive retries same Undo successfully",
    (await rpc("editor", "restore", atomicUndo)).code,
    null,
  );
  const racingRoot = await seedRoot("Concurrent discussion"),
    racingDelete = await deletion(racingRoot);
  const hold = await pg.hold(
    `select id from public.tasks where id=${lit(racingRoot)} for share`,
  );
  const waiting = rpc("editor", "delete", racingDelete, {
    app: "conversation-late-comment",
  });
  await pg.waitForLock("conversation-late-comment", hold.pid);
  await hold.release(
    "commit",
    `update public.task_comments set body='Latest discussion update',revision=revision+1 where task_id=${
      lit(racingRoot)
    }`,
  );
  check("delete waits for in-flight discussion", (await waiting).code, null);
  check(
    "racing discussion restores",
    (await rpc("editor", "restore", restore(racingDelete))).code,
    null,
  );
  check(
    "newest discussion preserved",
    await pg.scalar(
      `select to_jsonb(body) from public.task_comments where task_id=${
        lit(racingRoot)
      }`,
    ),
    "Latest discussion update",
  );
  const actorRoot = await seedRoot("Actor cleanup"),
    actorDelete = await deletion(actorRoot);
  check(
    "actor cleanup archive created",
    (await rpc("editor", "delete", actorDelete)).code,
    null,
  );
  await pg.raw(`delete from auth.users where id=${lit(users.editor.id)}`);
  check(
    "actor account removal purges key",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_keys where request_id=${
        lit(actorDelete.request_id)
      }`,
    ),
    0,
  );
  check(
    "actor account removal purges encrypted rows",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_archive where request_id=${
        lit(actorDelete.request_id)
      }`,
    ),
    0,
  );
  check(
    "deleted actor session cannot restore",
    (await rpc("editor", "restore", restore(actorDelete))).code,
    "28000",
  );
  const ownerRoot = await seedRoot("Whole team cleanup"),
    ownerDelete = await deletion(ownerRoot);
  check(
    "whole team archive created",
    (await rpc("owner", "delete", ownerDelete)).code,
    null,
  );
  const revision = await pg.scalar(
    `select to_jsonb(revision) from taskfold_private.teams where id=${
      lit(team)
    }`,
  );
  check(
    "owner deletes team with archived discussion",
    (await run(
      "owner",
      `public.taskfold_teams('delete',${
        json({
          team_id: team,
          request_id: randomUUID(),
          issued_at: new Date().toISOString(),
          revision,
        })
      })`,
    )).code,
    null,
  );
  check(
    "whole team removes every archive",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_archive where team_id=${
        lit(team)
      }`,
    ),
    0,
  );
  check(
    "whole team removes every recovery key",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_conversation_keys where team_id=${
        lit(team)
      }`,
    ),
    0,
  );
  check(
    "whole team leaves no live discussion",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.task_comments where project_id=${
        lit(project)
      }`,
    ),
    0,
  );
  check(
    "all conversation scopes cleaned",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.team_conversation_scope",
    ),
    0,
  );
  report.advisors = await pg.advisors();
  check(
    "no new advisor warnings",
    report.advisors.result.filter((x) =>
      ["WARN", "ERROR"].includes(x.level) && x.name !== "auth_rls_initplan"
    ),
    [],
  );
  report.containerRemoved = await pg.close();
  pg = null;
  report.checkCount = Object.keys(report.checks).length;
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
  }
  if (process.argv[3]) {
    await writeFile(process.argv[3], JSON.stringify(native, null, 2) + "\n");
  }
  console.log(
    JSON.stringify({
      checks: report.checkCount,
      containerRemoved: report.containerRemoved,
    }),
  );
} finally {
  if (pg) await pg.close();
}
