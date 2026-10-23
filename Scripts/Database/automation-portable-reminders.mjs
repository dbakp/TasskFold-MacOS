import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
// Called only after the actual complete candidate chain loads in the mutation runner.
export async function checkPortableReminders(db, account, id) {
  let checks = 0, sequence = 12000;
  const same = (a, b, label) => {
    assert.deepEqual(a, b, label);
    checks++;
  };
  const v = async (sql, args = []) =>
    Object.values((await db.query(sql, args)).rows[0])[0];
  const fixture = JSON.parse(
    await readFile(
      new URL(
        "../../TaskfoldTests/Fixtures/automation-reminder-validation.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  same(fixture.cases.length, 131, "Native oracle count");
  for (const row of fixture.cases) {
    same(
      await v(
        "select taskfold_private.automation_portable_reminder_kind($1::jsonb)",
        [JSON.stringify(row.spec)],
      ),
      row.expected,
      row.name,
    );
    // The real field validator accepts recognized schedules and refuses unsupported
    // new formats. UUID-invalid cases are also refused by the array identity guard.
    if (row.expected !== null) {
      await v(
        "select taskfold_private.automation_validate_fields($1::jsonb,'{}'::jsonb)",
        [JSON.stringify({ reminder_specs: [row.spec] })],
      );
      checks++;
    }
  }
  const key = id(28), hash = "8".repeat(64);
  await db.query(
    "insert into taskfold_private.automation_keys(id,user_id,name,token_hash,scopes,ttl_days,expires_at) values($1,$2,'Portable reminder fixture',$3,array['tasks:read','tasks:create','tasks:update','tasks:complete'],30,clock_timestamp()+interval '1 day')",
    [key, account, hash],
  );
  const write = (action, body) =>
    v("select public.taskfold_automation_write($1,$2,$3,$4::jsonb)", [
      key,
      hash,
      action,
      JSON.stringify({ request_id: id(sequence++), time_zone: "UTC", ...body }),
    ]);
  const get = (target) =>
    v("select public.taskfold_automation_read($1,$2,'get',$3::jsonb)", [
      key,
      hash,
      JSON.stringify({ id: target }),
    ]).then((r) => r.task);
  async function refuses(code, work) {
    let failed = false;
    try {
      await work();
    } catch (e) {
      same(e.code, code, e.message);
      failed = true;
    }
    same(failed, true, "Expected refusal");
  }
  const spec = (name) =>
    structuredClone(fixture.cases.find((r) => r.name === name).spec);
  const target = id(401), generation = id(10401);
  const rows = [
    "daily",
    "interval-normal",
    "holiday-move",
    "calendar-sensitive",
    "absolute-base",
  ].map((name, i) => ({ ...spec(name), id: id(14000 + i) }));
  await write("create", {
    id: target,
    task_generation: generation,
    fields: {
      title: "Synthetic portable schedules",
      due_date: "2026-10-23",
      is_recurring: true,
      recurrence_pattern: { type: "daily" },
      reminder_specs: rows,
      subtasks: [{
        id: id(18000),
        title: "Synthetic child reminders",
        reminder_specs: rows,
      }],
    },
  });
  let current = await get(target);
  same(
    current.reminder_specs,
    rows,
    "All portable formats survive actual create",
  );
  const changed = structuredClone(rows);
  changed[1].interval_schedule.every_minutes = 30;
  changed[2].holiday_policy.mode = "skip";
  changed[3].presentation = "time-sensitive";
  await write("update", {
    id: target,
    task_generation: generation,
    base: current,
    fields: { reminder_specs: changed },
  });
  current = await get(target);
  same(
    current.reminder_specs,
    changed,
    "Advanced edit is not preservation-only",
  );
  const stale = current;
  const newer = structuredClone(changed);
  newer[0].time = "10:00";
  await write("update", {
    id: target,
    task_generation: generation,
    base: current,
    fields: { reminder_specs: newer },
  });
  await refuses(
    "PT409",
    () =>
      write("update", {
        id: target,
        task_generation: generation,
        base: stale,
        fields: {
          reminder_specs: changed.map((r, i) =>
            i === 0 ? { ...r, time: "11:00" } : r
          ),
        },
      }),
  );
  current = await get(target);
  same(
    current.reminder_specs,
    newer,
    "Stale advanced edit cannot overwrite current schedule",
  );
  await write("update", {
    id: target,
    task_generation: generation,
    base: stale,
    fields: {
      reminder_specs: changed.map((r, i) =>
        i === 0 ? { ...r, enabled: false } : r
      ),
    },
  });
  newer[0].enabled = false;
  current = await get(target);
  same(
    current.reminder_specs,
    newer,
    "A disjoint stale enable edit preserves the newer clock",
  );
  const completed = await write("complete", {
    id: target,
    task_generation: generation,
    base: current,
  });
  same(
    typeof completed.receipt.successor_id,
    "string",
    "Task recurrence still creates its normal successor",
  );
  const successor = await get(completed.receipt.successor_id);
  same(
    successor.subtasks[0].reminder_specs,
    rows.slice(0, -1),
    "Child advanced schedules retain their own settings on successor",
  );
  same(
    successor.reminder_specs,
    newer.slice(0, -1),
    "Independent calendar/interval/holiday/wrapper survive; fixed absolute drops",
  );
  // A supported reminder can be deliberately removed. Future/private rows cannot.
  await write("update", {
    id: successor.id,
    task_generation: successor.task_generation,
    base: successor,
    fields: { reminder_specs: [] },
  });
  same(
    (await get(successor.id)).reminder_specs,
    [],
    "Portable schedules can be removed explicitly",
  );
  const future = {
    id: id(15001),
    version: 99,
    kind: "future",
    channels: ["local"],
    enabled: true,
    opaque: { retain: true },
  };
  const privateRow = {
    id: id(15002),
    version: 7,
    kind: "location",
    channels: ["local"],
    enabled: true,
    location_reference: {
      version: 2,
      device: id(15003),
      task_id: successor.id,
      task_generation: successor.task_generation,
      place_id: id(15004),
      place_revision: id(15005),
      arm: id(15006),
      transition: "arrive",
      repeats: true,
    },
  };
  await db.query(
    "update public.tasks set reminder_specs=$1::jsonb where id=$2",
    [JSON.stringify([future, privateRow]), successor.id],
  );
  let protectedTask = await get(successor.id);
  await write("update", {
    id: successor.id,
    task_generation: successor.task_generation,
    base: protectedTask,
    fields: { reminder_specs: [future, privateRow, rows[1]] },
  });
  protectedTask = await get(successor.id);
  same(
    protectedTask.reminder_specs,
    [future, privateRow, rows[1]],
    "Unknown/private rows preserved exactly alongside new portable schedule",
  );
  for (
    const replacement of [[rows[1]], [
      { ...future, enabled: false },
      privateRow,
      rows[1],
    ], [future, { ...privateRow, enabled: false }, rows[1]]]
  ) {
    await refuses(
      "22023",
      () =>
        write("update", {
          id: successor.id,
          task_generation: successor.task_generation,
          base: protectedTask,
          fields: { reminder_specs: replacement },
        }),
    );
  }
  same(
    (await get(successor.id)).reminder_specs,
    protectedTask.reminder_specs,
    "No private or future mutation",
  );
  const withExtensions = {
    ...rows[0],
    future_row: { preserve: true },
    recurrence: { ...rows[0].recurrence, future_rule: { preserve: true } },
  };
  const extensionTarget = id(402), extensionGeneration = id(10402);
  await write("create", {
    id: extensionTarget,
    task_generation: extensionGeneration,
    fields: {
      title: "Synthetic reminder extensions",
      reminder_specs: [withExtensions],
    },
  });
  const extensionTask = await get(extensionTarget);
  await refuses(
    "22023",
    () =>
      write("update", {
        id: extensionTarget,
        task_generation: extensionGeneration,
        base: extensionTask,
        fields: { reminder_specs: [{ ...rows[0], time: "11:00" }] },
      }),
  );
  await write("update", {
    id: extensionTarget,
    task_generation: extensionGeneration,
    base: extensionTask,
    fields: { reminder_specs: [{ ...withExtensions, time: "11:00" }] },
  });
  same((await get(extensionTarget)).reminder_specs[0], {
    ...withExtensions,
    time: "11:00",
  }, "Row and nested extensions survive known setting edit");
  for (const opaque of [privateRow, future]) {
    await refuses(
      "22023",
      () =>
        write("create", {
          id: id(19000 + sequence),
          task_generation: id(19500 + sequence),
          fields: { title: "Invalid fixture", reminder_specs: [opaque] },
        }),
    );
  }
  const before = await v(
    "select day_requests from taskfold_private.automation_keys where id=$1",
    [key],
  );
  for (
    const name of [
      "count-over",
      "interval-step-low",
      "holiday-duplicate",
      "wrapped-nesting",
      "skipped-day",
    ]
  ) {
    await refuses(
      "22023",
      () =>
        write("create", {
          id: id(16000 + sequence),
          task_generation: id(17000 + sequence),
          fields: { title: "Invalid fixture", reminder_specs: [spec(name)] },
        }),
    );
  }
  same(
    await v(
      "select day_requests from taskfold_private.automation_keys where id=$1",
      [key],
    ),
    before,
    "Invalid schedules roll back quota",
  );
  same(
    await v(
      "select count(*)::int from public.tasks where title='Invalid fixture'",
    ),
    0,
    "Invalid schedules leave no task",
  );
  for (const role of ["anon", "authenticated", "service_role"]) {
    same(
      await v(
        "select has_function_privilege($1,'taskfold_private.automation_portable_reminder_kind(jsonb)','EXECUTE')",
        [role],
      ),
      false,
      "Pure validator remains private",
    );
  }
  return { checks, goldenCases: fixture.cases.length };
}
