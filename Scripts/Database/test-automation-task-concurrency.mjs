// Genuine independent PostgreSQL sessions, synthetic local accounts only.
import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import {
  createPostgresFixture,
  literal as lit,
  postgresImage,
} from "./postgres-fixture.mjs";
import { createPostgresHttpFixture } from "./postgres-http-fixture.mjs";
import { loadAutomationPostgresSchema } from "./automation-postgres-schema.mjs";
const output = process.argv[2],
  summary = {
    date: new Date().toISOString(),
    image: postgresImage,
    checks: {},
    barriers: [],
    realTasksChanged: 0,
    hostedAcceptance: false,
    containerRemoved: false,
  };
let pg, checks = 0, sequence = 1000;
const id = (n) => "f09ccafe-0000-4000-8000-" + String(n).padStart(12, "0");
const a = id(1),
  b = id(2),
  sa = id(11),
  sb = id(12),
  project = id(31),
  member = id(41);
const same = (name, actual, expected = true) => {
  summary.checks[name] = JSON.stringify(actual) === JSON.stringify(expected);
  assert.deepEqual(actual, expected, name);
  checks++;
};
const payload = (value) => lit(JSON.stringify(value)) + "::jsonb";
const body = (target, generation, extra = {}) => ({
  request_id: id(sequence++),
  id: target,
  task_generation: generation,
  time_zone: "UTC",
  ...extra,
});
const expression = (key, action, document) =>
  `public.taskfold_automation_write(${lit(key.id)},${lit(key.hash)},${
    lit(action)
  },${payload(document)})`;
const accountLock =
  `select pg_advisory_xact_lock(hashtextextended('automation:${a}',11819))`;
