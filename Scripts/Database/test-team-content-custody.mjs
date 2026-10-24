// Actual local PostgreSQL, synthetic identities, no hosted writes or app processes.
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { loadAutomationPostgresSchema } from "./automation-postgres-schema.mjs";
const report = {
  checks: {},
  deployed: false,
  teamAccessEnabled: false,
  hostedAcceptanceClaimed: false,
  storageProviderDeliveryClaimed: false,
  realDataChanged: false,
};
const check = (name, actual, expected) => {
  assert.deepEqual(actual, expected, name);
  report.checks[name] = true;
};
const source = (p) => readFile(new URL("../../" + p, import.meta.url), "utf8");
const migration = "supabase/migrations/20261024022352_team_content_custody.sql";
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  report.postgresVersion = pg.serverVersion;
  await loadAutomationPostgresSchema(pg.raw);
  // Additional inspected hosted dependencies, not invented native routines.
  await pg.raw(
    "create table storage.buckets(id text primary key,public boolean not null);insert into storage.buckets values('avatars',true),('task-attachments',false);alter table auth.users add column email_confirmed_at timestamptz;create function auth.jwt() returns jsonb language sql stable set search_path='' as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;alter table public.sections add column user_id uuid references auth.users(id) on delete cascade;alter table public.project_collaborators enable row level security;alter table public.projects enable row level security;alter table public.sections enable row level security;grant select,insert,update,delete on public.sections to authenticated;drop function public.is_project_owner(uuid,uuid);create function public.is_project_owner(_user_id uuid,_project_id uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.projects where id=_project_id and user_id=_user_id)$$;create policy fixture_collaborator_read on public.project_collaborators for select to authenticated using(user_id=auth.uid() or public.is_project_owner(auth.uid(),project_id));create policy fixture_project_access on public.projects to authenticated using(user_id=auth.uid() or public.has_project_access(auth.uid(),id)) with check(user_id=auth.uid() or public.has_project_access(auth.uid(),id));create policy fixture_section_access on public.sections to authenticated using(public.has_project_access(auth.uid(),project_id)) with check(public.has_project_access(auth.uid(),project_id));",
  );
  await pg.raw(
    await source(
      "supabase/migrations/20261006100647_task_activity_history.sql",
    ),
  );
  await pg.raw(
    await source(
      "supabase/migrations/20261006100920_task_activity_cascade_authorization.sql",
    ),
  );
  await pg.raw(
    await source("supabase/migrations/20261024021629_team_organization.sql"),
  );
  const owner = randomUUID(),
    author = randomUUID(),
    survivor = randomUUID(),
    outsider = randomUUID();
  const session = randomUUID(), survivorSession = randomUUID();
  for (const id of [owner, author, survivor, outsider]) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${lit(id)},${
        lit(id + "@example.invalid")
      },now());insert into public.profiles values(${lit(id)});`,
    );
  }
  await pg.raw(
    `insert into auth.sessions(id,user_id) values(${lit(session)},${
      lit(owner)
    }),(${lit(survivorSession)},${lit(survivor)});`,
  );
  const personal = randomUUID(),
    shared = randomUUID(),
    project = randomUUID(),
    team = randomUUID();
  for (
    const [id, uid] of [[personal, author], [shared, author], [project, author]]
  ) {
    await pg.raw(
      `insert into public.projects(id,user_id,name) values(${lit(id)},${
        lit(uid)
      },'Synthetic project')`,
    );
  }
  const personalTask = randomUUID(),
    sharedTask = randomUUID(),
    teamTask = randomUUID(),
    foreignTask = randomUUID(),
    deletedTask = randomUUID(),
    child = randomUUID();
  for (
    const [id, uid, pid, parent] of [
      [personalTask, author, personal, null],
      [sharedTask, author, shared, null],
      [teamTask, author, project, null],
      [foreignTask, survivor, shared, null],
      [deletedTask, author, project, null],
      [child, survivor, project, personalTask],
    ]
  ) {
    await pg.raw(
      `insert into public.tasks(id,user_id,project_id,title,recurrence_parent_id) values(${
        lit(id)
      },${lit(uid)},${lit(pid)},'Synthetic retained work',${
        parent ? lit(parent) : "null"
      })`,
    );
  }
  const section = randomUUID(), oldSection = randomUUID();
  await pg.raw(
    `insert into public.sections(id,project_id,user_id,name) values(${
      lit(section)
    },${lit(project)},${lit(author)},'Retained section'),(${lit(oldSection)},${
      lit(personal)
    },${
      lit(author)
    },'Personal section');alter table public.project_collaborators disable trigger taskfold_prepare_invitation;insert into public.project_collaborators(id,project_id,user_id,invited_by,status) values(${
      lit(randomUUID())
    },${lit(shared)},${lit(survivor)},${
      lit(author)
    },'accepted');alter table public.project_collaborators enable trigger taskfold_prepare_invitation;`,
  );
  // Existing schema guard only permits owner-created pending invitations. Trusted
  // fixture setup explicitly disables that one invitation trigger while seeding.
  const sql = await source(migration);
  report.migrationSHA256 = createHash("sha256").update(sql).digest("hex");
  await pg.raw(sql);
  check(
    "backfill all live identities",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.content_identities",
    ),
    4,
  );
  await pg.raw(
    `begin;insert into taskfold_private.teams(id,owner_id,name) values(${
      lit(team)
    },${
      lit(owner)
    },'Synthetic team');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(owner)},'admin'),(${lit(team)},${
      lit(author)
    },'member');insert into taskfold_private.team_content_projects values(${
      lit(project)
    },${lit(team)});commit;`,
  );
  check(
    "existing generation bindings captured",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_content_tasks where team_id=${
        lit(team)
      }`,
    ),
    3,
  );
  const object = randomUUID(), personalObject = randomUUID();
  await pg.raw(
    `insert into storage.objects(id,bucket_id,name,owner,owner_id) values(${
      lit(object)
    },'task-attachments',${lit(author + "/retained")},${lit(author)},${
      lit(author)
    }),(${lit(personalObject)},'avatars',${lit(author + "/personal")},${
      lit(author)
    },${lit(author)});insert into taskfold_private.team_content_files values(${
      lit(object)
    },${lit(project)});`,
  );
  check(
    "cannot bind public avatar",
    await pg.raw(
      `insert into taskfold_private.team_content_files values(${
        lit(personalObject)
      },${lit(project)})`,
    ).then(() => null, (e) => e.code),
    "22023",
  );
  check(
    "bound attachment bucket cannot become public",
    await pg.raw(
      "update storage.buckets set public=true where id='task-attachments'",
    ).then(() => null, (e) => e.code),
    "PT409",
  );
  check(
    "bound object cannot move to public bucket",
    await pg.raw(
      `update storage.objects set bucket_id='avatars' where id=${lit(object)}`,
    ).then(() => null, (e) => e.code),
    "PT409",
  );
  const auth = (uid, expression) =>
    pg.scalar(
      `begin;create temp table custody_result(value jsonb,code text) on commit drop;grant all on custody_result to authenticated;set local role authenticated;set local request.jwt.claim.sub=${
        lit(uid)
      };set local request.jwt.claims=${
        lit(
          JSON.stringify({
            sub: uid,
            session_id: uid === owner ? session : survivorSession,
          }),
        )
      };do $t$begin begin insert into custody_result values((${expression}),null);exception when others then insert into custody_result values(null,sqlstate);end;end$t$;select jsonb_build_object('value',value,'code',code) from custody_result;commit;`,
    );
  for (const uid of [author, owner, outsider]) {
    check(
      "team project closed " + uid,
      (await auth(
        uid,
        `(select to_jsonb(count(*)) from public.projects where id=${
          lit(project)
        })`,
      )).value,
      0,
    );
    check(
      "team task closed " + uid,
      (await auth(
        uid,
        `(select to_jsonb(count(*)) from public.tasks where id=${
          lit(teamTask)
        })`,
      )).value,
      0,
    );
    check(
      "team section closed " + uid,
      (await auth(
        uid,
        `(select to_jsonb(count(*)) from public.sections where id=${
          lit(section)
        })`,
      )).value,
      0,
    );
    check(
      "team history closed " + uid,
      (await auth(
        uid,
        `(select to_jsonb(count(*)) from public.task_activity where task_id=${
          lit(teamTask)
        })`,
      )).value,
      0,
    );
    check(
      "team attachment closed " + uid,
      (await auth(
        uid,
        `(select to_jsonb(count(*)) from storage.objects where id=${
          lit(object)
        })`,
      )).value,
      0,
    );
    check(
      "team legacy helper closed " + uid,
      (await auth(
        uid,
        `to_jsonb(public.has_project_access(${lit(uid)},${lit(project)}))`,
      )).value,
      false,
    );
  }
  const write = (uid, statement) =>
    pg.scalar(
      `begin;create temp table write_result(value jsonb,code text) on commit drop;grant all on write_result to authenticated;set local role authenticated;set local request.jwt.claim.sub=${
        lit(uid)
      };do $w$declare n bigint;begin begin ${statement};get diagnostics n=row_count;insert into write_result values(to_jsonb(n),null);exception when others then insert into write_result values(null,sqlstate);end;end$w$;select jsonb_build_object('value',value,'code',code) from write_result;commit;`,
    );
  check(
    "direct team task update affects no rows",
    (await write(
      author,
      `update public.tasks set title='Must not edit' where id=${lit(teamTask)}`,
    )).value,
    0,
  );
  check(
    "direct team task deletion affects no rows",
    (await write(author, `delete from public.tasks where id=${lit(teamTask)}`))
      .value,
    0,
  );
  check(
    "direct team project update affects no rows",
    (await write(
      author,
      `update public.projects set name='Must not edit' where id=${
        lit(project)
      }`,
    )).value,
    0,
  );
  check(
    "direct team section update affects no rows",
    (await write(
      author,
      `update public.sections set name='Must not edit' where id=${
        lit(section)
      }`,
    )).value,
    0,
  );
  check(
    "direct team insert denied",
    (await write(
      author,
      `insert into public.tasks(id,user_id,project_id,title) values(${
        lit(randomUUID())
      },${lit(author)},${lit(project)},'Must not create')`,
    )).code,
    "PT503",
  );
  check(
    "direct cross-boundary move denied",
    (await write(
      author,
      `update public.tasks set project_id=${lit(project)} where id=${
        lit(personalTask)
      }`,
    )).code,
    "PT503",
  );
  check(
    "native guarded team patch denied",
    (await auth(
      author,
      `to_jsonb(public.taskfold_patch_task(${
        lit(teamTask)
      },'{"title":"Synthetic retained work"}'::jsonb,'{"title":"Must not edit"}'::jsonb))`,
    )).code,
    "P0001",
  );
  const teamBaseline = await pg.scalar(
    `select to_jsonb(t) from public.tasks t where id=${lit(teamTask)}`,
  );
  check(
    "native inaccessible delete remains opaque",
    (await auth(
      author,
      `to_jsonb(public.taskfold_delete_task(${lit(teamTask)},${
        lit(JSON.stringify(teamBaseline))
      }::jsonb))`,
    )).value,
    true,
  );
  check(
    "native opaque delete preserves team row",
    await pg.scalar(
      `select to_jsonb(t) from public.tasks t where id=${lit(teamTask)}`,
    ),
    teamBaseline,
  );
  check(
    "private content identities cannot be read",
    (await auth(
      author,
      "(select to_jsonb(count(*)) from taskfold_private.content_identities)",
    )).code,
    "42501",
  );
  check(
    "private binding cannot be inserted",
    (await write(
      author,
      `insert into taskfold_private.team_content_projects values(${
        lit(personal)
      },${lit(team)})`,
    )).code,
    "42501",
  );
  check(
    "ordinary own project readable",
    (await auth(
      author,
      `(select to_jsonb(count(*)) from public.projects where id=${
        lit(personal)
      })`,
    )).value,
    1,
  );
  check(
    "ordinary accepted collaborator readable",
    (await auth(
      survivor,
      `to_jsonb(public.has_project_access(${lit(survivor)},${lit(shared)}))`,
    )).value,
    true,
  );
  check(
    "ordinary outsider denied",
    (await auth(
      outsider,
      `to_jsonb(public.has_project_access(${lit(outsider)},${lit(shared)}))`,
    )).value,
    false,
  );
  check(
    "team service path closed",
    (await pg.value(
      `to_jsonb(taskfold_private.automation_lock_project(${lit(author)},${
        lit(project)
      }))`,
      { role: "postgres" },
    )).code,
    "PT503",
  );
  check(
    "legacy service path preserved",
    (await pg.value(
      `to_jsonb(taskfold_private.automation_lock_project(${lit(survivor)},${
        lit(shared)
      }))`,
      { role: "postgres" },
    )).code,
    null,
  );
  check(
    "native caller cannot forge private delete authority",
    (await write(
      author,
      `insert into taskfold_private.team_content_operations values(txid_current(),${
        lit(team)
      })`,
    )).code,
    "42501",
  );
  const personalBaseline = await pg.scalar(
    `select to_jsonb(t) from public.tasks t where id=${lit(personalTask)}`,
  );
  check(
    "native personal deletion cannot cascade into closed team task",
    (await auth(
      author,
      `to_jsonb(public.taskfold_delete_task(${lit(personalTask)},${
        lit(JSON.stringify(personalBaseline))
      }::jsonb))`,
    )).code,
    "PT503",
  );
  check(
    "blocked native cascade preserves both rows",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.tasks where id in(${
        lit(personalTask)
      },${lit(child)})`,
    ),
    2,
  );
  // Actual service-role API entry points preserve personal work and omit teams.
  const key = randomUUID(), hash = "b".repeat(64), apiTask = randomUUID();
  await pg.raw(
    `insert into taskfold_private.automation_keys(id,user_id,name,token_hash,scopes,ttl_days,expires_at) values(${
      lit(key)
    },${lit(author)},'Synthetic custody API',${
      lit(hash)
    },array['tasks:read','tasks:create'],30,clock_timestamp()+interval '1 day')`,
  );
  const api = (kind, action, body) =>
    pg.value(
      `public.taskfold_automation_${kind}(${lit(key)},${lit(hash)},${
        lit(action)
      },${lit(JSON.stringify(body))}::jsonb)`,
      { role: "service_role" },
    );
  const apiBody = (id, project_id) => ({
    request_id: randomUUID(),
    id,
    task_generation: randomUUID(),
    time_zone: "UTC",
    fields: { title: "API personal regression", project_id },
  });
  check(
    "actual API personal create works",
    (await api("write", "create", apiBody(apiTask, personal))).code,
    null,
  );
  check(
    "actual API team create denied",
    (await api("write", "create", apiBody(randomUUID(), project))).code,
    "PT503",
  );
  check(
    "actual API team get denied",
    (await api("read", "get", { id: teamTask })).code,
    "PT503",
  );
  const page = await api("read", "list", {});
  check("actual API list succeeds", page.code, null);
  check(
    "actual API list excludes team tasks",
    page.value.tasks.map((x) => x.id).sort(),
    [personalTask, sharedTask, foreignTask, apiTask].sort(),
  );
  // Delete a team task now: its generation/history survive the author's later exit.
  await pg.raw(`delete from public.tasks where id=${lit(deletedTask)}`);
  const beforeTask = await pg.scalar(
    `select to_jsonb(t) from public.tasks t where id=${lit(teamTask)}`,
  );
  const beforeGeneration = await pg.scalar(
    `select to_jsonb(g) from taskfold_private.task_generations g where task_id=${
      lit(teamTask)
    }`,
  );
  const beforeSection = await pg.scalar(
    `select to_jsonb(s) from public.sections s where id=${lit(section)}`,
  );
  const token = "a".repeat(64);
  await pg.raw(
    `insert into taskfold_private.account_removal_receipts(token_hash,account_id) values(${
      lit(token)
    },${lit(author)})`,
  );
  const files = await pg.value(
    `public.taskfold_account_removal_files(${lit(token)})`,
    { role: "service_role" },
  );
  check("removal lists only personal file", files.value, [{
    bucket: "avatars",
    name: author + "/personal",
  }]);
  // Fixture represents a confirmed Storage API deletion; no hosted Storage SQL.
  await pg.raw(`delete from storage.objects where id=${lit(personalObject)}`);
  check(
    "prepare removal succeeds",
    (await pg.value(
      `to_jsonb(public.taskfold_account_removal_prepare(${lit(token)}))`,
      { role: "service_role" },
    )).value,
    author,
  );
  check(
    "surviving recurrence detached from disappearing personal root",
    await pg.scalar(
      `select coalesce(to_jsonb(recurrence_parent_id),'null'::jsonb) from public.tasks where id=${
        lit(child)
      }`,
    ),
    null,
  );
  await pg.raw(`delete from auth.users where id=${lit(author)}`);
  check(
    "team task unchanged on author removal",
    await pg.scalar(
      `select to_jsonb(t) from public.tasks t where id=${lit(teamTask)}`,
    ),
    beforeTask,
  );
  check(
    "team generation unchanged",
    await pg.scalar(
      `select to_jsonb(g) from taskfold_private.task_generations g where task_id=${
        lit(teamTask)
      }`,
    ),
    beforeGeneration,
  );
  check(
    "team section unchanged",
    await pg.scalar(
      `select to_jsonb(s) from public.sections s where id=${lit(section)}`,
    ),
    beforeSection,
  );
  check(
    "personal/shared owned projects still removed",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.projects where id in(${
        lit(personal)
      },${lit(shared)})`,
    ),
    0,
  );
  check(
    "personal author tasks removed",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.tasks where id in(${
        lit(personalTask)
      },${lit(sharedTask)})`,
    ),
    0,
  );
  check(
    "foreign creator task survives legacy project removal",
    await pg.scalar(
      `select jsonb_build_object('creator',user_id,'project',project_id) from public.tasks where id=${
        lit(foreignTask)
      }`,
    ),
    { creator: survivor, project: null },
  );
  check(
    "deleted team task generation remains",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.task_generations where task_id=${
        lit(deletedTask)
      } and deleted_at is not null`,
    ),
    1,
  );
  check(
    "deleted team task activity remains",
    await pg.scalar(
      `select to_jsonb(count(*)>0) from public.task_activity where task_id=${
        lit(deletedTask)
      }`,
    ),
    true,
  );
  check(
    "personal history removed",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.task_activity where task_id in(${
        lit(personalTask)
      },${lit(sharedTask)})`,
    ),
    0,
  );
  check(
    "identity tombstoned",
    await pg.scalar(
      `select to_jsonb(removed_at is not null) from taskfold_private.content_identities where id=${
        lit(author)
      }`,
    ),
    true,
  );
  check(
    "retained object still exists",
    await pg.scalar(
      `select to_jsonb(count(*)) from storage.objects where id=${lit(object)}`,
    ),
    1,
  );
  check(
    "complete removal tolerates retained team object",
    (await pg.value(
      `to_jsonb(public.taskfold_account_removal_complete(${lit(token)}))`,
      { role: "service_role" },
    )).code,
    null,
  );
  check(
    "removed identity reuse rejected",
    await pg.raw(
      `insert into auth.users(id,email) values(${
        lit(author)
      },'reuse@example.invalid')`,
    ).then(() => null, (e) => e.code),
    "PT409",
  );
  const activityBefore = await pg.scalar(
    `select to_jsonb(count(*)) from public.task_activity where task_id=${
      lit(teamTask)
    }`,
  );
  await pg.raw(
    `update public.tasks set completed=true where id=${lit(teamTask)}`,
  );
  check(
    "team activity continues after creator deletion",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.task_activity where task_id=${
        lit(teamTask)
      }`,
    ),
    activityBefore + 1,
  );
  const taskBeforeTransfer = await pg.scalar(
    `select to_jsonb(t) from public.tasks t where id=${lit(teamTask)}`,
  );
  await pg.raw(
    `insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(survivor)},'member');`,
  );
  const command = (revision, extra = {}) =>
    JSON.stringify({
      team_id: team,
      revision,
      request_id: randomUUID(),
      issued_at: new Date().toISOString(),
      ...extra,
    });
  const teamRPC = (uid, action, body) =>
    auth(uid, `public.taskfold_teams(${lit(action)},${lit(body)}::jsonb)`);
  const offer = await teamRPC(
    owner,
    "transfer_offer",
    command(1, { user_id: survivor }),
  );
  check("custody ownership offer succeeds", offer.code, null);
  const accepted = await teamRPC(
    survivor,
    "transfer_accept",
    command(2, { transfer_id: offer.value.transfer_id }),
  );
  check("custody ownership acceptance succeeds", accepted.code, null);
  check(
    "custody transfer leaves task exact",
    await pg.scalar(
      `select to_jsonb(t) from public.tasks t where id=${lit(teamTask)}`,
    ),
    taskBeforeTransfer,
  );
  await pg.raw(`delete from auth.users where id=${lit(owner)}`);
  check(
    "former team owner removal preserves content",
    await pg.scalar(
      `select to_jsonb(t) from public.tasks t where id=${lit(teamTask)}`,
    ),
    taskBeforeTransfer,
  );
  check(
    "owner Auth deletion still blocked",
    await pg.raw(`delete from auth.users where id=${lit(survivor)}`).then(
      () => null,
      (e) => e.code,
    ),
    "PT409",
  );
  check(
    "team delete blocked while retaining object",
    (await teamRPC(survivor, "delete", command(3))).code,
    "PT409",
  );
  check(
    "blocked team deletion rolls back task",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.tasks where id=${lit(teamTask)}`,
    ),
    1,
  );
  // Simulate authorized Storage API cleanup then delete a team atomically.
  await pg.raw(
    `delete from taskfold_private.team_content_files where object_id=${
      lit(object)
    };`,
  );
  check(
    "binding release alone cannot delete team",
    (await teamRPC(survivor, "delete", command(3))).code,
    "PT409",
  );
  check(
    "pending cleanup still hides file from old uploader",
    (await auth(
      author,
      `(select to_jsonb(count(*)) from storage.objects where id=${
        lit(object)
      })`,
    )).value,
    0,
  );
  check(
    "pending cleanup bucket stays private",
    await pg.raw(
      "update storage.buckets set public=true where id='task-attachments'",
    ).then(() => null, (e) => e.code),
    "PT409",
  );
  await pg.raw(`delete from storage.objects where id=${lit(object)}`);
  check(
    "authorized team delete succeeds",
    (await teamRPC(survivor, "delete", command(3))).code,
    null,
  );
  check(
    "team deletion removes tasks",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.tasks where id in(${
        lit(teamTask)
      },${lit(child)})`,
    ),
    0,
  );
  check(
    "team deletion removes project",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.projects where id=${lit(project)}`,
    ),
    0,
  );
  check(
    "team deletion removes activity",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.task_activity where task_id in(${
        lit(teamTask)
      },${lit(child)},${lit(deletedTask)})`,
    ),
    0,
  );
  check(
    "generation tombstones retained",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.task_generations where task_id=${
        lit(teamTask)
      } and deleted_at is not null`,
    ),
    1,
  );
  // Capture DML errors under an actual authenticated role, not a fake account flag.
  const staleCreate = await pg.raw(
    `begin;set local role authenticated;set local request.jwt.claim.sub=${
      lit(author)
    };insert into public.projects(id,user_id,name) values(${
      lit(randomUUID())
    },${lit(author)},'Must not recreate');commit;`,
  ).then(() => null, (e) => e.code);
  check("stale deleted JWT personal insert rejected", staleCreate, "23503");
  // Both directions of the personal-create/Auth-removal race preserve FK behavior.
  const race = randomUUID();
  await pg.raw(`insert into auth.users(id) values(${lit(race)})`);
  const heldInsert = await pg.hold(
    `insert into public.tasks(id,user_id,title) values(${lit(randomUUID())},${
      lit(race)
    },'In-flight creation')`,
  );
  const deleting = pg.raw(
    `set application_name='custody-delete-waiter';delete from auth.users where id=${
      lit(race)
    }`,
  );
  await pg.waitForLock("custody-delete-waiter", heldInsert.pid);
  await heldInsert.release();
  await deleting;
  check(
    "Auth removal waits then cleans in-flight creation",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.tasks where user_id=${lit(race)}`,
    ),
    0,
  );
  const reverse = randomUUID();
  await pg.raw(`insert into auth.users(id) values(${lit(reverse)})`);
  const heldDelete = await pg.hold(
    `delete from auth.users where id=${lit(reverse)}`,
  );
  const creating = pg.raw(
    `set application_name='custody-create-waiter';insert into public.tasks(id,user_id,title) values(${
      lit(randomUUID())
    },${lit(reverse)},'Must not recreate')`,
  ).then(() => null, (e) => e.code);
  await pg.waitForLock("custody-create-waiter", heldDelete.pid);
  await heldDelete.release();
  check(
    "creation after in-flight Auth removal rejected",
    await creating,
    "23503",
  );
  check(
    "no orphan after reverse race",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.tasks where user_id=${
        lit(reverse)
      }`,
    ),
    0,
  );
  // Real project admission must hold the original creator while Auth removal waits.
  const admittingAuthor = randomUUID(),
    admissionTeam = randomUUID(),
    admissionProject = randomUUID(),
    admissionTask = randomUUID();
  await pg.raw(
    `insert into auth.users(id) values(${
      lit(admittingAuthor)
    });insert into public.projects(id,user_id,name) values(${
      lit(admissionProject)
    },${
      lit(admittingAuthor)
    },'Admission race');insert into public.tasks(id,user_id,project_id,title) values(${
      lit(admissionTask)
    },${lit(admittingAuthor)},${
      lit(admissionProject)
    },'Retain after admission');begin;insert into taskfold_private.teams(id,owner_id,name) values(${
      lit(admissionTeam)
    },${
      lit(survivor)
    },'Admission team');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(admissionTeam)
    },${lit(survivor)},'admin');commit;`,
  );
  const admissionHolder = await pg.hold(
    `insert into taskfold_private.team_content_projects values(${
      lit(admissionProject)
    },${lit(admissionTeam)})`,
  );
  const authorDeleting = pg.raw(
    `set application_name='custody-admission-waiter';delete from auth.users where id=${
      lit(admittingAuthor)
    }`,
  );
  await pg.waitForLock("custody-admission-waiter", admissionHolder.pid);
  await admissionHolder.release();
  await authorDeleting;
  check(
    "admission racing removal preserves project",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.projects where id=${
        lit(admissionProject)
      }`,
    ),
    1,
  );
  check(
    "admission racing removal preserves task",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.tasks where id=${
        lit(admissionTask)
      }`,
    ),
    1,
  );
  // The old project default-owner path remains available to native/legacy clients.
  check(
    "omitted personal owner still defaults to caller",
    (await write(
      survivor,
      `insert into public.projects(id,name) values(${
        lit(randomUUID())
      },'Default owner')`,
    )).code,
    null,
  );
  check(
    "removed profile is not retained",
    await pg.scalar(
      `select to_jsonb(count(*)) from public.profiles where user_id=${
        lit(author)
      }`,
    ),
    0,
  );
  check(
    "no original-author task remains after team deletion",
    await pg.scalar(
      `select coalesce(jsonb_agg(id order by id),'[]') from public.tasks where user_id=${
        lit(author)
      }`,
    ),
    [],
  );
  const newcomer = randomUUID();
  await pg.raw(`insert into auth.users(id) values(${lit(newcomer)})`);
  check(
    "new accounts receive content identity",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.content_identities where id=${
        lit(newcomer)
      }`,
    ),
    1,
  );
  check(
    "team operation authority has no leftovers",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.team_content_operations",
    ),
    0,
  );
  report.advisors = await pg.advisors();
  check(
    "no new custody advisor warnings",
    report.advisors.result.filter((x) =>
      ["WARN", "ERROR"].includes(x.level) &&
      (/team|content|legacy_project_access|has_project_access|is_project_owner/
        .test(
          x.metadata?.name ?? "",
        ))
    ),
    [],
  );
  check(
    "advisors report no errors",
    report.advisors.result.filter((x) => x.level === "ERROR"),
    [],
  );
  check(
    "only known fixture init-plan warnings remain",
    report.advisors.result.filter((x) =>
      x.level === "WARN" && x.name !== "auth_rls_initplan"
    ),
    [],
  );
  report.containerRemoved = await pg.close();
  pg = null;
  report.checkCount = Object.keys(report.checks).length;
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(report, null, 2) + "\n");
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
