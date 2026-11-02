import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import {
  audioProjectCustodyMigration,
  loadAudioProjectCustodyDependencies,
  migrationSQL,
} from "./audio-project-custody-schema.mjs";
import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
const output = process.argv[2];
assert(output?.startsWith("/tmp/taskfold-"));
const candidate = await migrationSQL(audioProjectCustodyMigration);
const report = {
  checks: {},
  candidateSHA256: createHash("sha256").update(candidate).digest("hex"),
  runnerSHA256: createHash("sha256").update(
    await readFile(new URL(import.meta.url)),
  ).digest("hex"),
  deployed: false,
  normalUseEnabled: false,
  genuineAuthOrStorage: false,
};
const check = (n, a, b = true) => {
  assert.deepEqual(a, b, n);
  report.checks[n] = true;
};
const j = (x) => lit(JSON.stringify(x)) + "::jsonb";
let pg, http, sourceHTTP, destHTTP, primaryError;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadAudioProjectCustodyDependencies(pg);
  const users = Object.fromEntries(
    ["owner", "source", "destination", "outside"].map(
      (k) => [k, { id: randomUUID(), session: randomUUID() }],
    ),
  );
  for (const u of Object.values(users)) {
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
  const owner = users.owner,
    team = randomUUID(),
    p = randomUUID(),
    dest = randomUUID();
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(owner.id)
    },'Recording workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(owner.id)},'admin'),(${lit(team)},${
      lit(users.source.id)
    },'guest'),(${lit(team)},${lit(users.destination.id)},'guest');`,
  );
  for (const id of [p, dest]) {
    await pg.raw(
      `insert into public.projects(id,user_id,name) values(${lit(id)},${
        lit(owner.id)
      },'Private audio project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
        lit(id)
      },${lit(team)},'private')`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(p)},${
      lit(team)
    },${lit(users.source.id)},'viewer'),(${lit(dest)},${lit(team)},${
      lit(users.destination.id)
    },'viewer');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_task_types_enabled=true;update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true,completions_enabled=true;update taskfold_private.audio_comment_config set enabled=true,team_publication_enabled=true`,
  );
  const row = (id) =>
    pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(id)}`);
  const seed = async () => {
    const id = randomUUID();
    await pg.raw(
      `insert into public.tasks(id,user_id,project_id,title) values(${
        lit(id)
      },${lit(owner.id)},${lit(p)},'Task with a published recording')`,
    );
    return row(id);
  };
  const media = await readFile(
    new URL(
      "../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
      import.meta.url,
    ),
  );
  const audio = {
    version: 1,
    mime_type: "audio/mp4",
    byte_count: media.length,
    duration_ms: 1000,
    sha256: createHash("sha256").update(media).digest("hex"),
  };
  const intent = (t) => ({
    version: 1,
    account: owner.id,
    operation_id: randomUUID(),
    comment_id: randomUUID(),
    asset_id: randomUUID(),
    target: {
      task_id: t.id,
      task_generation: t.task_generation,
      project_id: t.project_id,
    },
    caption: "Keep this exact recording cafe\u0301 🌿",
    audio,
  });
  // Seed a genuinely pre-candidate synthetic ledger row; no binding backfill.
  const legacy = await seed(), old = intent(legacy);
  await pg.raw(
    `insert into taskfold_private.audio_comment_publications(operation_id,comment_id,asset_id,author_id,task_id,task_generation,project_id,request_hash,sha256,byte_count,caption,audio_descriptor,state,published_at) values(${
      lit(old.operation_id)
    },${lit(old.comment_id)},${lit(old.asset_id)},${lit(owner.id)},${
      lit(legacy.id)
    },${lit(legacy.task_generation)},${lit(p)},decode(repeat('ab',32),'hex'),${
      lit(audio.sha256)
    },${audio.byte_count},${lit(old.caption)},${j(audio)},'published',now())`,
  );
  const preMigrationTask = await seed(),
    preScope = {
      team_id: team,
      task_id: preMigrationTask.id,
      task_generation: preMigrationTask.task_generation,
      source_project_id: p,
      destination_project_id: dest,
    };
  const oldRPC = (op, body) =>
    pg.scalar(
      `begin;set local role authenticated;set local request.jwt.claim.sub=${
        lit(owner.id)
      };set local request.jwt.claims=${
        lit(JSON.stringify({ sub: owner.id, session_id: owner.session }))
      };select public.taskfold_team_task_move(${lit(op)},${j(body)});commit;`,
    );
  const preReview = await oldRPC("review", preScope),
    preCommand = {
      ...preScope,
      request_id: randomUUID(),
      expires_at: preReview.expires_at,
      review_token: preReview.review_token,
    };
  await oldRPC("move", preCommand);
  report.baselineAdvisors = await pg.advisors();
  await pg.raw(candidate);
  const run = (expr, who = "owner") => {
    const u = users[who];
    return pg.scalar(
      `begin;create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated;set local role authenticated;set local request.jwt.claim.sub=${
        lit(u.id)
      };set local request.jwt.claims=${
        lit(JSON.stringify({ sub: u.id, session_id: u.session }))
      };do $r$begin begin insert into result values(to_jsonb(${expr}),null,null);exception when others then insert into result values(null,sqlstate,sqlerrm);end;end$r$;select to_jsonb(r) from result r;commit;`,
    );
  };
  const rpc = (op, b) => `public.taskfold_team_task_move(${lit(op)},${j(b)})`;
  const ok = async (op, b, who = "owner") => {
    const r = await run(rpc(op, b), who);
    assert.equal(r.code, null, JSON.stringify(r));
    return r.value;
  };
  const denied = async (n, op, b, code = "PT409", who = "owner") =>
    check(n, (await run(rpc(op, b), who)).code, code);
  const scope = (t, from = t.project_id, to = dest, undoes = null) => ({
    team_id: team,
    task_id: t.id,
    task_generation: t.task_generation,
    source_project_id: from,
    destination_project_id: to,
    ...(undoes ? { undoes } : {}),
  });
  const command = (s, r, ack = true) => ({
    ...s,
    request_id: randomUUID(),
    expires_at: r.expires_at,
    review_token: r.review_token,
    ...(ack && r.audio_custody_count > 0
      ? {
        audio_custody_ack: {
          policy: r.audio_custody_policy,
          count: r.audio_custody_count,
        },
      }
      : {}),
  });
  const audioCommand = async (action, b, who = "owner") => {
    const u = users[who];
    const r = await pg.value(
      `public.taskfold_audio_comment_command(${lit(action)},${lit(u.id)},${
        lit(u.session)
      },${j(b)})`,
    );
    assert.equal(r.code, null, JSON.stringify(r));
    return r.value;
  };
  const read = (i, who) =>
    audioCommand("read", { comment_id: i.comment_id }, who);
  const custody = (i) =>
    pg.scalar(
      `select coalesce((select to_jsonb(c) from taskfold_private.audio_comment_custody c where operation_id=${
        lit(i.operation_id)
      }),'null'::jsonb)`,
    );
  const ledger = (i) =>
    pg.scalar(
      `select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${
        lit(i.operation_id)
      }`,
    );
  const preUndoScope = scope(preMigrationTask, dest, p, preCommand.request_id),
    preUndoReview = await ok("review_undo", preUndoScope);
  check(
    "pre-migration ordinary Undo remains reviewable",
    preUndoReview.audio_custody_count,
    0,
  );
  await ok("undo", command(preUndoScope, preUndoReview));
  check(
    "pre-migration Undo restores original project",
    (await row(preMigrationTask.id)).project_id,
    p,
  );
  check("legacy publication is not silently bound", await custody(old), null);
  await denied(
    "unbound legacy media blocks move review",
    "review",
    scope(legacy),
  );
  check(
    "legacy media stays readable in original project",
    (await read(old, "source")).target.project_id,
    p,
  );
  const plain = await seed(),
    plainScope = scope(plain),
    plainReview = await ok("review", plainScope);
  check(
    "ordinary review reports zero recordings",
    plainReview.audio_custody_count,
    0,
  );
  const plainCommand = command(plainScope, plainReview);
  check(
    "ordinary request needs no audio acknowledgement",
    Object.hasOwn(plainCommand, "audio_custody_ack"),
    false,
  );
  await ok("move", plainCommand);
  check(
    "ordinary move remains available",
    (await row(plain.id)).project_id,
    dest,
  );
  const personalProject = randomUUID(),
    personalTask = randomUUID(),
    personalGeneration = randomUUID();
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${
      lit(personalProject)
    },${
      lit(owner.id)
    },'Personal project with recording');insert into public.tasks(id,user_id,project_id,task_generation,title) values(${
      lit(personalTask)
    },${lit(owner.id)},${lit(personalProject)},${
      lit(personalGeneration)
    },'Private recording task')`,
  );
  const personalIntent = intent({
    id: personalTask,
    task_generation: personalGeneration,
    project_id: personalProject,
  });
  check(
    "personal pending publication remains available",
    (await audioCommand("reserve", personalIntent)).state,
    "pending",
  );
  try {
    await pg.raw(
      `insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
        lit(personalProject)
      },${lit(team)},'team')`,
    );
    assert.fail("Adoption needs audio review");
  } catch (error) {
    check(
      "project adoption cannot silently expose pending audio",
      error.code,
      "PT409",
    );
  }
  const personalClose = await pg.value(
    `public.taskfold_audio_owner_publication(${lit(owner.id)},${
      lit(owner.session)
    },${j({ intent: personalIntent, close: true })})`,
  );
  check(
    "personal sender can close after refused adoption",
    personalClose.value.state,
    "closed",
  );
  http = await createAudioHttpFixture(pg, owner.id, owner.session);
  let task = await seed();
  const i = intent(task),
    fileID = randomUUID(),
    fileAttachment = {
      id: randomUUID(),
      name: "Synthetic companion.pdf",
      storage_object_id: fileID,
    };
  await pg.raw(
    `insert into storage.objects(id,bucket_id,name,owner,owner_id,metadata,version) values(${
      lit(fileID)
    },'task-attachments',${lit(owner.id + "/" + fileID)},${lit(owner.id)},${
      lit(owner.id)
    },'{"size":128,"mimetype":"application/pdf"}','v1');insert into taskfold_private.team_content_files(object_id,project_id,task_id,task_generation) values(${
      lit(fileID)
    },${lit(p)},${lit(task.id)},${
      lit(task.task_generation)
    });update public.tasks set attachments=${j([fileAttachment])} where id=${
      lit(task.id)
    }`,
  );
  task = await row(task.id);
  const published = await http.call("publish", {
    intent: i,
    audio_base64: media.toString("base64"),
  });
  check(
    "production gateway publishes a bound recording",
    published.status,
    200,
  );
  const originalReceipt = (await published.json()).receipt;
  const originalLedger = await ledger(i), originalCustody = await custody(i);
  check(
    "publication creates exact task binding",
    originalCustody.task_id,
    task.id,
  );
  check(
    "new binding uses original generation",
    originalCustody.task_generation,
    task.task_generation,
  );
  const s = scope(task), review = await ok("review", s);
  check("review counts recordings", review.audio_custody_count, 1);
  check("review keeps companion file inventory", review.file_custody_count, 1);
  check(
    "review states exact custody policy",
    review.audio_custody_policy,
    "published_same_generation_v1",
  );
  report.clientSample = {
    origin: "https://synthetic.example",
    scope: s,
    review,
    intent: i,
    senderReceipt: originalReceipt,
  };
  await denied(
    "unaware client cannot move recordings",
    "move",
    command(s, review, false),
  );
  await denied("wrong recording acknowledgement refuses", "move", {
    ...command(s, review),
    audio_custody_ack: { policy: "published_same_generation_v1", count: 2 },
  });
  check("refused moves keep exact root", await row(task.id), task);
  const busy = await pg.hold(
    `select 1 from taskfold_private.audio_comment_publications where operation_id=${
      lit(i.operation_id)
    } for update`,
  );
  try {
    await denied("busy media refuses review without waiting", "review", s);
  } finally {
    await busy.release("rollback");
  }
  try {
    await pg.raw(
      `update public.tasks set task_generation=gen_random_uuid() where id=${
        lit(task.id)
      }`,
    );
    assert.fail("Recording generation must not change");
  } catch (error) {
    check("uncertified generation change remains closed", error.code, "23514");
  }
  const cmd = command(s, review);
  report.clientSample.command = cmd;
  report.clientSample.reply = await ok("move", cmd);
  check("reviewed move changes project", (await row(task.id)).project_id, dest);
  check(
    "recording follows current project",
    (await custody(i)).project_id,
    dest,
  );
  check("immutable ledger stays byte-exact", await ledger(i), originalLedger);
  check(
    "companion file follows mixed-media move",
    await pg.scalar(
      `select to_jsonb(project_id) from taskfold_private.team_content_files where object_id=${
        lit(fileID)
      }`,
    ),
    dest,
  );
  check(
    "old project viewer loses audio",
    (await read(i, "source")).status,
    "unavailable",
  );
  check(
    "destination viewer reads current target",
    (await read(i, "destination")).target.project_id,
    dest,
  );
  check(
    "outside account gains no audio",
    (await read(i, "outside")).status,
    "unavailable",
  );
  check(
    "object path remains unchanged",
    (await read(i, "destination")).object_name,
    originalLedger.object_name,
  );
  const liveRead = await read(i, "destination");
  report.clientSample.liveRead = Object.fromEntries(
    Object.entries(liveRead).filter(([key]) =>
      !["bucket", "object_name"].includes(key)
    ),
  );
  const status = await http.call("resolve", { intent: i, close: false });
  check("sender status survives the move", status.status, 200);
  check(
    "sender receipt remains original",
    (await status.json()).receipt,
    originalReceipt,
  );
  const repeat = await ok("move", cmd);
  check("lost-reply retry is a replay", repeat.replayed, true);
  check("retry does not alter custody", await custody(i), {
    ...originalCustody,
    project_id: dest,
  });
  const us = scope(task, dest, p, cmd.request_id),
    ur = await ok("review_undo", us);
  check("Undo reviews same recordings", ur.audio_custody_count, 1);
  await ok("undo", command(us, ur));
  check("Undo restores project audience", (await custody(i)).project_id, p);
  check(
    "Undo restores source read access",
    (await read(i, "source")).state,
    "published",
  );
  check(
    "Undo revokes destination read access",
    (await read(i, "destination")).status,
    "unavailable",
  );
  check("Undo keeps original ledger", await ledger(i), originalLedger);
  check(
    "Undo returns companion file custody",
    await pg.scalar(
      `select to_jsonb(project_id) from taskfold_private.team_content_files where object_id=${
        lit(fileID)
      }`,
    ),
    p,
  );
  // Same actor can read both projects; a mid-download move must still withhold
  // bytes from the previous task context, not merely check a generic membership.
  const rr = await ok("review", s), redo = command(s, rr);
  http.state.afterGet = async () => {
    await ok("move", redo);
  };
  const moving = await http.call("download", { comment_id: i.comment_id });
  check("mid-download move withholds bytes", moving.status, 503);
  await moving.arrayBuffer();
  http.state.afterGet = null;
  destHTTP = await createAudioHttpFixture(
    pg,
    users.destination.id,
    users.destination.session,
  );
  destHTTP.state.objects = http.state.objects;
  const bytes = await destHTTP.call("download", { comment_id: i.comment_id });
  check("destination gateway downloads after move", bytes.status, 200);
  check(
    "recording bytes remain exact",
    Buffer.from(await bytes.arrayBuffer()),
    media,
  );
  sourceHTTP = await createAudioHttpFixture(
    pg,
    users.source.id,
    users.source.session,
  );
  sourceHTTP.state.objects = http.state.objects;
  const removedAccess = await sourceHTTP.call("download", {
    comment_id: i.comment_id,
  });
  check("old audience gateway refuses bytes", removedAccess.status, 404);
  await removedAccess.arrayBuffer();
  check(
    "old audience cannot fetch provider bytes",
    sourceHTTP.state.storageRequests,
    0,
  );
  const target = { ...i.target, project_id: dest };
  const page = await pg.value(
    `public.taskfold_audio_comment_page(${lit(users.destination.id)},${
      lit(users.destination.session)
    },${j({ target, after: null })})`,
  );
  assert.equal(page.code, null, JSON.stringify(page));
  check(
    "keyset page follows current project",
    page.value.items[0].target,
    target,
  );
  check(
    "legacy list follows current project",
    (await audioCommand("list", target, "destination")).items[0].target,
    target,
  );
  const otherTeam = randomUUID();
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${
      lit(otherTeam)
    },${
      lit(owner.id)
    },'Other team');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(otherTeam)
    },${lit(owner.id)},'admin')`,
  );
  try {
    await pg.raw(
      `update taskfold_private.team_content_projects set team_id=${
        lit(otherTeam)
      } where project_id=${lit(dest)}`,
    );
    assert.fail("Realm transfer needs audio review");
  } catch (error) {
    check(
      "whole-project team transfer requires audio review",
      error.code,
      "PT409",
    );
  }
  try {
    await pg.raw(
      `delete from taskfold_private.team_content_projects where project_id=${
        lit(dest)
      }`,
    );
    assert.fail("Team detachment needs audio review");
  } catch (error) {
    check(
      "whole-project detachment requires audio review",
      error.code,
      "PT409",
    );
  }
  const back = scope(task, dest, p), stale = await ok("review", back);
  await pg.raw(
    `update storage.objects set version='changed' where id=${
      lit(originalCustody.object_id)
    }`,
  );
  await denied(
    "changed storage metadata invalidates signed review",
    "move",
    command(back, stale),
  );
  await pg.raw(
    `update storage.objects set version=null where id=${
      lit(originalCustody.object_id)
    }`,
  );
  const pending = intent(await row(task.id));
  check(
    "reserve pending recording",
    (await audioCommand("reserve", pending)).state,
    "pending",
  );
  await denied("pending publication blocks reviewed move", "review", back);
  const close = await pg.value(
    `public.taskfold_audio_owner_publication(${lit(owner.id)},${
      lit(owner.session)
    },${j({ intent: pending, close: true })})`,
  );
  check("sender can close pending publication", close.value.state, "closed");
  try {
    await pg.raw(
      `update taskfold_private.audio_comment_custody set project_id=${
        lit(p)
      } where operation_id=${lit(i.operation_id)}`,
    );
    assert.fail("No unreviewed custody update");
  } catch (error) {
    check("unreviewed custody update refuses", error.code, "42501");
  }
  const beforeMissing = await custody(i);
  await pg.raw(
    `delete from storage.objects where id=${lit(beforeMissing.object_id)}`,
  );
  check(
    "missing provider metadata preserves last known custody",
    await custody(i),
    beforeMissing,
  );
  await pg.raw(
    "update taskfold_private.audio_comment_config set enabled=false,team_publication_enabled=false",
  );
  check(
    "manager removes in current destination",
    (await audioCommand("remove", { comment_id: i.comment_id })).state,
    "retired",
  );
  await denied(
    "removed recording invalidates move Undo",
    "review_undo",
    scope(task, dest, p, redo.request_id),
  );
  check(
    "removal does not rewrite original target",
    (await ledger(i)).project_id,
    p,
  );
  check("published bytes await fenced cleanup", http.state.objects.size, 1);
  for (const role of ["anon", "authenticated", "service_role"]) {
    check(
      role + " cannot directly update custody",
      await pg.scalar(
        `select to_jsonb(has_table_privilege(${
          lit(role)
        },'taskfold_private.audio_comment_custody','update'))`,
      ),
      false,
    );
  }
  report.finalAdvisors = await pg.advisors();
  report.addedAdvisors = report.finalAdvisors.result.filter((x) =>
    !report.baselineAdvisors.result.some((y) => y.cache_key === x.cache_key)
  );
  check("no new advisor findings", report.addedAdvisors, []);
  report.checkCount = Object.keys(report.checks).length;
} catch (error) {
  primaryError = error;
  report.error = { message: error.message, code: error.code ?? null };
} finally {
  report.cleanupErrors = [];
  for (const x of [sourceHTTP, destHTTP, http]) {
    if (x) {
      try {
        await x.close();
      } catch (error) {
        report.cleanupErrors.push(error.message);
      }
    }
  }
  if (pg) {
    try {
      report.ownedPostgresContainerRemoved = await pg.close();
    } catch (error) {
      report.cleanupErrors.push(error.message);
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