const app = (kind) => "taskfold-" + kind + "-" + randomUUID().slice(0, 8);
async function resetUsage() {
  await pg.raw(
    "update taskfold_private.automation_keys set window_started_at=clock_timestamp(),window_requests=0,usage_day=(clock_timestamp() at time zone 'UTC')::date,day_requests=0;delete from taskfold_private.automation_account_usage",
  );
}
async function mint(n, owner = a) {
  const secret = "tfk_v1_" + id(n).replaceAll("-", "") +
    "_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
  const key = {
    id: id(n),
    secret,
    hash: createHash("sha256").update(secret).digest("hex"),
  };
  await pg.raw(
    `insert into taskfold_private.automation_keys(id,user_id,name,token_hash,scopes,ttl_days,expires_at) values(${
      lit(key.id)
    },${lit(owner)},'Synthetic worker',${
      lit(key.hash)
    },array['tasks:read','tasks:create','tasks:update','tasks:complete','tasks:delete'],30,clock_timestamp()+interval '1 day')`,
  );
  return key;
}
async function get(key, target) {
  const answer = await pg.value(
    `public.taskfold_automation_read(${lit(key.id)},${lit(key.hash)},'get',${
      payload({ id: target })
    })`,
  );
  same("read-" + target.slice(-6) + "-" + checks, answer.code, null);
  return answer.value.task;
}
async function create(key, n, fields = {}) {
  const input = body(id(n), id(n + 10000), {
    fields: { title: "Synthetic task " + n, ...fields },
  });
  const answer = await pg.value(expression(key, "create", input));
  same("create-" + n, answer.code, null);
  return { input, task: await get(key, id(n)) };
}
async function race(name, operations) {
  const holder = await pg.hold(accountLock);
  const workers = operations.map((operation) => {
    const identity = app(name);
    return { app: identity, promise: pg.value(operation, { app: identity }) };
  });
  try {
    const blocked = await Promise.all(
      workers.map((worker) => pg.waitForLock(worker.app, holder.pid)),
    );
    same(
      name + "-all-queued-on-account-lock",
      blocked.every((row) => row.blockers.includes(holder.pid)),
    );
    same(
      name + "-independent-backends",
      new Set(blocked.map((row) => row.pid)).size,
      operations.length,
    );
    summary.barriers.push({
      case: name,
      holderPid: holder.pid,
      blockedPids: blocked.map((row) => row.pid),
      observedBeforeRelease: true,
    });
    await holder.release();
    return await Promise.all(workers.map((worker) => worker.promise));
  } finally {
    await holder.release("rollback");
  }
}
try {
  summary.phase = "initialize";
  pg = await createPostgresFixture();
  summary.postgresVersion = pg.serverVersion;
  await loadAutomationPostgresSchema(pg.raw);
  await pg.raw(
    `insert into auth.users(id,email) values(${
      lit(a)
    },'race-a@example.invalid'),(${
      lit(b)
    },'race-b@example.invalid');insert into public.profiles(user_id) values(${
      lit(a)
    }),(${lit(b)});insert into auth.sessions(id,user_id,not_after) values(${
      lit(sa)
    },${lit(a)},clock_timestamp()+interval '1 day'),(${lit(sb)},${
      lit(b)
    },clock_timestamp()+interval '1 day');insert into public.projects(id,user_id,name) values(${
      lit(project)
    },${
      lit(b)
    },'Synthetic shared project');select set_config('request.jwt.claim.sub',${
      lit(b)
    },false);insert into public.project_collaborators(id,project_id,invited_email,invited_by) values(${
      lit(member)
    },${lit(project)},'race-a@example.invalid',${
      lit(b)
    });select set_config('request.jwt.claim.sub',${
      lit(a)
    },false);update public.project_collaborators set status='accepted' where id=${
      lit(member)
    }`,
  );
  const key = await mint(21), second = await mint(22);
  summary.phase = "duplicate-retries";
  const duplicate = body(id(101), id(10101), {
    fields: { title: "Concurrent duplicate proof" },
  });
  let results = await race(
    "duplicate",
    Array.from({ length: 4 }, () => expression(key, "create", duplicate)),
  );
  same("duplicate-all-acknowledged", results.every((r) => r.code === null));
  same(
    "duplicate-one-effect",
    results.filter((r) => !r.value.replayed).length,
    1,
  );
  same(
    "duplicate-three-replays",
    results.filter((r) => r.value.replayed).length,
    3,
  );
  same(
    "duplicate-identical-receipt",
    new Set(results.map((r) => JSON.stringify(r.value.receipt))).size,
    1,
  );
  same(
    "duplicate-one-task",
    await pg.scalar(
      `select to_jsonb(count(*)::int) from public.tasks where id=${
        lit(duplicate.id)
      }`,
    ),
    1,
  );
  same(
    "duplicate-one-journal",
    await pg.scalar(
      `select to_jsonb(count(*)::int) from taskfold_private.automation_requests where request_id=${
        lit(duplicate.request_id)
      }`,
    ),
    1,
  );
  summary.phase = "conflicting-request-identity";
  await resetUsage();
  const conflicting = body(id(102), id(10102), {
    fields: { title: "First candidate" },
  });
  results = await race("identity", [
    expression(key, "create", conflicting),
    expression(second, "create", {
      ...conflicting,
      fields: { title: "Second candidate" },
    }),
  ]);
  same("identity-one-writer", results.filter((r) => r.code === null).length, 1);
  same(
    "identity-one-conflict",
    results.filter((r) => r.code === "PT409").length,
    1,
  );
  const actual = await get(key, conflicting.id);
  same(
    "identity-winner-preserved",
    ["First candidate", "Second candidate"].includes(actual.title),
  );
  summary.phase = "field-conflicts";
  await resetUsage();
  const editable = await create(key, 103);
  results = await race("disjoint", [
    expression(
      key,
      "update",
      body(editable.task.id, editable.task.task_generation, {
        base: editable.task,
        fields: { title: "Merged title" },
      }),
    ),
    expression(
      second,
      "update",
      body(editable.task.id, editable.task.task_generation, {
        base: editable.task,
        fields: { priority: 1 },
      }),
    ),
  ]);
  same("disjoint-both-accepted", results.every((r) => r.code === null));
  const row = await get(key, editable.task.id);
  same("disjoint-both-fields-retained", [row.title, row.priority], [
    "Merged title",
    1,
  ]);
  results = await race("same-field", [
    expression(
      key,
      "update",
      body(row.id, row.task_generation, {
        base: row,
        fields: { title: "Competing alpha" },
      }),
    ),
    expression(
      second,
      "update",
      body(row.id, row.task_generation, {
        base: row,
        fields: { title: "Competing beta" },
      }),
    ),
  ]);
  same(
    "same-field-one-writer",
    results.filter((r) => r.code === null).length,
    1,
  );
  same(
    "same-field-one-conflict",
    results.filter((r) => r.code === "PT409").length,
    1,
  );
  summary.phase = "recurring-completion";
  await resetUsage();
  const recurring = await create(key, 104, {
    due_date: "2026-10-23",
    is_recurring: true,
    recurrence_pattern: { type: "daily" },
  });
  results = await race("complete", [
    expression(
      key,
      "complete",
      body(recurring.task.id, recurring.task.task_generation, {
        base: recurring.task,
      }),
    ),
    expression(
      second,
      "complete",
      body(recurring.task.id, recurring.task.task_generation, {
        base: recurring.task,
      }),
    ),
  ]);
  same(
    "completion-one-effect",
    results.filter((r) => r.code === null).length,
    1,
  );
  same(
    "completion-stale-cycle-refused",
    results.filter((r) => r.code === "PT409").length,
    1,
  );
  same(
    "completion-one-successor",
    await pg.scalar(
      `select to_jsonb(count(*)::int) from public.tasks where recurrence_parent_id=${
        lit(recurring.task.id)
      }`,
    ),
    1,
  );
  same(
    "completion-revision-one",
    (await get(key, recurring.task.id)).completion_version,
    1,
  );
  summary.phase = "revocation-ordering";
  await resetUsage();
  for (const revokeFirst of [true, false]) {
    const disposable = await mint(revokeFirst ? 23 : 24);
    const input = body(
      id(revokeFirst ? 105 : 106),
      id(revokeFirst ? 10105 : 10106),
      { fields: { title: "Revocation ordering proof" } },
    );
    const revoke = `public.taskfold_automation_keys(${lit(a)},${
        lit(sa)
      },'revoke',${payload({ id: disposable.id })})`,
      write = expression(disposable, "create", input),
      holder = await pg.hold(accountLock);
    const firstApp = app("first"), secondApp = app("second");
    try {
      const first = pg.value(revokeFirst ? revoke : write, { app: firstApp });
      const firstBlocked = await pg.waitForLock(firstApp, holder.pid);
      const later = pg.value(revokeFirst ? write : revoke, { app: secondApp });
      const secondBlocked = await pg.waitForLock(secondApp, holder.pid);
      same(
        "revoke-" + revokeFirst + "-distinct-blocked-sessions",
        firstBlocked.pid !== secondBlocked.pid,
      );
      summary.barriers.push({
        case: revokeFirst ? "revoke-before-write" : "write-before-revoke",
        blockedPids: [firstBlocked.pid, secondBlocked.pid],
        observedBeforeRelease: true,
      });
      await holder.release();
      const outcomes = await Promise.all([first, later]);
      same("revoke-" + revokeFirst + "-first-accepted", outcomes[0].code, null);
      same(
        "revoke-" + revokeFirst + "-later-outcome",
        outcomes[1].code,
        revokeFirst ? "28000" : null,
      );
      same(
        "revoke-" + revokeFirst + "-task-count",
        await pg.scalar(
          `select to_jsonb(count(*)::int) from public.tasks where id=${
            lit(input.id)
          }`,
        ),
        revokeFirst ? 0 : 1,
      );
      same(
        "revoked-key-replay-" + revokeFirst,
        (await pg.value(write)).code,
        "28000",
      );
      if (!revokeFirst) {
        same(
          "new-key-can-review-retry",
          (await pg.value(expression(second, "create", input))).value.replayed,
          true,
        );
      }
    } finally {
      await holder.release("rollback");
    }
  }
  summary.phase = "membership-withdrawal";
  await resetUsage();
  const shared = await create(key, 107, { project_id: project });
  const memberHolder = await pg.hold(
      `select * from public.project_collaborators where id=${
        lit(member)
      } for update`,
    ),
    pendingApp = app("membership"),
    pendingInput = body(id(108), id(10108), {
      fields: { title: "Withdrawn member proof", project_id: project },
    });
  try {
    const pending = pg.value(expression(key, "create", pendingInput), {
      app: pendingApp,
    });
    const blocked = await pg.waitForLock(pendingApp, memberHolder.pid);
    same(
      "membership-observed-real-row-block",
      blocked.blockers.includes(memberHolder.pid),
    );
    await memberHolder.release(
      "commit",
      `select set_config('request.jwt.claim.sub',${
        lit(b)
      },false);update public.project_collaborators set status='pending' where id=${
        lit(member)
      }`,
    );
    same("withdrawn-member-write-refused", (await pending).code, "PT404");
    same(
      "withdrawn-member-task-absent",
      await pg.scalar(
        `select to_jsonb(count(*)::int) from public.tasks where id=${
          lit(pendingInput.id)
        }`,
      ),
      0,
    );
    same(
      "withdrawn-member-replay-refused",
      (await pg.value(expression(key, "create", shared.input))).code,
      "PT404",
    );
    same(
      "departed-creator-read-refused",
      (await pg.value(
        `public.taskfold_automation_read(${lit(key.id)},${
          lit(key.hash)
        },'get',${payload({ id: shared.task.id })})`,
      )).code,
      "PT404",
    );
  } finally {
    await memberHolder.release("rollback");
  }
  summary.phase = "generation-replacement";
  await resetUsage();
  const original = await create(key, 109),
    replacementGeneration = id(20109),
    replacementApp = app("replacement");
  const originalInput = body(original.task.id, original.task.task_generation, {
    base: original.task,
    fields: { title: "Must not overwrite replacement" },
  });
  const beforeAttempt = await pg.scalar(
    `select to_jsonb(day_requests) from taskfold_private.automation_keys where id=${
      lit(key.id)
    }`,
  );
  const http = await createPostgresHttpFixture(pg, key, replacementApp);
  const replacementHolder = await pg.hold(
    `set local deadlock_timeout='10s';select * from public.tasks where id=${
      lit(original.task.id)
    } for update`,
  );
  try {
    const outdated = http.call("update", originalInput);
    await pg.waitForLock(replacementApp, replacementHolder.pid);
    await replacementHolder.release(
      "commit",
      `delete from public.tasks where id=${
        lit(original.task.id)
      };insert into public.tasks(id,user_id,title,task_generation,completion_version) values(${
        lit(original.task.id)
      },${lit(a)},'Replacement row',${lit(replacementGeneration)},0)`,
    );
    const response = await outdated;
    same(
      "database-deadlock-reached-real-handler",
      http.calls.errors[0],
      "40P01",
    );
    same("actual-deadlock-is-retryable-http-503", response.status, 503);
    same("actual-deadlock-retry-after", response.retryAfter, "1");
    same("actual-deadlock-no-store", response.cache, "no-store");
    same(
      "actual-deadlock-copy-reuses-request-id",
      response.body.error.includes("same request ID"),
    );
    same(
      "deadlock-rolls-back-success-quota",
      await pg.scalar(
        `select to_jsonb(day_requests) from taskfold_private.automation_keys where id=${
          lit(key.id)
        }`,
      ),
      beforeAttempt,
    );
    same(
      "deadlock-leaves-no-journal",
      await pg.scalar(
        `select to_jsonb(count(*)::int) from taskfold_private.automation_requests where request_id=${
          lit(originalInput.request_id)
        }`,
      ),
      0,
    );
    const retry = await http.call("update", originalInput);
    same("exact-request-retry-detects-new-generation", retry.status, 409);
    same(
      "failed-exact-retry-still-no-claim",
      await pg.scalar(
        `select to_jsonb(count(*)::int) from taskfold_private.automation_requests where request_id=${
          lit(originalInput.request_id)
        }`,
      ),
      0,
    );
    same("exact-retry-preserves-success-quota",await pg.scalar(`select to_jsonb(day_requests) from taskfold_private.automation_keys where id=${lit(key.id)}`),beforeAttempt);
    same("both-failed-attempts-charge-admission",await pg.scalar("select to_jsonb(hits) from taskfold_private.automation_ingress where route='tasks' and dimension='global'"),2);
    const replacement = await get(key, original.task.id);
    same("replacement-content-safe", [
      replacement.title,
      replacement.task_generation,
    ], ["Replacement row", replacementGeneration]);
    summary.atomicReplacement = {
      sqlStates: http.calls.errors,
      firstHTTPStatus: response.status,
      retryAfter: response.retryAfter,
      exactRetryStatus: retry.status,
      replacementGenerationPreserved: true,
      admissionCalls: http.calls.admission,
      resourceCalls: http.calls.resource,
    };
  } finally {
    await replacementHolder.release("rollback");
    await http.close();
  }
  summary.phase = "cascade-review";
  await resetUsage();
  const parent = await create(key, 110),
    child = id(111),
    childGeneration = id(10111),
    reviewHolder = await pg.hold(
      `select * from public.tasks where id=${lit(parent.task.id)} for update`,
    ),
    deleteApp = app("cascade");
  const deletion = body(parent.task.id, parent.task.task_generation, {
    revision: parent.task.revision,
    descendants: [],
  });
  try {
    const staleDelete = pg.value(expression(key, "delete", deletion), {
      app: deleteApp,
    });
    await pg.waitForLock(deleteApp, reviewHolder.pid);
    await reviewHolder.release(
      "commit",
      `insert into public.tasks(id,user_id,title,task_generation,completion_version,recurrence_parent_id) values(${
        lit(child)
      },${lit(a)},'New linked occurrence',${lit(childGeneration)},0,${
        lit(parent.task.id)
      })`,
    );
    same(
      "unreviewed-new-descendant-refuses-delete",
      (await staleDelete).code,
      "PT409",
    );
    same(
      "cascade-review-preserves-both-rows",
      await pg.scalar(
        `select to_jsonb(count(*)::int) from public.tasks where id in(${
          lit(parent.task.id)
        },${lit(child)})`,
      ),
      2,
    );
    const root = await get(key, parent.task.id),
      descendant = await get(key, child);
    const reviewed = body(root.id, root.task_generation, {
      revision: root.revision,
      descendants: [{
        id: child,
        task_generation: descendant.task_generation,
        revision: descendant.revision,
      }],
    });
    same(
      "fresh-reviewed-cascade-accepted",
      (await pg.value(expression(key, "delete", reviewed))).code,
      null,
    );
    same(
      "reviewed-cascade-deletes-exact-family",
      await pg.scalar(
        `select to_jsonb(count(*)::int) from public.tasks where id in(${
          lit(root.id)
        },${lit(child)})`,
      ),
      0,
    );
  } finally {
    await reviewHolder.release("rollback");
  }
  summary.phase = "atomic-success-quotas";
  for (const dimension of ["minute", "day", "account"]) {
    await resetUsage();
    const limited = await mint(
      dimension === "minute" ? 25 : dimension === "day" ? 26 : 27,
    );
    if (dimension === "account") {
      await pg.raw(
        `insert into taskfold_private.automation_account_usage(user_id,usage_day,requests) values(${
          lit(a)
        },(clock_timestamp() at time zone 'UTC')::date,1999)`,
      );
    } else {await pg.raw(
        `update taskfold_private.automation_keys set ${
          dimension === "minute" ? "window_requests=59" : "day_requests=999"
        } where id=${lit(limited.id)}`,
      );}
    const targets = Array.from({ length: 4 }, (_, i) => id(300 + sequence + i));
    const inputs = targets.map((target, i) =>
      body(target, id(20000 + sequence + i), {
        fields: { title: "Quota race " + dimension },
      })
    );
    results = await race(
      "quota-" + dimension,
      inputs.map((input) => expression(limited, "create", input)),
    );
    same(
      dimension + "-one-within-budget",
      results.filter((r) => r.code === null).length,
      1,
    );
    same(
      dimension + "-three-over-budget",
      results.filter((r) => r.code === "PT429").length,
      3,
    );
    same(
      dimension + "-one-task-only",
      await pg.scalar(
        `select to_jsonb(count(*)::int) from public.tasks where id in(${
          targets.map(lit).join(",")
        })`,
      ),
      1,
    );
    same(
      dimension + "-one-journal-only",
      await pg.scalar(
        `select to_jsonb(count(*)::int) from taskfold_private.automation_requests where request_id in(${
          inputs.map((input) => lit(input.request_id)).join(",")
        })`,
      ),
      1,
    );
    const count = await pg.scalar(
      dimension === "account"
        ? `select to_jsonb(requests) from taskfold_private.automation_account_usage where user_id=${
          lit(a)
        }`
        : `select to_jsonb(${
          dimension === "minute" ? "window_requests" : "day_requests"
        }) from taskfold_private.automation_keys where id=${lit(limited.id)}`,
    );
    same(
      dimension + "-counter-never-overshoots",
      count,
      dimension === "account" ? 2000 : dimension === "minute" ? 60 : 1000,
    );
  }
  same(
    "no-stranded-claims",
    await pg.scalar(
      "select to_jsonb(count(*)::int) from taskfold_private.automation_requests where applied_at is null",
    ),
    0,
  );
  summary.phase = "cleanup";
  await pg.raw(`delete from auth.users where id in(${lit(a)},${lit(b)})`);
  same(
    "synthetic-accounts-removed",
    await pg.scalar("select to_jsonb(count(*)::int) from auth.users"),
    0,
  );
  same(
    "owned-key-history-cascaded",
    await pg.scalar(
      "select to_jsonb(count(*)::int) from taskfold_private.automation_keys",
    ),
    0,
  );
} catch (error) {
  summary.failed = true;
  summary.failure = error instanceof assert.AssertionError
    ? error.message
    : "Real task concurrency fixture failed";
  summary.errorCode = error.code;
  process.exitCode = 1;
} finally {
  if (pg) summary.containerRemoved = await pg.close();
  summary.assertions = checks;
  if (output) {
    await writeFile(output, JSON.stringify(summary, null, 2) + "\n", {
      mode: 0o600,
    });
  }
  console.log(
    JSON.stringify({
      passed: !summary.failed,
      assertions: checks,
      containerRemoved: summary.containerRemoved,
      phase: summary.phase,
      summary: output,
    }),
  );
}
