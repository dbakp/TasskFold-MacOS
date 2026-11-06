import { randomUUID } from "node:crypto";

// Invoked only by the branch-guarded hosted runner after its real Auth/CRUD cases.
// The service-only fixture injects waits; production RPC bodies remain unchanged.
export async function checkHostedDeadlines(
  {
    request,
    manage,
    task,
    sendWithAbort,
    service,
    account,
    token,
    taskSecret,
    credential,
    check,
    receipt,
  },
) {
  const rpc = (name, body) =>
    request("/rest/v1/rpc/" + name, service, body, "POST", service);
  const state = (id, requestID = null) =>
    rpc("taskfold_acceptance_deadline_state", { _id: id, _request: requestID })
      .then((r) => {
        if (r.status !== 200) throw Error("Deadline state observation failed");
        return r.value;
      });
  let controlStep = 0;
  const control = async (id, kind, seconds) => {
    const r = await rpc("taskfold_acceptance_deadline_control", {
      _id: id,
      _account: account,
      _kind: kind,
      _seconds: seconds,
    });
    check(
      "deadline-control-" + (++controlStep) + "-" + kind + "-" + seconds,
      r.status === 200 && r.value?.ready === true,
    );
  };
  async function observe(id, predicate, requestID = null, maximum = 12000) {
    const end = Date.now() + maximum;
    do {
      const value = await state(id, requestID);
      if (predicate(value)) return value;
      await new Promise((resolve) => setTimeout(resolve, 150));
    } while (Date.now() < end);
    throw Error("Deadline fixture did not reach its observed state");
  }
  const timing = {};
  receipt.deadlines = timing;

  const lockKey = credential(["tasks:read"]), holder = randomUUID();
  const hold = rpc("taskfold_acceptance_deadline_hold", {
    _id: holder,
    _account: account,
  });
  try {
    await observe(holder, (s) => s.holder);
    const start = Date.now();
    const pending = manage(token, "create", lockKey.body);
    await observe(holder, (s) => s.blocked > 0);
    check("management-observed-actual-blocker", true);
    const result = await pending;
    timing.managementLockMS = Date.now() - start;
    check(
      "management-lock-times-out",
      result.status === 503 && timing.managementLockMS >= 2500 &&
        timing.managementLockMS < 7000,
    );
    check("management-lock-retry-hint", result.retry === "1");
    check(
      "management-lock-preserves-key-id",
      result.value?.error?.includes("same key ID"),
    );
    check("management-lock-no-key", (await state(lockKey.id)).keys === 0);
  } finally {
    const released = await hold;
    check(
      "owned-lock-holder-released",
      released.status === 200 && released.value?.released === true,
    );
  }
  check(
    "management-lock-exact-retry",
    (await manage(token, "create", lockKey.body)).value?.key?.id === lockKey.id,
  );
  check("management-lock-single-key", (await state(lockKey.id)).keys === 1);

  const slow = credential(["tasks:read"]);
  await control(slow.id, "keys", 12);
  const claims = JSON.parse(
    Buffer.from(token.split(".")[1], "base64url").toString("utf8"),
  );
  let start = Date.now();
  const direct = await rpc("taskfold_automation_keys", {
    _account: account,
    _session: claims.session_id,
    _action: "create",
    _body: slow.body,
  });
  timing.directStatementMS = Date.now() - start;
  timing.statementSQLState = direct.value?.code;
  check(
    "postgrest-hoists-management-deadline",
    direct.value?.code === "57014" && timing.directStatementMS >= 9000 &&
      timing.directStatementMS < 12000,
  );
  check("statement-timeout-rolls-back-key", (await state(slow.id)).keys === 0);
  start = Date.now();
  const edge = await manage(token, "create", slow.body);
  timing.edgeStatementMS = Date.now() - start;
  check(
    "edge-handles-real-statement-timeout",
    edge.status === 503 && edge.retry === "1" && edge.cache === "no-store",
  );
  check(
    "edge-timeout-keeps-retry-identity",
    edge.value?.error?.includes("same key ID"),
  );
  check("edge-statement-no-key", (await state(slow.id)).keys === 0);
  await control(slow.id, "keys", 0);
  check(
    "statement-timeout-exact-retry",
    (await manage(token, "create", slow.body)).value?.key?.id === slow.id,
  );
  check("statement-timeout-single-key", (await state(slow.id)).keys === 1);

  const interrupted = credential(["tasks:read"]);
  await control(interrupted.id, "keys", 4);
  const keyAbort = new AbortController();
  const keyPending = sendWithAbort(
    "keys",
    token,
    "create",
    interrupted.body,
    keyAbort.signal,
  )
    .then(() => false, (error) => error.name === "AbortError");
  await observe(interrupted.id, (s) => s.inserting);
  start = Date.now();
  keyAbort.abort();
  check("native-management-client-disconnected", await keyPending);
  const keySettled = await observe(interrupted.id, (s) => !s.inserting);
  timing.managementDisconnectSettledMS = Date.now() - start;
  timing.managementRowsAfterDisconnect = keySettled.keys;
  check(
    "management-disconnect-bounded",
    timing.managementDisconnectSettledMS < 12000 &&
      [0, 1].includes(keySettled.keys),
  );
  await control(interrupted.id, "keys", 0);
  check(
    "management-disconnect-exact-retry",
    (await manage(token, "create", interrupted.body)).value?.key?.id ===
      interrupted.id,
  );
  check(
    "management-disconnect-one-key",
    (await state(interrupted.id)).keys === 1,
  );

  const timedTask = randomUUID(),
    timedGeneration = randomUUID(),
    timedIntent = randomUUID();
  const timedCreate = {
    id: timedTask,
    task_generation: timedGeneration,
    request_id: timedIntent,
    time_zone: "UTC",
    fields: { title: "Timed hosted synthetic task" },
  };
  await control(timedTask, "tasks", 12);
  start = Date.now();
  const timedResult = await task(taskSecret, "create", timedCreate);
  timing.taskStatementMS = Date.now() - start;
  check(
    "task-postgrest-deadline-and-retry",
    timedResult.status === 503 && timedResult.retry === "1" &&
      timedResult.cache === "no-store" && timing.taskStatementMS >= 9000 &&
      timing.taskStatementMS < 12000,
  );
  check(
    "task-timeout-preserves-request-id",
    timedResult.value?.error?.includes("same request ID"),
  );
  const timedState = await state(timedTask, timedIntent);
  check(
    "task-timeout-rolls-back-task-and-journal",
    timedState.tasks === 0 && timedState.journal === 0,
  );
  await control(timedTask, "tasks", 0);
  check(
    "task-timeout-exact-retry",
    (await task(taskSecret, "create", timedCreate)).value?.receipt?.task_id ===
      timedTask,
  );
  const timedAfter = await state(timedTask, timedIntent);
  check(
    "task-timeout-single-effect-and-journal",
    timedAfter.tasks === 1 && timedAfter.journal === 1,
  );
  const timedRead = await task(taskSecret, "get", { id: timedTask });
  check(
    "task-timeout-delete-reviewed",
    (await task(taskSecret, "delete", {
      id: timedTask,
      task_generation: timedGeneration,
      request_id: randomUUID(),
      time_zone: "UTC",
      revision: timedRead.value.task.revision,
      descendants: [],
    })).value?.receipt?.deleted === true,
  );

  const target = randomUUID(), generation = randomUUID(), intent = randomUUID();
  const create = {
    id: target,
    task_generation: generation,
    request_id: intent,
    time_zone: "UTC",
    fields: { title: "Interrupted hosted synthetic task" },
  };
  await control(target, "tasks", 4);
  const taskAbort = new AbortController();
  const taskPending = sendWithAbort(
    "tasks",
    taskSecret,
    "create",
    create,
    taskAbort.signal,
  )
    .then(() => false, (error) => error.name === "AbortError");
  await observe(target, (s) => s.inserting, intent);
  start = Date.now();
  taskAbort.abort();
  check("task-client-disconnected", await taskPending);
  const taskSettled = await observe(target, (s) => !s.inserting, intent);
  timing.taskDisconnectSettledMS = Date.now() - start;
  timing.taskRowsAfterDisconnect = taskSettled.tasks;
  check(
    "task-disconnect-bounded",
    timing.taskDisconnectSettledMS < 12000 &&
      [0, 1].includes(taskSettled.tasks),
  );
  await control(target, "tasks", 0);
  const replay = await task(taskSecret, "create", create);
  check(
    "task-disconnect-exact-request-retry",
    replay.status === 200 && replay.value?.receipt?.task_id === target,
  );
  const after = await state(target, intent);
  check(
    "task-disconnect-single-effect-and-journal",
    after.tasks === 1 && after.journal === 1,
  );
  const read = await task(taskSecret, "get", { id: target });
  check(
    "task-disconnect-delete-reviewed",
    (await task(taskSecret, "delete", {
      id: target,
      task_generation: generation,
      request_id: randomUUID(),
      time_zone: "UTC",
      revision: read.value.task.revision,
      descendants: [],
    })).value?.receipt?.deleted === true,
  );
}
