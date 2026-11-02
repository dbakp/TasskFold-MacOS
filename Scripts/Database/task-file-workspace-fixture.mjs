// Isolated workspace read adapter: actual SQL, authenticated RLS and unchanged
// workspace routines. This is not PostgREST, genuine Auth or full schema parity.
import { readFile } from "node:fs/promises";
import assert from "node:assert/strict";
import { literal as lit } from "./postgres-fixture.mjs";
export const workspaceTables = [
  "projects",
  "sections",
  "labels",
  "tasks",
  "profiles",
  "project_collaborators",
  "saved_views",
  "favorites",
  "view_preferences",
  "view_orders",
  "project_templates",
  "reminder_preferences",
  "focus_sessions",
  "task_activity_epoch",
  "task_activity",
];
const optionalTables = [
  "task_assignment_provenance",
  "task_node_activity_epoch",
  "task_node_activity",
];
export async function loadTaskFileWorkspaceFixture(pg) {
  // These inspected native base tables are omitted by the narrower provider
  // fixture. Reuse its recorded base definitions, never make missing reads [].
  const base = await readFile(
    new URL("../Diagnostics/webhook-hosted-base.sql", import.meta.url),
    "utf8",
  );
  for (const table of ["view_preferences", "favorites", "saved_views"]) {
    assert(
      await pg.scalar(
        `select to_jsonb(to_regclass('public.${table}') is null)`,
      ),
    );
    const start = base.indexOf(`create table public.${table}(`);
    assert(start >= 0);
    const end = base.indexOf(";", start);
    assert(end > start);
    await pg.raw(base.slice(start, end + 1));
  }
  await pg.raw(
    `create table public.labels(id uuid primary key,user_id uuid not null references auth.users on delete cascade,name text,color text,order_index integer default 0);
    alter table public.profiles enable row level security;
    create policy fixture_profile_owner_read on public.profiles for select to authenticated using(user_id=(select auth.uid()));
    grant select on public.profiles to authenticated;`,
  );
  for (
    const table of [
      "labels",
      "view_preferences",
      "favorites",
      "saved_views",
      "reminder_preferences",
    ]
  ) {
    await pg.raw(`alter table public.${table} enable row level security;
      create policy fixture_workspace_owner_read on public.${table} for select to authenticated using(user_id=(select auth.uid()));
      grant select on public.${table} to authenticated;`);
  }
  await pg.raw(
    await readFile(
      new URL(
        "../../supabase/migrations/20261006073641_durable_focus_session.sql",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const actual = await pg.scalar(
    `select coalesce(jsonb_agg(relname order by relname),'[]') from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and relname=any(array[${
      workspaceTables.map(lit).join(",")
    }]) and c.relrowsecurity`,
  );
  assert.deepEqual(
    actual,
    [...workspaceTables].sort(),
    "Every required table must exist with RLS",
  );
}
export function taskFileWorkspaceAdapter(pg, users, tokens) {
  const counts = { boundary: 0, auth: 0, tables: {}, rejected: 0, errors: [] };
  const allowed = new Set([...workspaceTables, ...optionalTables]);
  async function reply(req, res) {
    try {
      assert.equal(req.headers.apikey, "synthetic-public");
      const entry = Object.entries(tokens).find(([, token]) =>
        req.headers.authorization === "Bearer " + token
      );
      assert(entry, "Disposable authenticated user required");
      const user = users[entry[0]],
        url = new URL(req.url.slice("/native".length), "http://127.0.0.1");
      const claims = JSON.stringify({
        sub: user.id,
        session_id: user.session,
        role: "authenticated",
      });
      const sql = (expression) =>
        pg.scalar(
          `begin;set local role authenticated;set local request.jwt.claim.sub=${
            lit(user.id)
          };set local request.jwt.claims=${
            lit(claims)
          };select ${expression};rollback;`,
        );
      let result;
      if (url.pathname === "/rest/v1/rpc/taskfold_workspace_boundary") {
        assert.equal(req.method, "POST");
        assert.equal(url.search, "");
        let body = "";
        for await (const bytes of req) {
          body += bytes.toString("utf8");
          assert(body.length <= 32);
        }
        assert.deepEqual(JSON.parse(body), {});
        counts.boundary++;
        result = await sql("public.taskfold_workspace_boundary()");
      } else if (url.pathname === "/auth/v1/user") {
        assert.equal(req.method, "GET");
        assert.equal(url.search, "");
        await sql("public.taskfold_workspace_boundary()");
        counts.auth++;
        result = { id: user.id };
      } else {
        assert.equal(req.method, "GET");
        const table = url.pathname.slice("/rest/v1/".length);
        assert(url.pathname.startsWith("/rest/v1/") && allowed.has(table));
        const params = url.searchParams, keys = [...params.keys()];
        assert.equal(new Set(keys).size, keys.length);
        assert.equal(params.get("select"), "*");
        assert.equal(params.get("limit"), "500");
        let order, offset = 0, predicate = "true";
        if (table === "task_activity" || table === "task_node_activity") {
          assert.deepEqual(keys.sort(), [
            "limit",
            "order",
            "select",
            "sequence",
          ]);
          assert.equal(params.get("order"), "sequence.asc");
          assert(/^gt\.[0-9]{1,16}$/.test(params.get("sequence")));
          const cursor = Number(params.get("sequence").slice(3));
          assert(Number.isSafeInteger(cursor));
          order = "sequence";
          predicate = "sequence>" + cursor;
        } else {
          assert.deepEqual(keys.sort(), ["limit", "offset", "order", "select"]);
          order = table === "profiles" ? "user_id" : "id";
          assert.equal(params.get("order"), order);
          assert(/^[0-9]{1,6}$/.test(params.get("offset")));
          offset = Number(params.get("offset"));
          assert(offset <= 100000);
        }
        counts.tables[table] = (counts.tables[table] ?? 0) + 1;
        // The boundary invokes the real live-session/account guard. The rows
        // are selected by the authenticated role, not by the fixture owner.
        const answer = await sql(
          `jsonb_build_object('boundary',public.taskfold_workspace_boundary(),'rows',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from (select * from public.${table} where ${predicate} order by ${order} offset ${offset} limit 500) r))`,
        );
        result = answer.rows;
      }
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(result));
    } catch (error) {
      counts.rejected++;
      counts.errors.push({
        code: String(error.code ?? "adapter_contract").slice(0, 80),
        path: req.url.split("?")[0].slice(0, 120),
      });
      res.writeHead(400, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ code: "workspace_fixture_read_failed" }));
    }
  }
  return { reply, counts };
}
