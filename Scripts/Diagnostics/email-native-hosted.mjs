// Private controller only. App HTTP/Auth/Keychain are never intercepted.
import assert from "node:assert/strict";
import { mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createHash, randomUUID } from "node:crypto";
export async function runNativeEmailFixture(c) {
  const root = "/private/tmp/taskfold-email-native";
  await mkdir(root, { mode: 0o700 });
  assert(((await stat(root)).mode & 0o077) === 0);
  const users = [];
  for (let n = 0; n < 4; n++) users.push(await c.makeUser());
  const accounts = users.map((u, i) => ({
    id: u.id,
    email: u.email,
    password: u.password,
    device: i < 2 ? "phone" : "tablet",
    role: i % 2 === 0 ? "A" : "B",
  }));
  const safeAccounts = accounts.map(({ id, device, role }) => ({
    id,
    device,
    role,
  }));
  c.result.fixtureAccounts = safeAccounts;
  await writeFile(
    c.output + ".accounts.json",
    JSON.stringify({
      origin: c.origin,
      project: c.project,
      accounts: safeAccounts,
    }),
    { mode: 0o600 },
  );
  const suffix = randomUUID().slice(0, 8),
    titles = {
      phone: "Keep email recovery work phone " + suffix,
      tablet: "Keep email recovery work tablet " + suffix,
    };
  await writeFile(
    join(root, "native.json"),
    JSON.stringify({ url: c.origin, project: c.project, accounts, titles }),
    { mode: 0o600, flag: "wx" },
  );
  const digest = (v) =>
    createHash("sha256").update(JSON.stringify(v)).digest("hex");
  const saved = new Map(),
    expired = new Map(),
    passed = new Set(),
    handled = new Set();
  const rows = async (owner, table) =>
    (await c.database(
      `select coalesce(jsonb_agg(to_jsonb(t)order by id),'[]'::jsonb)as value from ${table} t where user_id=${
        c.lit(owner)
      }`,
    ))[0].value;
  const stableRoute = (r) =>
    Object.fromEntries(
      Object.entries(r).filter(([k]) =>
        !["state", "revision", "updated_at", "accept_after"].includes(k)
      ),
    );
  console.log(
    "Native email fixture ready: actual hosted Auth, gateway, SQL and device-only vault; synthetic data only",
  );
  try {
    const deadline = Date.now() + 90 * 60000;
    while (Date.now() < deadline) {
      if (await readFile(join(root, "finish.json"), "utf8").catch(() => null)) {
        break;
      }
      const raw = await readFile(join(root, "request.json"), "utf8").catch(() =>
        null
      );
      if (raw) {
        const r = JSON.parse(raw);
        assert(
          /^[a-f0-9-]{36}$/.test(r.id) &&
            ["phone", "tablet"].includes(r.device) &&
            typeof r.operation === "string",
        );
        if (!handled.has(r.id)) {
          const account = accounts.find((a) =>
              a.device === r.device && a.role === "A"
            ),
            other = accounts.find((a) =>
              a.device === r.device && a.role === "B"
            );
          const routes = await rows(
              account.id,
              "taskfold_private.email_routes",
            ),
            tasks = await rows(account.id, "public.tasks");
          if (r.operation === "baseline") {
            assert.equal(routes.length, 1);
            assert.equal(routes[0].state, "active");
            assert.equal(routes[0].revision, 1);
            assert.equal(tasks.length, 1);
            assert.equal(tasks[0].title, titles[r.device]);
            saved.set(r.device, { route: routes[0], task: tasks });
            c.check(
              "native-" + r.device + "-actual-task-and-private-route-baseline",
              true,
            );
          } else {
            const baseline = saved.get(r.device);
            assert(baseline, "Baseline must precede native recovery");
            assert.equal(
              digest(tasks),
              digest(baseline.task),
              "Saved task fingerprint changed",
            );
            assert.equal(routes.length, 1);
            assert.equal(
              digest(stableRoute(routes[0])),
              digest(stableRoute(baseline.route)),
              "Original route identity changed",
            );
            if (r.operation === "expire-session") {
              const sessions = await c.database(
                `update auth.sessions set not_after=clock_timestamp()-interval '1 minute' where user_id=${
                  c.lit(account.id)
                } returning id`,
              );
              assert(sessions.length > 0);
              expired.set(r.device, sessions.map((s) => s.id));
              c.check("native-" + r.device + "-actual-sessions-expired", true);
            } else if (r.operation === "renewed") {
              assert.equal(
                digest(routes[0]),
                digest(baseline.route),
                "Renewal changed original route before retry",
              );
              const sessions = await c.database(
                `select id from auth.sessions where user_id=${
                  c.lit(account.id)
                } and (not_after is null or not_after>clock_timestamp())`,
              );
              assert(
                sessions.some((s) => !expired.get(r.device).includes(s.id)),
              );
              c.check(
                "native-" + r.device + "-renewed-session-and-original-row",
                true,
              );
            } else if (r.operation === "paused") {
              assert.equal(routes[0].state, "paused");
              assert.equal(routes[0].revision, 2);
              c.check(
                "native-" + r.device + "-saved-pause-retry-confirmed",
                true,
              );
            } else if (r.operation === "resumed") {
              assert.equal(routes[0].state, "active");
              assert.equal(routes[0].revision, 3);
              c.check("native-" + r.device + "-resume-confirmed", true);
            } else if (r.operation === "isolated") {
              assert.equal(
                (await rows(other.id, "taskfold_private.email_routes")).length,
                0,
              );
              assert.equal(routes[0].state, "active");
              assert.equal(routes[0].revision, 3);
              c.check(
                "native-" + r.device + "-other-account-has-no-route",
                true,
              );
            } else if (r.operation === "revoked") {
              assert.equal(routes[0].state, "revoked");
              assert.equal(routes[0].revision, 4);
              c.check("native-" + r.device + "-revoke-confirmed", true);
            } else if (r.operation === "passed") {
              assert.equal(routes[0].state, "revoked");
              assert.equal(routes[0].revision, 4);
              passed.add(r.device);
              c.check(
                "native-" + r.device +
                  "-ui-relaunch-isolation-cleanup-completed",
                true,
              );
            } else throw Error("Unknown native email operation");
          }
          const file = join(root, r.id + ".tmp");
          await writeFile(file, JSON.stringify({ id: r.id, ok: true }), {
            mode: 0o600,
          });
          await rm(join(root, "request.json"));
          await import("node:fs/promises").then((fs) =>
            fs.rename(file, join(root, "response.json"))
          );
          handled.add(r.id);
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 200));
    }
    assert.deepEqual(
      [...passed].sort(),
      ["phone", "tablet"],
      "Both native device runs must finish",
    );
    c.result.nativeUIClaimed = true;
    c.result.nativeFingerprints = Object.fromEntries(
      [...saved].map((
        [device, b],
      ) => [device, { route: digest(b.route), task: digest(b.task) }]),
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}
