import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { createTaskFileProviderDatabase } from "./task-file-provider-schema.mjs";
import { createTaskFileProviderHttp } from "./task-files-provider-http-fixture.mjs";
import {
  loadTaskFileWorkspaceFixture,
  taskFileWorkspaceAdapter,
  workspaceTables,
} from "./task-file-workspace-fixture.mjs";
import { literal as lit } from "./postgres-fixture.mjs";
if (Number(process.versions.node.split(".")[0]) < 22) {
  throw Error("Node 22 required");
}
const output = process.argv[2];
assert(output?.startsWith("/tmp/taskfold-"));
const owner = "ec240000-0000-4000-8000-000000000001",
  creator = "ec240000-0000-4000-8000-000000000099",
  outsider = "ec240000-0000-4000-8000-000000000098",
  team = "ec240000-0000-4000-8000-000000000004",
  project = "ec240000-0000-4000-8000-000000000003",
  task = "ec240000-0000-4000-8000-000000000002";
const users = Object.fromEntries(
  Object.entries({ owner, creator, outsider }).map((
    [k, id],
  ) => [k, { id, session: randomUUID() }]),
);
const report = {
  checks: {},
  genuineAuth: false,
  fullSchemaParity: false,
  hostedChanges: false,
};
let pg, storage, http;
const check = (name, a, b = true) => {
  assert.deepEqual(a, b, name);
  report.checks[name] = true;
  console.log("passed:", name);
};
try {
  ({ pg, storage } = await createTaskFileProviderDatabase());
  await loadTaskFileWorkspaceFixture(pg);
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
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(creator)
    },'Workspace proof');insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(creator)},'admin'),(${lit(team)},${
      lit(owner)
    },'member');insert into public.projects(id,user_id,name) values(${
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
      lit(owner)
    },'editor');insert into public.tasks(id,user_id,project_id,title) values(${
      lit(task)
    },${lit(creator)},${lit(project)},'Actual SQL task'),(${lit(outsider)},${
      lit(creator)
    },null,'Private creator task');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_task_types_enabled=true`,
  );
  http = await createTaskFileProviderHttp(
    pg,
    storage,
    users,
    taskFileWorkspaceAdapter,
  );
  const request = async (path, who = "owner", method = "GET") => {
    const res = await fetch(http.url + path, {
      method,
      headers: {
        apikey: "synthetic-public",
        Authorization: "Bearer " + (http.tokens[who] ?? "invalid"),
        "Content-Type": "application/json",
      },
      ...(method === "POST" ? { body: "{}" } : {}),
      signal: AbortSignal.timeout(30000),
    });
    return { status: res.status, value: await res.json() };
  };
  const boundary = await request(
    "/rest/v1/rpc/taskfold_workspace_boundary",
    "owner",
    "POST",
  );
  check("actual SQL workspace boundary succeeds", boundary.status, 200);
  check(
    "actual project role is editor",
    boundary.value.projects[0].role,
    "editor",
  );
  for (const table of workspaceTables) {
    const query = table === "task_activity"
      ? "?select=*&order=sequence.asc&sequence=gt.0&limit=500"
      : `?select=*&order=${
        table === "profiles" ? "user_id" : "id"
      }&offset=0&limit=500`;
    const response = await request("/rest/v1/" + table + query);
    check("actual authenticated table read: " + table, response.status, 200);
    assert(Array.isArray(response.value));
    if (table === "tasks") {
      check(
        "RLS hides the creator private task",
        response.value.map((r) => r.id),
        [task],
      );
    }
    if (table === "profiles") {
      check(
        "fixture profile read is account scoped",
        response.value.map((r) => r.user_id),
        [owner],
      );
    }
  }
  const path = "/rest/v1/tasks?select=*&order=id&offset=0&limit=500";
  check(
    "outsider task read remains empty under actual RLS",
    (await request(path, "outsider")).value,
    [],
  );
  check(
    "invalid token cannot read",
    (await request(path, "invalid")).status,
    400,
  );
  await pg.raw(
    `update auth.sessions set not_after=now()-interval '1 minute' where id=${
      lit(users.owner.session)
    }`,
  );
  check(
    "expired SQL session cannot read cached role",
    (await request(path)).status,
    400,
  );
  check(
    "expired SQL session cannot obtain boundary",
    (await request("/rest/v1/rpc/taskfold_workspace_boundary", "owner", "POST"))
      .status,
    400,
  );
  await pg.raw(
    `update auth.sessions set not_after=null where id=${
      lit(users.owner.session)
    };delete from taskfold_private.team_project_grants where project_id=${
      lit(project)
    } and user_id=${lit(owner)}`,
  );
  check("withdrawn grant hides actual task", (await request(path)).value, []);
  check(
    "withdrawn grant removes boundary project",
    (await request("/rest/v1/rpc/taskfold_workspace_boundary", "owner", "POST"))
      .value.projects,
    [],
  );
  report.workspaceCounts = http.workspaceCounts;
  report.checkCount = Object.keys(report.checks).length;
} catch (error) {
  report.error = { message: error.message, code: error.code };
  throw error;
} finally {
  const errors = [];
  for (
    const [r, key] of [[http, "httpClosed"], [storage, "storageRemoved"], [
      pg,
      "databaseRemoved",
    ]]
  ) {
    if (r) {
      try {
        report[key] = await r.close();
      } catch (error) {
        errors.push(error.message);
      }
    }
  }
  if (errors.length) report.cleanupErrors = errors;
  await writeFile(output, JSON.stringify(report, null, 2) + "\n");
}
if (report.cleanupErrors?.length) throw Error("Owned cleanup failed");
console.log(
  JSON.stringify({
    checks: report.checkCount,
    storageRemoved: report.storageRemoved,
    databaseRemoved: report.databaseRemoved,
  }),
);
