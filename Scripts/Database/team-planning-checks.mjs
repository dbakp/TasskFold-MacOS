import { randomUUID } from "node:crypto";
import { literal as lit } from "./postgres-fixture.mjs";
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
export async function checkTeamPlanning(
  { pg, check, rpc, row, body, people, team, project, hidden, task },
) {
  const section = randomUUID(), other = randomUUID();
  await pg.raw(
    `insert into public.sections(id,project_id,name,user_id) values(${
      lit(section)
    },${lit(project)},'Review',${lit(people.owner.id)}),(${lit(other)},${
      lit(hidden)
    },'Private',${lit(people.owner.id)})`,
  );
  const reminder = {
    id: randomUUID(),
    version: 1,
    kind: "relative",
    anchor: "planned",
    offset_minutes: -15,
    channels: ["local"],
    future_choice: { retain: true },
  };
  const changes = {
    assigned_to: people.editor.id,
    section_id: section,
    labels: ["Design", "Review"],
    reminder_specs: [reminder],
  };
  const draft = await body(changes),
    before = await row(),
    saved = await rpc("editor", draft);
  check("planning four fields saved", saved.code, null);
  for (const [key, value] of Object.entries(changes)) {
    check("planning saved " + key, saved.value?.task[key], value);
  }
  const fixture = {
    body: draft,
    reply: saved.value,
    before,
    account: people.editor.id,
  };
  const later = await body({ labels: ["Newer label"] });
  check("planning later edit saved", (await rpc("editor", later)).code, null);
  const replay = await rpc("editor", draft);
  check("planning replay receipt", replay.value?.replayed, true);
  check("planning replay preserves newer labels", replay.value?.task.labels, [
    "Newer label",
  ]);
  const denied = async (name, fields, code = "22023") => {
    const before = await row();
    check(
      "planning " + name,
      (await rpc("editor", await body(fields))).code,
      code,
    );
    check("planning " + name + " leaves task intact", await row(), before);
  };
  for (const who of ["viewer", "guest", "outsider"]) {
    await denied(
      who + " cannot be assignee",
      { assigned_to: people[who].id },
      "42501",
    );
  }
  await denied("missing assignee", { assigned_to: randomUUID() }, "42501");
  await denied("malformed assignee", { assigned_to: "not-a-uuid" });
  await denied("foreign section", { section_id: other }, "PT409");
  await denied("missing section", { section_id: randomUUID() }, "PT409");
  await denied("malformed section", { section_id: { id: section } });
  await denied("invalid labels", { labels: ["Valid", null] });
  await denied("oversized label", { labels: ["x".repeat(1025)] });
  await denied("too many labels", {
    labels: Array.from({ length: 257 }, (_, i) => "label" + i),
  });
  await denied("duplicate reminder identity", {
    reminder_specs: [reminder, reminder],
  });
  await denied("private reminder insertion", {
    reminder_specs: [reminder, {
      id: randomUUID(),
      version: 99,
      private_place: "never upload",
    }],
  });
  await denied("reminder extension removed", {
    reminder_specs: [Object.fromEntries(
      Object.entries(reminder).filter(([k]) => k !== "future_choice"),
    )],
  });
  const opaque = {
    id: randomUUID(),
    version: 99,
    kind: "private-device-setting",
    opaque: { keep: true },
  };
  await pg.raw(
    `update public.tasks set reminder_specs=${
      json([reminder, opaque])
    } where id=${lit(task)}`,
  );
  await denied("opaque reminder removal", { reminder_specs: [reminder] });
  const changedReminder = { ...reminder, offset_minutes: -30 };
  check(
    "planning opaque reminder preserved during portable edit",
    (await rpc(
      "editor",
      await body({ reminder_specs: [changedReminder, opaque] }),
    )).code,
    null,
  );
  check(
    "planning opaque reminder unchanged",
    (await row()).reminder_specs.find((x) => x.id === opaque.id),
    opaque,
  );
  // A stale baseline must not drop a private row that arrived after the draft.
  const stale = await body({
    reminder_specs: [{ ...changedReminder, offset_minutes: -45 }, opaque],
  });
  const newOpaque = { id: randomUUID(), version: 101, opaque: "arrived later" };
  await pg.raw(
    `update public.tasks set reminder_specs=${
      json([changedReminder, opaque, newOpaque])
    } where id=${lit(task)}`,
  );
  const concurrent = await rpc("editor", stale);
  check("planning concurrent opaque row retained", concurrent.code, null);
  check(
    "planning concurrent opaque value unchanged",
    concurrent.value?.task.reminder_specs.find((x) => x.id === newOpaque.id),
    newOpaque,
  );
  check(
    "planning same nonce changed payload rejected",
    (await rpc("editor", {
      ...draft,
      changes: { ...changes, labels: ["Forged retry"] },
    })).code,
    "PT409",
  );
  check(
    "planning viewer cannot write fields",
    (await rpc("viewer", await body({ labels: ["No"] }))).code,
    "42501",
  );
  // Clear then restore with new nonces, matching native Undo/Redo semantics.
  const clear = await body({ assigned_to: null, section_id: null, labels: [] });
  check(
    "planning nullable references clear",
    (await rpc("editor", clear)).code,
    null,
  );
  const restore = await body({
    assigned_to: people.editor.id,
    section_id: section,
    labels: ["Design"],
  });
  check(
    "planning reviewed inverse restores references",
    (await rpc("editor", restore)).code,
    null,
  );
  const staleSection = await body({ section_id: null });
  await pg.raw(`update public.tasks set section_id=null where id=${lit(task)}`);
  // Same final value is idempotent; a third section value is a real conflict.
  check(
    "planning same final section accepted",
    (await rpc("editor", staleSection)).code,
    null,
  );
  const third = randomUUID();
  await pg.raw(
    `insert into public.sections(id,project_id,name,user_id) values(${
      lit(third)
    },${lit(project)},'Third',${lit(people.owner.id)})`,
  );
  const conflict = await body({ section_id: section });
  await pg.raw(
    `update public.tasks set section_id=${lit(third)} where id=${lit(task)}`,
  );
  check(
    "planning concurrent section move conflicts",
    (await rpc("editor", conflict)).code,
    "P0001",
  );
  // Wait on the section itself, then recheck its project after a concurrent move.
  let sectionHolder = await pg.hold(
    `select id from public.sections where id=${lit(section)} for update`,
  );
  const sectionMove = rpc("editor", await body({ section_id: section }), {
    app: "team-planning-section-project-wait",
  });
  await pg.waitForLock("team-planning-section-project-wait", sectionHolder.pid);
  await sectionHolder.release(
    "commit",
    `update public.sections set project_id=${lit(hidden)} where id=${
      lit(section)
    }`,
  );
  check(
    "planning section moved project while waiting rejected",
    (await sectionMove).code,
    "PT409",
  );
  await pg.raw(
    `update public.sections set project_id=${lit(project)} where id=${
      lit(section)
    }`,
  );
  let holder = await pg.hold(
    `select id from taskfold_private.teams where id=${lit(team)} for update`,
  );
  const moving = await body({ section_id: section });
  const pending = rpc("editor", moving, { app: "team-planning-section-wait" });
  await pg.waitForLock("team-planning-section-wait", holder.pid);
  await holder.release(
    "commit",
    `delete from public.sections where id=${lit(section)}`,
  );
  check(
    "planning section removed while waiting rejected",
    (await pending).code,
    "PT409",
  );
  holder = await pg.hold(
    `select id from taskfold_private.teams where id=${lit(team)} for update`,
  );
  const assign = await body({ assigned_to: people.owner.id });
  const assignment = rpc("editor", assign, { app: "team-planning-role-wait" });
  await pg.waitForLock("team-planning-role-wait", holder.pid);
  // Owner cannot be demoted by project grants; use a disposable non-owner recipient.
  await holder.release();
  check(
    "planning live owner assignment after wait",
    (await assignment).code,
    null,
  );
  const target = randomUUID();
  await pg.raw(
    `insert into auth.users(id,email,email_confirmed_at) values(${
      lit(target)
    },'recipient@example.invalid',now());insert into taskfold_private.team_members(team_id,user_id,role) values(${
      lit(team)
    },${lit(target)},'member')`,
  );
  holder = await pg.hold(
    `select id from taskfold_private.teams where id=${lit(team)} for update`,
  );
  const revoked = rpc("editor", await body({ assigned_to: target }), {
    app: "team-planning-recipient-revoke",
  });
  await pg.waitForLock("team-planning-recipient-revoke", holder.pid);
  await holder.release(
    "commit",
    `insert into taskfold_private.team_project_grants values(${lit(project)},${
      lit(team)
    },${lit(target)},'viewer')`,
  );
  check(
    "planning recipient demoted while waiting denied",
    (await revoked).code,
    "42501",
  );
  await pg.raw(
    `delete from taskfold_private.team_project_grants where user_id=${
      lit(target)
    }`,
  );
  const targetIntent = await body({ assigned_to: target });
  check(
    "planning current recipient assignable",
    (await rpc("editor", targetIntent)).code,
    null,
  );
  await pg.raw(
    `update public.tasks set assigned_to=null where id=${
      lit(task)
    };update auth.users set banned_until=now()+interval '1 day' where id=${
      lit(target)
    }`,
  );
  const afterBan = await rpc("editor", targetIntent);
  check(
    "planning applied retry acknowledges after recipient ban",
    afterBan.code,
    null,
  );
  check(
    "planning applied retry remains replay",
    afterBan.value?.replayed,
    true,
  );
  check(
    "planning applied retry cannot reassign banned recipient",
    afterBan.value?.task.assigned_to,
    null,
  );
  await denied("banned recipient", { assigned_to: target }, "42501");
  await pg.raw(
    `update public.tasks set labels=array[]::text[] where id=${lit(task)}`,
  );
  const bounded = await body({
    labels: Array.from({ length: 130 }, (_, i) => "local-" + i),
  });
  await pg.raw(
    `update public.tasks set labels=array[${
      Array.from({ length: 130 }, (_, i) => lit("remote-" + i)).join(",")
    }] where id=${lit(task)}`,
  );
  const mergedBound = await rpc("editor", bounded);
  check(
    "planning concurrent label replacement requires review",
    mergedBound.code,
    "P0001",
  );
  check(
    "planning rejected oversized merge preserves remote labels",
    (await row()).labels.length,
    130,
  );
  const oldSpecs = (await row()).reminder_specs;
  const additions = () =>
    Array.from(
      { length: 9 },
      () => ({
        id: randomUUID(),
        version: 1,
        kind: "relative",
        anchor: "planned",
        offset_minutes: -5,
        channels: ["local"],
      }),
    );
  const boundedReminders = await body({
    reminder_specs: [...oldSpecs, ...additions()],
  });
  const remoteReminders = [...oldSpecs, ...additions()];
  await pg.raw(
    `update public.tasks set reminder_specs=${json(remoteReminders)} where id=${
      lit(task)
    }`,
  );
  check(
    "planning merged reminder bound checked",
    (await rpc("editor", boundedReminders)).code,
    "22023",
  );
  check(
    "planning rejected oversized merge preserves remote reminders",
    (await row()).reminder_specs,
    remoteReminders,
  );
  check(
    "planning operation scope cleaned",
    await pg.scalar(
      "select to_jsonb(count(*)) from taskfold_private.team_task_edit_scope",
    ),
    0,
  );
  return fixture;
}
