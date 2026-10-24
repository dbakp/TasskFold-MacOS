import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import {
  loadTeamProjectSchema,
  teamProjectMigration,
} from "./team-project-schema.mjs";
const report = {
  checks: {},
  deployed: false,
  nativeRolloutEnabled: false,
  taskWritesEnabled: false,
  hostedAcceptanceClaimed: false,
  storageProviderClaimed: false,
  realDataChanged: false,
};
const check = (name, actual, expected) => {
  assert.deepEqual(actual, expected, name);
  report.checks[name] = true;
};
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
const people = Object.fromEntries(
  [
    "owner",
    "admin",
    "creator",
    "member",
    "viewer",
    "observer",
    "guest",
    "outsider",
  ].map((k) => [k, { id: randomUUID(), session: randomUUID() }]),
);
const commands = [];
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  report.postgresVersion = pg.serverVersion;
  await loadTeamProjectSchema(pg.raw);
  const presentationSource = await readFile(new URL("../../supabase/migrations/20261024163752_team_project_presentation.sql",import.meta.url),"utf8");
  await pg.raw(presentationSource);
  report.presentationMigrationSHA256 = createHash("sha256").update(presentationSource).digest("hex");
  report.migrationSHA256 = createHash("sha256").update(
    await readFile(
      new URL(
        "../../supabase/migrations/" + teamProjectMigration,
        import.meta.url,
      ),
    ),
  ).digest("hex");
  for (const [name, u] of Object.entries(people)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${
        lit(name + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${
        lit(u.id)
      });insert into public.profiles(user_id,display_name) values(${
        lit(u.id)
      },${lit("Synthetic " + name)});`,
    );
  }
  const team = randomUUID(),
    foreignTeam = randomUUID(),
    folder = randomUUID(),
    foreignFolder = randomUUID(),
    project = randomUUID(),
    secret = randomUUID();
  await pg.raw(
    `begin;insert into taskfold_private.teams(id,owner_id,name) values(${
      lit(team)
    },${lit(people.owner.id)},'Product team'),(${lit(foreignTeam)},${
      lit(people.outsider.id)
    },'Other team');` + Object.entries(people).filter(([k]) =>
      k !== "outsider"
    ).map(([k, u]) =>
      `insert into taskfold_private.team_members(team_id,user_id,role) values(${
        lit(team)
      },${lit(u.id)},${
        lit(
          k === "owner" || k === "admin"
            ? "admin"
            : k === "guest"
            ? "guest"
            : "member",
        )
      });`
    ).join("") +
      `insert into taskfold_private.team_members(team_id,user_id,role) values(${
        lit(foreignTeam)
      },${
        lit(people.outsider.id)
      },'admin');insert into taskfold_private.team_folders(id,team_id,name) values(${
        lit(folder)
      },${lit(team)},'Design'),(${lit(foreignFolder)},${
        lit(foreignTeam)
      },'Other');commit;`,
  );
  for (const [p, visibility] of [[project, "team"], [secret, "private"]]) {
    await pg.raw(
      `insert into public.projects(id,user_id,name) values(${lit(p)},${
        lit(people.creator.id)
      },${
        lit(visibility + " project")
      });insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
        lit(p)
      },${lit(team)},${
        lit(visibility)
      });insert into taskfold_private.team_project_grants values(${lit(p)},${
        lit(team)
      },${lit(people.creator.id)},'manager')`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(people.viewer.id)},'viewer');`,
  );
  const task = randomUUID(),
    hiddenTask = randomUUID(),
    section = randomUUID(),
    object = randomUUID(),
    comment = randomUUID();
  for (const [id, p] of [[task, project], [hiddenTask, secret]]) {
    await pg.raw(
      `insert into public.tasks(id,user_id,project_id,title) values(${
        lit(id)
      },${lit(people.creator.id)},${lit(p)},'Read permission proof')`,
    );
  }
  await pg.raw(
    `insert into public.sections(id,user_id,project_id,name) values(${
      lit(section)
    },${lit(people.creator.id)},${
      lit(project)
    },'Design');insert into storage.objects(id,bucket_id,name,owner,owner_id) values(${
      lit(object)
    },'task-attachments',${lit(people.creator.id + "/team-proof")},${
      lit(people.creator.id)
    },${
      lit(people.creator.id)
    });insert into taskfold_private.team_content_files values(${lit(object)},${
      lit(project)
    });insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body) select ${
      lit(comment)
    },id,task_generation,project_id,user_id,'Read-only shared comment' from public.tasks where id=${
      lit(task)
    };`,
  );
  const run = (who, expression, opts = {}) => {
    const u = people[who], role = opts.role ?? "authenticated";
    return pg.scalar(
      `begin;set application_name=${
        lit(opts.app ?? "team-project-" + randomUUID().slice(0, 8))
      };create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated,anon,service_role;set local role ${role};set local request.jwt.claim.sub=${
        lit(u.id)
      };set local request.jwt.claims=${
        lit(
          JSON.stringify({
            sub: u.id,
            session_id: opts.session === undefined ? u.session : opts.session,
            ...opts.claims,
          }),
        )
      };do $r$begin begin insert into result values((${expression}),null,null);exception when others then insert into result values(null,sqlstate,left(sqlerrm,150));end;end$r$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`,
    );
  };
  const rpc = async (who, action, body, opts) => {
    const result = await run(who,`public.taskfold_team_projects(${lit(action)},${json(body)})`,opts);
    if(result.code===null && ["create","settings","set_access","reset_access"].includes(action)) commands.push({account:people[who].id,action,body,result:result.value});
    return result;
  };
  const request = async (p = project, extra = {}) => ({
    team_id: team,
    project_id: p,
    request_id: randomUUID(),
    issued_at: new Date().toISOString(),
    team_revision: await pg.scalar(
      `select to_jsonb(revision) from taskfold_private.teams where id=${
        lit(team)
      }`,
    ),
    revision: await pg.scalar(
      `select to_jsonb(revision) from taskfold_private.team_content_projects where project_id=${
        lit(p)
      }`,
    ),
    ...extra,
  });
  const mutate = async (who, action, extra = {}, p = project) =>
    rpc(who, action, await request(p, extra));
  const success = async (name, who, action, body) => {
    const r = await rpc(who, action, body);
    check(name, r.code, null);
    return r.value;
  };
  const visible = async (who, table, id) =>
    run(
      who,
      `(select to_jsonb(count(*)) from public.${table} where id=${lit(id)})`,
    );
  check(
    "feature defaults closed",
    (await visible("owner", "projects", project)).value,
    0,
  );
  check(
    "catalog defaults closed",
    (await rpc("owner", "list", { team_id: team })).code,
    "PT503",
  );
  await pg.raw(
    "update taskfold_private.team_project_config set native_reads_enabled=true;update taskfold_private.team_config set enabled=true",
  );
  for (
    const [who, expected] of [
      ["owner", 1],
      ["admin", 1],
      ["creator", 1],
      ["member", 1],
      ["viewer", 1],
      ["observer", 1],
      ["guest", 0],
      ["outsider", 0],
    ]
  ) {
    check(
      who + " team project view",
      (await visible(who, "projects", project)).value,
      expected,
    );
    check(
      who + " team task view",
      (await visible(who, "tasks", task)).value,
      expected,
    );
    check(
      who + " section view",
      (await visible(who, "sections", section)).value,
      expected,
    );
    check(
      who + " comment view",
      (await visible(who, "task_comments", comment)).value,
      expected,
    );
    check(
      who + " file view",
      (await run(
        who,
        `(select to_jsonb(count(*)) from storage.objects where id=${
          lit(object)
        })`,
      )).value,
      expected,
    );
  }
  for (
    const [who, expected] of [
      ["owner", 1],
      ["admin", 1],
      ["creator", 1],
      ["member", 0],
      ["viewer", 0],
      ["observer", 0],
      ["guest", 0],
    ]
  ) {
    check(
      who + " private project view",
      (await visible(who, "projects", secret)).value,
      expected,
    );
  }
  const member = await success("member catalog", "member", "list", {
    team_id: team,
  });
  check("member only public project", member.projects.map((x) => x.id), [
    project,
  ]);
  check("member role is editor", member.projects[0].role, "editor");
  check(
    "editor task edits still disabled",
    member.projects[0].can_edit_tasks,
    false,
  );
  const nativeDetail = await success(
    "native detail contract",
    "member",
    "get",
    { team_id: team, project_id: project },
  );
  const nativeFixture = {
    account: people.member.id,
    team,
    project,
    page: member,
    detail: nativeDetail,
  };
  nativeFixture.management = await success("native manager presentation", "owner", "get", {team_id:team, project_id:project});
  nativeFixture.managerAccount = people.owner.id;
  check("native project name",nativeFixture.management.name,"team project");
  check("native bounded accepted recipients",nativeFixture.management.eligible_members.length,7);
  check("native no email or outsider directory",nativeFixture.management.eligible_members.every(x=>x.user_id!==people.outsider.id && !Object.hasOwn(x,"verified_email") && !Object.hasOwn(x,"email")),true);
  check("native member lacks recipient directory",nativeDetail.eligible_members,undefined);
  await pg.raw(`update public.profiles set display_name=repeat('x',101) where user_id=${lit(people.guest.id)}`);
  const sanitized = await success("native bounded profile", "creator", "get", {team_id:team,project_id:project});
  check("native oversized name withheld",sanitized.eligible_members.find(x=>x.user_id===people.guest.id).display_name,null);
  await pg.raw(`update public.profiles set display_name='Synthetic guest' where user_id=${lit(people.guest.id)}`);
  const viewer = await success("viewer capabilities", "viewer", "get", {
    team_id: team,
    project_id: project,
  });
  check("viewer explicit role", viewer.role, "viewer");
  check("viewer no grants directory", viewer.grants, undefined);
  check(
    "viewer cannot manage",
    (await mutate("viewer", "settings", {
      visibility: "private",
      folder_id: null,
    })).code,
    "42501",
  );
  check(
    "guest has no team-wide projects",
    (await success("guest catalog", "guest", "list", { team_id: team }))
      .projects,
    [],
  );
  check(
    "outsider catalog unavailable",
    (await rpc("outsider", "list", { team_id: team })).code,
    "PT404",
  );
  check(
    "foreign session denied",
    (await rpc("member", "list", { team_id: team }, {
      session: people.owner.session,
    })).code,
    "28000",
  );
  check(
    "foreign session RLS empty",
    (await run(
      "member",
      `(select to_jsonb(count(*)) from public.tasks where id=${lit(task)})`,
      { session: people.owner.session },
    )).value,
    0,
  );
  check(
    "malformed session RLS empty",
    (await run(
      "member",
      `(select to_jsonb(count(*)) from public.tasks where id=${lit(task)})`,
      { session: "not-a-session" },
    )).value,
    0,
  );
  check(
    "no session RLS empty",
    (await run(
      "member",
      `(select to_jsonb(count(*)) from public.tasks where id=${lit(task)})`,
      { session: null },
    )).value,
    0,
  );
  check(
    "editable metadata cannot grant private access",
    (await run(
      "member",
      `(select to_jsonb(count(*)) from public.projects where id=${
        lit(secret)
      })`,
      { claims: { user_metadata: { role: "owner", project_id: secret } } },
    )).value,
    0,
  );
  check(
    "anon cannot call management",
    (await rpc("owner", "get", { team_id: team, project_id: project }, {
      role: "anon",
    })).code,
    "42501",
  );
  check(
    "service cannot impersonate native management",
    (await rpc("owner", "get", { team_id: team, project_id: project }, {
      role: "service_role",
    })).code,
    "42501",
  );
  check(
    "grant guest viewer",
    (await mutate("creator", "set_access", {
      user_id: people.guest.id,
      role: "viewer",
    })).code,
    null,
  );
  check(
    "guest sees exactly invited project",
    (await success("guest scoped catalog", "guest", "list", { team_id: team }))
      .projects.map((x) => x.id),
    [project],
  );
  check(
    "guest now sees shared task",
    (await visible("guest", "tasks", task)).value,
    1,
  );
  check(
    "guest remains outside private project",
    (await visible("guest", "tasks", hiddenTask)).value,
    0,
  );
  check(
    "guest cannot become manager",
    (await mutate("owner", "set_access", {
      user_id: people.guest.id,
      role: "manager",
    })).code,
    "22023",
  );
  check(
    "cannot grant across teams",
    (await mutate("owner", "set_access", {
      user_id: people.outsider.id,
      role: "viewer",
    })).code,
    "PT404",
  );
  check(
    "admin cannot be falsely downgraded",
    (await mutate("creator", "set_access", {
      user_id: people.admin.id,
      role: "viewer",
    })).code,
    "42501",
  );
  check(
    "private helper not directly executable",
    (await run(
      "member",
      `to_jsonb(taskfold_private.team_project_role(${lit(people.member.id)},${
        lit(secret)
      }))`,
    )).code,
    "42501",
  );
  check(
    "grants table not readable",
    (await run(
      "member",
      "(select to_jsonb(count(*)) from taskfold_private.team_project_grants)",
    )).code,
    "42501",
  );
  const grantRequest = await request(project, {
    user_id: people.member.id,
    role: "viewer",
  });
  const grant = await success(
    "downgrade explicit member",
    "creator",
    "set_access",
    grantRequest,
  );
  check(
    "exact grant retry",
    await success("retry same grant", "creator", "set_access", grantRequest),
    grant,
  );
  check(
    "changed retry rejected",
    (await rpc("creator", "set_access", { ...grantRequest, role: "manager" }))
      .code,
    "PT409",
  );
  check(
    "member downgraded to viewer",
    (await success("updated member capabilities", "member", "get", {
      team_id: team,
      project_id: project,
    })).role,
    "viewer",
  );
  check(
    "stale project review rejected",
    (await rpc("creator", "settings", {
      ...await request(),
      revision: 1,
      visibility: "private",
      folder_id: null,
    })).code,
    "PT409",
  );
  check(
    "foreign folder rejected",
    (await mutate("creator", "settings", {
      visibility: "team",
      folder_id: foreignFolder,
    })).code,
    "22023",
  );
  check(
    "private visibility and folder saved",
    (await mutate("creator", "settings", {
      visibility: "private",
      folder_id: folder,
    })).code,
    null,
  );
  check(
    "explicit viewer survives visibility change",
    (await visible("member", "tasks", task)).value,
    1,
  );
  check(
    "inherited member loses private project",
    (await visible("observer", "tasks", task)).value,
    0,
  );
  check(
    "reset private guest access",
    (await mutate("creator", "reset_access", { user_id: people.guest.id }))
      .code,
    null,
  );
  check(
    "reset guest access enforced",
    (await visible("guest", "tasks", task)).value,
    0,
  );
  // Direct writes/privileged comment writers remain closed even for managers.
  check(
    "native team patch still disabled",
    (await run(
      "creator",
      `to_jsonb(public.taskfold_patch_task(${
        lit(task)
      },'{"title":"Read permission proof"}'::jsonb,'{"title":"Must not save"}'::jsonb))`,
    )).code,
    "P0001",
  );
  const generation = await pg.scalar(
    `select to_jsonb(task_generation) from public.tasks where id=${lit(task)}`,
  );
  check(
    "viewer cannot write through comment RPC",
    (await run(
      "member",
      `public.taskfold_write_comment(${lit(randomUUID())},${
        lit(randomUUID())
      },${lit(task)},${lit(generation)},${
        lit(project)
      },0,'Must not comment','{}'::uuid[],false)`,
    )).code,
    "PT503",
  );
  check(
    "service project path remains disabled",
    (await pg.value(
      `to_jsonb(taskfold_private.automation_lock_project(${
        lit(people.creator.id)
      },${lit(project)}))`,
      { role: "postgres" },
    )).code,
    "PT503",
  );
  // Current authority is re-read after an actual competing management commit.
  const held = await pg.hold(
    `select 1 from taskfold_private.teams where id=${lit(team)} for update`,
  );
  const waiting = rpc(
    "creator",
    "settings",
    await request(project, { visibility: "private", folder_id: folder }),
    { app: "team-project-authority-waiter" },
  );
  await pg.waitForLock("team-project-authority-waiter", held.pid);
  await held.release(
    "commit",
    `delete from taskfold_private.team_project_grants where project_id=${
      lit(project)
    } and user_id=${
      lit(people.creator.id)
    };update taskfold_private.team_content_projects set revision=revision+1 where project_id=${
      lit(project)
    }`,
  );
  check("queued manager loses authority", (await waiting).code, "42501");
  await pg.raw(
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${
      lit(people.creator.id)
    },'manager');update taskfold_private.team_content_projects set revision=revision+1 where project_id=${
      lit(project)
    }`,
  );
  const beforeReview = await request(project, {
    visibility: "private",
    folder_id: folder,
  });
  const simultaneous = await Promise.all([
    rpc("owner", "settings", beforeReview),
    rpc("admin", "settings", {
      ...beforeReview,
      request_id: randomUUID(),
      folder_id: null,
    }),
  ]);
  check(
    "one reviewed management mutation wins",
    simultaneous.map((x) => x.code).sort(),
    [null, "PT409"].sort(),
  );
  check(
    "one management revision advances",
    await pg.scalar(
      `select to_jsonb(revision) from taskfold_private.team_content_projects where project_id=${
        lit(project)
      }`,
    ),
    beforeReview.revision + 1,
  );
  const expiryHolder = await pg.hold(
    `select 1 from taskfold_private.teams where id=${lit(team)} for update`,
  );
  await pg.raw(
    `update auth.sessions set not_after=clock_timestamp()+interval '0.4 second' where id=${
      lit(people.creator.session)
    }`,
  );
  const expiring = rpc(
    "creator",
    "settings",
    await request(project, { visibility: "private", folder_id: folder }),
    { app: "team-project-session-waiter" },
  );
  await pg.waitForLock("team-project-session-waiter", expiryHolder.pid);
  await pg.raw("select pg_sleep(0.5)");
  await expiryHolder.release();
  check(
    "session expiring while queued rejected",
    (await expiring).code,
    "28000",
  );
  await pg.raw(
    `update auth.sessions set not_after=null where id=${
      lit(people.creator.session)
    }`,
  );
  // Manager grants are not revived by a guest demotion/return to membership.
  check(
    "appoint project manager",
    (await mutate("owner", "set_access", {
      user_id: people.observer.id,
      role: "manager",
    })).code,
    null,
  );
  await pg.raw(
    `update taskfold_private.team_members set role='guest' where team_id=${
      lit(team)
    } and user_id=${lit(people.observer.id)}`,
  );
  check(
    "guest demotion removes manager access",
    (await visible("observer", "projects", project)).value,
    0,
  );
  await pg.raw(
    `update taskfold_private.team_members set role='member' where team_id=${
      lit(team)
    } and user_id=${lit(people.observer.id)}`,
  );
  check(
    "membership return cannot revive private manager access",
    (await visible("observer", "projects", project)).value,
    0,
  );
  await pg.raw("update taskfold_private.team_config set enabled=false");
  check(
    "paused setup cannot widen project access",
    (await mutate("creator", "set_access", {
      user_id: people.guest.id,
      role: "editor",
    })).code,
    "PT503",
  );
  check(
    "paused private reset can remove viewer access",
    (await mutate("creator", "reset_access", { user_id: people.member.id }))
      .code,
    null,
  );
  check(
    "paused reset changes actual reads",
    (await visible("member", "tasks", task)).value,
    0,
  );
  await pg.raw("update taskfold_private.team_config set enabled=true");
  check(
    "restore explicit viewer after recovery",
    (await mutate("creator", "set_access", {
      user_id: people.member.id,
      role: "viewer",
    })).code,
    null,
  );
  // Private project grant revisions serialize peer clients; body validation is strict.
  check(
    "fractional revision rejected",
    (await rpc("creator", "settings", {
      ...await request(),
      revision: 1.2,
      visibility: "private",
      folder_id: null,
    })).code,
    "22023",
  );
  check(
    "unknown settings field rejected",
    (await rpc("creator", "settings", {
      ...await request(),
      visibility: "private",
      folder_id: null,
      owner_id: people.creator.id,
    })).code,
    "22023",
  );
  check(
    "expired request rejected",
    (await rpc("creator", "settings", {
      ...await request(),
      issued_at: "2000-01-01T00:00:00Z",
      visibility: "private",
      folder_id: null,
    })).code,
    "PT409",
  );
  const firstPage = await success("first catalog page", "owner", "list", {
    team_id: team,
    limit: 1,
  });
  const secondPage = await success("second catalog page", "owner", "list", {
    team_id: team,
    limit: 1,
    after: firstPage.next_cursor,
  });
  check(
    "paged catalog visits each project once",
    [...firstPage.projects, ...secondPage.projects].map((x) => x.id).sort(),
    [project, secret].sort(),
  );
  check("last page has no cursor", secondPage.next_cursor, null);
  // Team-only historical collaborator rows never grant contact email access.
  await pg.raw(
    `alter table public.project_collaborators disable trigger taskfold_prepare_invitation;insert into public.project_collaborators(id,project_id,user_id,invited_by,status) values(${
      lit(randomUUID())
    },${lit(project)},${lit(people.member.id)},${
      lit(people.creator.id)
    },'accepted');alter table public.project_collaborators enable trigger taskfold_prepare_invitation;`,
  );
  check(
    "team relationship does not expose contact email",
    (await run(
      "creator",
      `to_jsonb(public.get_user_email_by_id(${lit(people.member.id)}))`,
    )).value,
    null,
  );
  const personal = randomUUID();
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${lit(personal)},${
      lit(people.creator.id)
    },'Personal sharing');alter table public.project_collaborators disable trigger taskfold_prepare_invitation;insert into public.project_collaborators(id,project_id,user_id,invited_by,status) values(${
      lit(randomUUID())
    },${lit(personal)},${lit(people.member.id)},${
      lit(people.creator.id)
    },'accepted');alter table public.project_collaborators enable trigger taskfold_prepare_invitation;`,
  );
  check(
    "personal sharing contact contract preserved",
    (await run(
      "creator",
      `to_jsonb(public.get_user_email_by_id(${lit(people.member.id)}))`,
    )).value,
    "member@example.invalid",
  );
  const personalTask = randomUUID(),
    readKey = randomUUID(),
    keyHash = "c".repeat(64);
  await pg.raw(
    `insert into public.tasks(id,user_id,project_id,title) values(${
      lit(personalTask)
    },${lit(people.creator.id)},${
      lit(personal)
    },'Personal API proof');insert into taskfold_private.automation_keys(id,user_id,name,token_hash,scopes,ttl_days,expires_at) values(${
      lit(readKey)
    },${lit(people.creator.id)},'Synthetic role read',${
      lit(keyHash)
    },array['tasks:read'],30,clock_timestamp()+interval '1 day')`,
  );
  const servicePage = await pg.value(
    `public.taskfold_automation_read(${lit(readKey)},${
      lit(keyHash)
    },'list','{}'::jsonb)`,
    { role: "service_role" },
  );
  check("actual service API personal page still works", servicePage.code, null);
  check(
    "actual service API page cannot inherit native team access",
    servicePage.value.tasks.map((t) => t.id),
    [personalTask],
  );
  const direct = (statement) =>
    pg.raw(
      `begin;set local role authenticated;set local request.jwt.claim.sub=${
        lit(people.creator.id)
      };${statement};commit;`,
    ).then(() => null, (e) => e.code);
  check(
    "legacy personal hierarchy cannot attach to team",
    await direct(
      `update public.projects set parent_id=${lit(project)} where id=${
        lit(personal)
      }`,
    ),
    "22023",
  );
  check(
    "legacy personal recurrence cannot attach to team",
    await direct(
      `insert into public.tasks(id,user_id,project_id,title,recurrence_parent_id) values(${
        lit(randomUUID())
      },${lit(people.creator.id)},${lit(personal)},'Must stay personal',${
        lit(task)
      })`,
    ),
    "22023",
  );
  const personalSection = randomUUID();
  await pg.raw(
    `insert into public.sections(id,user_id,project_id,name) values(${
      lit(personalSection)
    },${lit(people.creator.id)},${lit(personal)},'Personal section')`,
  );
  check(
    "legacy section cannot cross workspace",
    await direct(
      `update public.sections set project_id=${lit(project)} where id=${
        lit(personalSection)
      }`,
    ),
    "22023",
  );
  const personalSibling = randomUUID();
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${
      lit(personalSibling)
    },${lit(people.creator.id)},'Personal sibling')`,
  );
  check(
    "personal hierarchy remains supported",
    await direct(
      `update public.projects set parent_id=${lit(personalSibling)} where id=${
        lit(personal)
      }`,
    ),
    null,
  );
  // Current roster excludes former project creator after team membership removal.
  check(
    "current profile roster only readable people",
    (await run(
      "creator",
      `(select jsonb_agg(user_id order by user_id) from public.taskfold_project_members(${
        lit(project)
      }))`,
    )).value.sort(),
    [
      people.owner.id,
      people.admin.id,
      people.creator.id,
      people.member.id,
      people.viewer.id,
    ].sort(),
  );
  await pg.raw(
    `delete from taskfold_private.team_members where team_id=${
      lit(team)
    } and user_id=${lit(people.creator.id)}`,
  );
  check(
    "creator shortcut cannot bypass membership loss",
    (await visible("creator", "tasks", task)).value,
    0,
  );
  check(
    "former uploader cannot read retained team file",
    (await run(
      "creator",
      `(select to_jsonb(count(*)) from storage.objects where id=${
        lit(object)
      })`,
    )).value,
    0,
  );
  check(
    "former creator cannot read retained team activity",
    (await run(
      "creator",
      `(select to_jsonb(count(*)) from public.task_activity where task_id=${
        lit(task)
      })`,
    )).value,
    0,
  );
  check(
    "former creator excluded from profile roster",
    (await run(
      "owner",
      `(select jsonb_agg(user_id order by user_id) from public.taskfold_project_members(${
        lit(project)
      }))`,
    )).value.includes(people.creator.id),
    false,
  );
  check(
    "revoked manager cannot replay receipt",
    (await rpc("creator", "set_access", grantRequest)).code,
    "42501",
  );
  const createBody = {
    team_id: team,
    project_id: randomUUID(),
    request_id: randomUUID(),
    issued_at: new Date().toISOString(),
    team_revision: 1,
    name: "Launch plan",
    visibility: "private",
    folder_id: folder,
  };
  const created = await success(
    "native reviewed project creation",
    "member",
    "create",
    createBody,
  );
  check(
    "project create retry",
    await success("project create retry", "member", "create", createBody),
    created,
  );
  check(
    "creator gets manager role",
    (await success("created capabilities", "member", "get", {
      team_id: team,
      project_id: createBody.project_id,
    })).role,
    "manager",
  );
  check(
    "new private project excluded for another member",
    (await visible("viewer", "projects", createBody.project_id)).value,
    0,
  );
  check(
    "guest cannot create",
    (await rpc("guest", "create", {
      ...createBody,
      project_id: randomUUID(),
      request_id: randomUUID(),
    })).code,
    "42501",
  );
  check(
    "changed create retry conflicts",
    (await rpc("member", "create", { ...createBody, name: "Changed" })).code,
    "PT409",
  );
  await pg.raw(
    `delete from public.projects where id=${lit(createBody.project_id)}`,
  );
  check(
    "deleted project identity cannot resurrect",
    (await rpc("member", "create", { ...createBody, request_id: randomUUID() }))
      .code,
    "PT409",
  );
  // A genuine session expiry also empties task/file/comment reads.
  await pg.raw(
    `update auth.sessions set not_after=now()-interval '1 second' where id=${
      lit(people.member.session)
    }`,
  );
  check(
    "expired session hides task",
    (await visible("member", "tasks", task)).value,
    0,
  );
  check(
    "expired session hides file",
    (await run(
      "member",
      `(select to_jsonb(count(*)) from storage.objects where id=${
        lit(object)
      })`,
    )).value,
    0,
  );
  check(
    "expired session hides comment",
    (await visible("member", "task_comments", comment)).value,
    0,
  );
  await pg.raw(
    `update auth.sessions set not_after=null where id=${
      lit(people.member.session)
    }`,
  );
  const moving = randomUUID();
  await pg.raw(
    `insert into public.tasks(id,user_id,project_id,title) values(${
      lit(moving)
    },${lit(people.member.id)},${
      lit(project)
    },'History scope proof');update public.tasks set project_id=${
      lit(secret)
    } where id=${lit(moving)}`,
  );
  check(
    "custody follows same-team project move",
    await pg.scalar(
      `select to_jsonb(project_id) from taskfold_private.team_content_tasks where task_id=${
        lit(moving)
      }`,
    ),
    secret,
  );
  check(
    "creator cannot read history in unavailable destination",
    (await run(
      "member",
      `(select to_jsonb(count(*)) from public.task_activity where task_id=${
        lit(moving)
      })`,
    )).value,
    0,
  );
  check(
    "team admin can read authorized move history",
    (await run(
      "owner",
      `(select to_jsonb(count(*)>=2) from public.task_activity where task_id=${
        lit(moving)
      })`,
    )).value,
    true,
  );
  check(
    "grant destination viewer",
    (await mutate("owner", "set_access", {
      user_id: people.member.id,
      role: "viewer",
    }, secret)).code,
    null,
  );
  check(
    "reset old private-project reader",
    (await mutate("owner", "reset_access", { user_id: people.member.id })).code,
    null,
  );
  await pg.raw(
    `update public.tasks set completed=true where id=${lit(moving)}`,
  );
  check(
    "destination viewer sees only destination-local activity",
    (await run(
      "member",
      `(select to_jsonb(count(*)) from public.task_activity where task_id=${
        lit(moving)
      })`,
    )).value,
    1,
  );
  await pg.raw(`delete from public.tasks where id=${lit(moving)}`);
  check(
    "deleted history retains last-project scope",
    (await run(
      "member",
      `(select to_jsonb(count(*)) from public.task_activity where task_id=${
        lit(moving)
      })`,
    )).value,
    2,
  );
  report.advisors = await pg.advisors();
  check(
    "no new project security/performance warnings",
    report.advisors.result.filter((x) =>
      ["WARN", "ERROR"].includes(x.level) && x.name !== "auth_rls_initplan"
    ),
    [],
  );
  report.containerRemoved = await pg.close();
  pg = null;
  report.checkCount = Object.keys(report.checks).length;
  if (process.argv[3]) {
    await writeFile(
      process.argv[3],
      JSON.stringify(nativeFixture, null, 2) + "\n",
    );
  }
  if (process.argv[4]) await writeFile(process.argv[4],JSON.stringify(commands,null,2)+"\n");
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
