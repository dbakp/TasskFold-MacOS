// Disposable PostgreSQL only. Run the real migration under native JWT/SQL roles.
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
const migration = "supabase/migrations/20261024021629_team_organization.sql";
const output = process.argv[2];
const repoFile = (path) => new URL("../../" + path, import.meta.url);
const report = {
  checks: {},
  deployed: false,
  realDataChanged: false,
  projectAuthorityIntegrated: false,
  nativeUIEnabled: false,
};
const check = (name, actual, expected) => {
  assert.deepEqual(actual, expected, name);
  report.checks[name] = true;
};
const json = (v) => lit(JSON.stringify(v)) + "::jsonb";
const users = Object.fromEntries(
  ["owner", "admin", "member", "guest", "outsider", "other"].map(
    (k) => [k, {
      id: randomUUID(),
      session: randomUUID(),
      email: k + "@example.invalid",
    }],
  ),
);
const nativeCommands = [];
const nativeCommandActions = new Set(["create", "rename", "archive", "unarchive", "folder_create", "folder_rename", "folder_remove"]);
const captureCommand = (who, action, body, result) => {
  if (nativeCommandActions.has(action)) nativeCommands.push({account: users[who].id, action, body, result});
};
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  report.postgresVersion = pg.serverVersion;
  await pg.raw(
    await readFile(repoFile("Scripts/Database/account-removal-bootstrap.sql"), "utf8"),
  );
  await pg.raw(
    "create schema extensions;create extension pgcrypto with schema extensions;alter table auth.users add column email_confirmed_at timestamptz;create function auth.jwt() returns jsonb language sql stable set search_path='' as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;",
  );
  await pg.raw(
    await readFile(
      repoFile("supabase/migrations/20261022193804_account_removal_service.sql"),
      "utf8",
    ),
  );
  const existingBoundary = () =>
    pg.scalar(`select jsonb_build_object(
    'functions',(select jsonb_agg(pg_get_functiondef(p.oid) order by p.proname,pg_get_function_identity_arguments(p.oid)) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname<>'taskfold_teams'),
    'policies',(select jsonb_agg(to_jsonb(p) order by schemaname,tablename,policyname) from pg_policies p where schemaname in('public','storage')),
    'project_task_columns',(select jsonb_agg(to_jsonb(c) order by table_name,ordinal_position) from information_schema.columns c where table_schema='public' and table_name in('projects','tasks')),
    'grants',(select jsonb_agg(jsonb_build_object('schema',n.nspname,'table',c.relname,'acl',c.relacl,'rls',c.relrowsecurity) order by n.nspname,c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where (n.nspname='public' and c.relname in('tasks','projects','project_collaborators')) or (n.nspname='storage' and c.relname='objects')))`);
  const beforeBoundary = await existingBoundary();
  const source = await readFile(repoFile(migration), "utf8");
  report.migrationSHA256 = createHash("sha256").update(source).digest("hex");
  await pg.raw(source);
  check(
    "existing project/task/storage boundary unchanged in fixture",
    await existingBoundary(),
    beforeBoundary,
  );
  for (const u of Object.values(users)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${lit(u.email)},now());insert into auth.sessions(id,user_id) values(${
        lit(u.session)
      },${lit(u.id)});insert into public.profiles values(${lit(u.id)});`,
    );
  }
  const run = (
    u,
    expression,
    {
      role = "authenticated",
      app = "team-" + randomUUID().slice(0, 8),
      session = u.session,
      claims = {},
    } = {},
  ) =>
    pg.scalar(
      `begin;set application_name=${
        lit(app)
      };create temp table team_result(value jsonb,code text,reason text) on commit drop;grant all on team_result to authenticated,anon,service_role;set local role ${role};set local request.jwt.claim.sub=${
        lit(u.id)
      };set local request.jwt.claims=${
        lit(JSON.stringify({ sub: u.id, session_id: session, role, ...claims }))
      };do $test$begin begin insert into team_result values((${expression}),null,null);exception when others then insert into team_result values(null,sqlstate,left(sqlerrm,160));end;end$test$;select jsonb_build_object('value',value,'code',code,'reason',reason) from team_result;commit;`,
    );
  const rpc = (who, action, body, opts) =>
    run(
      users[who],
      `public.taskfold_teams(${lit(action)},${json(body)})`,
      opts,
    );
  const ok = async (name, who, action, body, opts) => {
    const r = await rpc(who, action, body, opts);
    check(name + " succeeds", r.code, null);
    captureCommand(who, action, body, r.value);
    return r.value;
  };
  const deny = async (name, who, action, body, code, opts) =>
    check(name, (await rpc(who, action, body, opts)).code, code);
  const team = randomUUID();
  const request = (revision, extra = {}, team_id = team) => ({
    team_id,
    request_id: randomUUID(),
    issued_at: new Date().toISOString(),
    ...(revision ? { revision } : {}),
    ...extra,
  });
  const revision = async (t = team) =>
    pg.scalar(
      `select to_jsonb(revision) from taskfold_private.teams where id=${
        lit(t)
      }`,
    );
  const mutate = async (who, action, extra = {}, t = team) =>
    rpc(who, action, request(await revision(t), extra, t));
  const change = async (name, who, action, extra = {}, t = team) => {
    const body = request(await revision(t), extra, t);
    const r = await rpc(who, action, body);
    check(name, r.code, null);
    captureCommand(who, action, body, r.value);
    return r.value;
  };
  const create = request(null, { name: "Design studio" });
  await deny("feature disabled", "owner", "create", create, "PT503");
  check(
    "paused list",
    (await ok("list paused", "owner", "list", {})).enabled,
    false,
  );
  await pg.raw("update taskfold_private.team_config set enabled=true");
  const created = await ok("create team", "owner", "create", create);
  check("initial revision", created.revision, 1);
  check(
    "create retry",
    await ok("retry create", "owner", "create", create),
    created,
  );
  await deny("changed create replay", "owner", "create", {
    ...create,
    name: "Other",
  }, "PT409");
  await deny(
    "unknown field",
    "owner",
    "get",
    { team_id: team, role: "owner" },
    "22023",
  );
  await deny("unknown action", "owner", "elevate", {}, "22023");
  await deny(
    "outsider cannot read",
    "outsider",
    "get",
    { team_id: team },
    "PT404",
  );
  await deny("anon cannot call", "owner", "get", { team_id: team }, "42501", {
    role: "anon",
  });
  await deny(
    "service cannot impersonate native caller",
    "owner",
    "get",
    { team_id: team },
    "42501",
    { role: "service_role" },
  );
  await deny("missing session", "owner", "get", { team_id: team }, "28000", {
    session: null,
  });
  await deny("wrong session", "owner", "get", { team_id: team }, "28000", {
    session: users.other.session,
  });
  check(
    "private table reads denied",
    (await run(
      users.owner,
      "(select to_jsonb(count(*)) from taskfold_private.team_members)",
    )).code,
    "42501",
  );
  check(
    "helper execution denied",
    (await run(
      users.owner,
      "to_jsonb(taskfold_private.team_role(" + lit(team) + "," +
        lit(users.owner.id) + "))",
    )).code,
    "42501",
  );
  check(
    "all team tables RLS enabled",
    await pg.scalar(
      "select to_jsonb(bool_and(relrowsecurity)) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='taskfold_private' and (c.relname like 'team_%' or c.relname='teams') and c.relkind='r'",
    ),
    true,
  );
  for (const who of ["admin", "member", "guest"]) {
    const invitation = await change("invite " + who, "owner", "invite", {
      email: users[who].email.toUpperCase(),
      role: who,
    });
    check(
      "only own pending " + who,
      (await ok("discover " + who, who, "invitations", {})).invitations.length,
      1,
    );
    await deny(
      "wrong person cannot accept " + who,
      "outsider",
      "accept_invitation",
      request(await revision(), { invitation_id: invitation.invitation_id }),
      "PT404",
    );
    const accept = request(await revision(), {
      invitation_id: invitation.invitation_id,
    });
    const accepted = await ok(
      "accept " + who,
      who,
      "accept_invitation",
      accept,
    );
    check(
      "accept retry " + who,
      await ok("retry accept " + who, who, "accept_invitation", accept),
      accepted,
    );
  }
  check(
    "owner computed",
    (await ok("owner detail", "owner", "get", { team_id: team })).role,
    "owner",
  );
  const guest = await ok("guest detail", "guest", "get", { team_id: team });
  check("guest has no directory or folders", [
    guest.members,
    guest.invitations,
    guest.folders,
  ], [undefined, undefined, undefined]);
  const member = await ok("member detail", "member", "get", { team_id: team });
  check("member no directory", member.members, undefined);
  const folder = await change("create folder", "admin", "folder_create", {
    name: "Product",
  });
  check(
    "member folder metadata",
    (await ok("member folders", "member", "get", { team_id: team })).folders[0]
      .name,
    "Product",
  );
  if (process.argv[3]) {
    const fixture = {team};
    for (const role of ["owner", "admin", "member", "guest"]) {
      fixture[role] = {
        account: users[role].id,
        list: await ok("native " + role + " list", role, "list", {}),
        invitations: await ok("native " + role + " invitations", role, "invitations", {}),
        detail: await ok("native " + role + " detail", role, "get", {team_id: team}),
      };
    }
    await writeFile(process.argv[3], JSON.stringify(fixture, null, 2) + "\n");
  }
  for (
    const [name, who, action, extra, code] of [
      ["guest cannot create folder", "guest", "folder_create", {
        name: "Secret",
      }, "42501"],
      ["member cannot rename", "member", "rename", { name: "Secret" }, "42501"],
      ["admin cannot appoint admin", "admin", "invite", {
        email: users.other.email,
        role: "admin",
      }, "42501"],
      ["admin cannot promote self", "admin", "change_role", {
        user_id: users.admin.id,
        role: "admin",
      }, "42501"],
      ["admin cannot change owner", "admin", "remove_member", {
        user_id: users.owner.id,
      }, "PT409"],
      ["owner cannot leave", "owner", "leave", {}, "PT409"],
      ["member cannot transfer", "member", "transfer_offer", {
        user_id: users.admin.id,
      }, "42501"],
      ["folder from another team unavailable", "admin", "folder_remove", {
        folder_id: randomUUID(),
      }, "PT404"],
      ["invalid role", "owner", "change_role", {
        user_id: users.member.id,
        role: "owner",
      }, "22023"],
      ["control name", "owner", "rename", { name: "a\nb" }, "22023"],
      ["blank name", "owner", "rename", { name: "  " }, "22023"],
    ]
  ) await deny(name, who, action, request(await revision(), extra), code);
  await deny(
    "metadata cannot grant role",
    "outsider",
    "get",
    { team_id: team },
    "PT404",
    { claims: { user_metadata: { role: "owner", team_id: team } } },
  );
  await deny(
    "stale revision",
    "owner",
    "rename",
    request(1, { name: "Stale" }),
    "PT409",
  );
  await deny(
    "fractional revision",
    "owner",
    "rename",
    request(1.5, { name: "Fractional" }),
    "22023",
  );
  await deny(
    "old request",
    "owner",
    "rename",
    request(await revision(), {
      name: "Old",
      issued_at: "2000-01-01T00:00:00Z",
    }),
    "PT409",
  );
  await deny(
    "future request",
    "owner",
    "rename",
    request(await revision(), {
      name: "Future",
      issued_at: "2099-01-01T00:00:00Z",
    }),
    "PT409",
  );
  await deny(
    "oversized body",
    "owner",
    "rename",
    request(await revision(), { name: "x".repeat(17000) }),
    "22023",
  );
  const rename = request(await revision(), { name: "Design collective" });
  const renamed = await ok("rename", "admin", "rename", rename);
  check(
    "rename retry",
    await ok("retry rename", "admin", "rename", rename),
    renamed,
  );
  await deny("changed command", "admin", "rename", {
    ...rename,
    name: "Changed",
  }, "PT409");
  await change("demote admin", "owner", "change_role", {
    user_id: users.admin.id,
    role: "member",
  });
  await deny("demoted replay denied", "admin", "rename", rename, "42501");
  await change("restore admin", "owner", "change_role", {
    user_id: users.admin.id,
    role: "admin",
  });
  await pg.raw(
    `update auth.sessions set not_after=now()-interval '1 second' where id=${
      lit(users.owner.session)
    }`,
  );
  await deny("expired session", "owner", "get", { team_id: team }, "28000");
  await pg.raw(
    `update auth.sessions set not_after=null where id=${
      lit(users.owner.session)
    };update auth.users set banned_until=now()+interval '1 day' where id=${
      lit(users.owner.id)
    }`,
  );
  await deny("banned actor", "owner", "get", { team_id: team }, "28000");
  await pg.raw(
    `update auth.users set banned_until=null,email_confirmed_at=null where id=${
      lit(users.owner.id)
    }`,
  );
  await deny("unverified actor", "owner", "get", { team_id: team }, "28000");
  await pg.raw(
    `update auth.users set email_confirmed_at=now() where id=${
      lit(users.owner.id)
    }`,
  );
  const pending = await change("admin invites outsider", "admin", "invite", {
    email: users.outsider.email,
    role: "member",
  });
  await deny(
    "duplicate invite",
    "owner",
    "invite",
    request(await revision(), { email: users.outsider.email, role: "member" }),
    "PT409",
  );
  await pg.raw(
    `update auth.users set email='changed@example.invalid' where id=${
      lit(users.outsider.id)
    }`,
  );
  await deny(
    "old email cannot accept",
    "outsider",
    "accept_invitation",
    request(await revision(), { invitation_id: pending.invitation_id }),
    "PT404",
  );
  await pg.raw(
    `update auth.users set email=${lit(users.outsider.email)} where id=${
      lit(users.outsider.id)
    }`,
  );
  await change("revoke inviter role", "owner", "change_role", {
    user_id: users.admin.id,
    role: "member",
  });
  await deny(
    "revoked invitation cannot accept",
    "outsider",
    "accept_invitation",
    request(await revision(), { invitation_id: pending.invitation_id }),
    "PT404",
  );
  await change("restore inviter", "owner", "change_role", {
    user_id: users.admin.id,
    role: "admin",
  });
  const expired = await change("invite expiry fixture", "owner", "invite", {
    email: users.other.email,
    role: "guest",
  });
  await pg.raw(
    `update taskfold_private.team_invitations set expires_at=now()-interval '1 second' where id=${
      lit(expired.invitation_id)
    }`,
  );
  await deny(
    "expired invitation",
    "other",
    "accept_invitation",
    request(await revision(), { invitation_id: expired.invitation_id }),
    "PT404",
  );
  const deleteOwner = await pg.raw(
    `delete from auth.users where id=${lit(users.owner.id)}`,
  ).then(() => null, (e) => e.code);
  check("direct owner Auth deletion restricted", deleteOwner, "23503");
  const removal = await pg.value(
    `public.taskfold_account_removal_begin(${lit(users.owner.id)},${
      lit(users.owner.session)
    },${lit("1".repeat(64))})`,
    { role: "service_role" },
  );
  check("account removal ownership guard", removal.code, "PT409");
  // Server-issued nonce, archive and role changes invalidate pending authority.
  await change("rename folder", "admin", "folder_rename", {
    folder_id: folder.folder_id,
    name: "Research",
  });
  await change("remove folder", "admin", "folder_remove", {
    folder_id: folder.folder_id,
  });
  await change("archive team", "owner", "archive");
  await deny(
    "archived team edit",
    "admin",
    "rename",
    request(await revision(), { name: "Archived edit" }),
    "PT409",
  );
  await deny(
    "nonowner unarchive",
    "admin",
    "unarchive",
    request(await revision()),
    "42501",
  );
  await change("unarchive team", "owner", "unarchive");
  await deny(
    "guest cannot own team",
    "owner",
    "transfer_offer",
    request(await revision(), { user_id: users.guest.id }),
    "22023",
  );
  const expiredOffer = await change(
    "expiring transfer",
    "owner",
    "transfer_offer",
    { user_id: users.member.id },
  );
  await pg.raw(
    `update taskfold_private.team_transfers set expires_at=now()-interval '1 second' where team_id=${
      lit(team)
    }`,
  );
  await deny(
    "expired transfer",
    "member",
    "transfer_accept",
    request(await revision(), { transfer_id: expiredOffer.transfer_id }),
    "PT404",
  );
  await change("cancel transfer", "owner", "transfer_cancel");
  const declined = await change(
    "replace expired invitation",
    "owner",
    "invite",
    { email: users.other.email, role: "guest" },
  );
  await change("decline own invitation", "other", "decline_invitation", {
    invitation_id: declined.invitation_id,
  });
  check(
    "decline clears pending",
    (await ok("declined inbox", "other", "invitations", {})).invitations.length,
    0,
  );
  // Every table remains inaccessible through ordinary authenticated SQL.
  for (
    const table of [
      "team_config",
      "teams",
      "team_members",
      "team_invitations",
      "team_transfers",
      "team_folders",
      "team_commands",
      "team_creation_usage",
    ]
  ) {
    check(
      "no select grant " + table,
      (await run(
        users.admin,
        `(select to_jsonb(count(*)) from taskfold_private.${table})`,
      )).code,
      "42501",
    );
    check(
      "no delete grant " + table,
      (await run(
        users.admin,
        `to_jsonb(has_table_privilege(current_user,'taskfold_private.${table}','delete'))`,
      )).value,
      false,
    );
  }
  // Permission is reevaluated after an actual competing administration commit.
  const roleHolder = await pg.hold(
    `select pg_advisory_xact_lock(hashtextextended('team:'||${
      lit(team)
    },51712))`,
  );
  const heldRevision = await revision();
  const roleWaiter = rpc(
    "admin",
    "rename",
    request(heldRevision, { name: "Revoked queued edit" }),
    { app: "team-role-waiter" },
  );
  await pg.waitForLock("team-role-waiter", roleHolder.pid);
  await roleHolder.release(
    "commit",
    `update taskfold_private.team_members set role='member' where team_id=${
      lit(team)
    } and user_id=${
      lit(users.admin.id)
    };update taskfold_private.teams set revision=revision+1 where id=${
      lit(team)
    }`,
  );
  check("queued role revoked", (await roleWaiter).code, "42501");
  await change("restore queued administrator", "owner", "change_role", {
    user_id: users.admin.id,
    role: "admin",
  });
  const offer = await change("offer ownership", "owner", "transfer_offer", {
    user_id: users.member.id,
  });
  await deny(
    "wrong transfer accepter",
    "admin",
    "transfer_accept",
    request(await revision(), { transfer_id: offer.transfer_id }),
    "PT404",
  );
  await change("accept ownership", "member", "transfer_accept", {
    transfer_id: offer.transfer_id,
  });
  check(
    "new owner role",
    (await ok("transferred owner detail", "member", "get", { team_id: team }))
      .role,
    "owner",
  );
  check(
    "former owner admin",
    (await ok("former owner detail", "owner", "get", { team_id: team })).role,
    "admin",
  );
  check(
    "former owner can authorize removal",
    (await pg.value(
      `public.taskfold_account_removal_begin(${lit(users.owner.id)},${
        lit(users.owner.session)
      },${lit("2".repeat(64))})`,
      { role: "service_role" },
    )).code,
    null,
  );
  await pg.raw(`delete from auth.users where id=${lit(users.owner.id)}`);
  check(
    "former owner membership removed",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_members where user_id=${
        lit(users.owner.id)
      }`,
    ),
    0,
  );
  check(
    "transferred team has surviving owner",
    await pg.scalar(
      `select to_jsonb(owner_id) from taskfold_private.teams where id=${
        lit(team)
      }`,
    ),
    users.member.id,
  );
  // A waiter must recheck its session after the real team lock is released.
  const holder = await pg.hold(
    `select pg_advisory_xact_lock(hashtextextended('team:'||${
      lit(team)
    },51712))`,
  );
  await pg.raw(
    `update auth.sessions set not_after=clock_timestamp()+interval '0.4 second' where id=${
      lit(users.guest.session)
    }`,
  );
  const waiting = rpc("guest", "get", { team_id: team }, {
    app: "team-expiry-waiter",
  });
  await pg.waitForLock("team-expiry-waiter", holder.pid);
  await pg.raw("select pg_sleep(0.5)");
  await holder.release();
  check("queued expiry rechecked", (await waiting).code, "28000");
  await pg.raw(
    `update auth.sessions set not_after=null where id=${
      lit(users.guest.session)
    }`,
  );
  // Two real transactions with one reviewed revision: one writes, one conflicts.
  const rev = await revision();
  const concurrent = await Promise.all([
    rpc("member", "rename", request(rev, { name: "Concurrent A" })),
    rpc("admin", "rename", request(rev, { name: "Concurrent B" })),
  ]);
  check(
    "concurrent reviewed writes",
    [...concurrent.map((x) => x.code)].sort(),
    [null, "PT409"].sort(),
  );
  check("single revision increment", await revision(), rev + 1);
  await pg.raw(
    `update taskfold_private.teams set day_operations=2000 where id=${
      lit(team)
    }`,
  );
  await deny(
    "operation quota",
    "member",
    "rename",
    request(await revision(), { name: "Over quota" }),
    "PT429",
  );
  await change(
    "safety revoke remains possible at quota",
    "member",
    "remove_member",
    { user_id: users.guest.id },
  );
  await pg.raw(`update taskfold_private.team_config set enabled=false`);
  await deny(
    "paused blocks edits",
    "member",
    "rename",
    request(await revision(), { name: "Paused" }),
    "PT503",
  );
  const deletion = request(await revision());
  const deleted = await ok(
    "paused owner deletion",
    "member",
    "delete",
    deletion,
  );
  check(
    "delete retry",
    await ok("retry deletion", "member", "delete", deletion),
    deleted,
  );
  check(
    "tombstone erases name owner",
    await pg.scalar(
      `select jsonb_build_array(name,owner_id,state) from taskfold_private.teams where id=${
        lit(team)
      }`,
    ),
    [null, null, "deleted"],
  );
  check(
    "team member data removed",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.team_members where team_id=${
        lit(team)
      }`,
    ),
    0,
  );
  await pg.raw("update taskfold_private.team_config set enabled=true");
  await deny(
    "deleted identifier cannot resurrect",
    "member",
    "create",
    request(null, { name: "Resurrect" }),
    "PT409",
  );
  // Last owner slot and per-day creation budget serialize across real sessions.
  await pg.raw(
    `insert into taskfold_private.team_creation_usage values(${
      lit(users.other.id)
    },(clock_timestamp() at time zone 'UTC')::date,19) on conflict(user_id) do update set requests=19`,
  );
  const lastSlot = await Promise.all([
    rpc(
      "other",
      "create",
      request(null, { name: "Last slot A" }, randomUUID()),
    ),
    rpc(
      "other",
      "create",
      request(null, { name: "Last slot B" }, randomUUID()),
    ),
  ]);
  check(
    "one last daily creation slot",
    [...lastSlot.map((x) => x.code)].sort(),
    [null, "PT429"].sort(),
  );
  check(
    "daily creation counter stays bounded",
    await pg.scalar(
      `select to_jsonb(requests) from taskfold_private.team_creation_usage where user_id=${
        lit(users.other.id)
      }`,
    ),
    20,
  );
  // Failed creates and rejected updates leave no partial records/receipts.
  check(
    "failed create no partial team",
    await pg.scalar(
      `select to_jsonb(count(*)) from taskfold_private.teams where owner_id=${
        lit(users.other.id)
      }`,
    ),
    1,
  );
  const advisors = await pg.advisors();
  check(
    "no team advisor findings",
    advisors.result.filter((x) =>
      ["ERROR", "WARN"].includes(x.level) &&
      (x.metadata?.name?.startsWith("team_") || x.metadata?.name === "teams" ||
        x.metadata?.name === "taskfold_teams")
    ),
    [],
  );
  report.advisorBaselineFindings = advisors.result.map((x) => ({
    name: x.name,
    object: x.metadata?.schema + "." + x.metadata?.name,
  }));
  report.advisors = advisors;
  report.containerRemoved = await pg.close();
  pg = null;
  if (process.argv[4]) await writeFile(process.argv[4], JSON.stringify(nativeCommands, null, 2) + "\n");
  report.checkCount = Object.keys(report.checks).length;
  if (output) await writeFile(output, JSON.stringify(report, null, 2) + "\n");
  console.log(
    JSON.stringify({
      checks: report.checkCount,
      containerRemoved: report.containerRemoved,
      advisorsRan: advisors.ran,
    }),
  );
} finally {
  if (pg) await pg.close();
}
