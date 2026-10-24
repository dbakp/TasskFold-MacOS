import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import {
  loadTeamCompletionSchema,
  teamCompletionMigration,
} from "./team-completion-schema.mjs";
const report = {
  checks: {},
  deployed: false,
  realDataChanged: false,
  nativeTeamUIEnabled: false,
};
const check = (name, a, b = true) => {
  assert.deepEqual(a, b, name);
  report.checks[name] = true;
};
const json = (x) => lit(JSON.stringify(x)) + "::jsonb";
const users = Object.fromEntries(
  ["owner", "editor", "viewer", "outsider"].map(
    (n) => [n, { id: randomUUID(), session: randomUUID() }],
  ),
);
const team = randomUUID(), project = randomUUID();
let pg;
try {
  pg = await createPostgresFixture({ advisors: true });
  await loadTeamCompletionSchema(pg.raw);
  {
    const { loadTeamCompletionReviewSchema,teamCompletionReviewMigration }=await import('./team-completion-review-schema.mjs');
    await loadTeamCompletionReviewSchema(pg.raw,{base:false});
    report.reviewMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamCompletionReviewMigration,import.meta.url))).digest('hex');
  }
  const {loadTeamCompletionCancellationSchema,teamCompletionCancellationMigration}=await import('./team-completion-cancellation-schema.mjs');
  await loadTeamCompletionCancellationSchema(pg.raw,{base:false});
  report.cancellationMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamCompletionCancellationMigration,import.meta.url))).digest('hex');
  const {loadTeamCompletionRebaseSchema,teamCompletionRebaseMigration}=await import('./team-completion-rebase-schema.mjs');
  await loadTeamCompletionRebaseSchema(pg.raw,{base:false});
  report.rebaseMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamCompletionRebaseMigration,import.meta.url))).digest('hex');
  if(process.env.TASKFOLD_TEAM_PROVISIONAL_REGRESSION === '1') {
    if(!report.rebaseMigrationSHA256)throw new Error('Load rebase capabilities before provisional retirement regression');
    const {loadTeamProvisionalRetirementSchema,teamProvisionalRetirementMigration}=await import('./team-provisional-retirement-schema.mjs');
    await loadTeamProvisionalRetirementSchema(pg.raw,{base:false});
    report.retirementMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamProvisionalRetirementMigration,import.meta.url))).digest('hex');
  }
  report.completionMigrationSHA256 = createHash("sha256").update(
    await readFile(
      new URL(
        "../../supabase/migrations/" + teamCompletionMigration,
        import.meta.url,
      ),
    ),
  ).digest("hex");
  for (const [n, u] of Object.entries(users)) {
    await pg.raw(
      `insert into auth.users(id,email,email_confirmed_at) values(${
        lit(u.id)
      },${
        lit(n + "@example.invalid")
      },now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${
        lit(u.id)
      })`,
    );
  }
  await pg.raw(
    `insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${
      lit(users.owner.id)
    },'Completion team');` + Object.entries(users).filter(([n]) =>
      n !== "outsider"
    ).map(([n, u]) =>
      `insert into taskfold_private.team_members(team_id,user_id,role) values(${
        lit(team)
      },${lit(u.id)},${lit(n === "owner" ? "admin" : "member")});`
    ).join(""),
  );
  await pg.raw(
    `insert into public.projects(id,user_id,name) values(${lit(project)},${
      lit(users.owner.id)
    },'Completion project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${
      lit(project)
    },${
      lit(team)
    },'team');insert into taskfold_private.team_project_grants values(${
      lit(project)
    },${lit(team)},${lit(users.viewer.id)},'viewer')`,
  );
  const run = (who, expression, opts = {}) => {
    const u = users[who];
    return pg.scalar(
      `begin;set application_name=${
        lit(opts.app ?? "completion-" + randomUUID().slice(0, 8))
      };create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated,anon,service_role;set local role ${
        opts.role ?? "authenticated"
      };set local request.jwt.claim.sub=${
        lit(u.id)
      };set local request.jwt.claims=${
        lit(
          JSON.stringify({
            sub: u.id,
            session_id: opts.session ?? u.session,
            ...opts.claims,
          }),
        )
      };do $r$begin begin insert into result values((${expression}),null,null);exception when others then insert into result values(null,sqlstate,left(sqlerrm,160));end;end$r$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`,
    );
  };
  const rpc = (action, b, who = "editor", opts = {}) =>
    run(
      who,
      `public.taskfold_complete_team_task(${lit(action)},${json(b)})`,
      opts,
    );
  const row = (id) =>
    pg.scalar(
      `select coalesce((select to_jsonb(t) from public.tasks t where id=${
        lit(id)
      }),'null')`,
    );
  const create = async (extra = {}) => {
    const r = {
      id: randomUUID(),
      user_id: users.owner.id,
      project_id: project,
      title: "Recurring team task",
      description: "Shared instructions",
      task_generation: randomUUID(),
      completed: false,
      completion_version: 0,
      created_at: "2026-10-24T00:00:00Z",
      priority: 2,
      due_date: "2026-10-24",
      due_time: "09:00",
      time_zone: "Europe/Copenhagen",
      is_recurring: true,
      recurrence_pattern: { type: "daily", interval: 1, count: 3 },
      ...extra,
    };
    await pg.raw(
      `insert into public.tasks select (jsonb_populate_record(null::public.tasks,${
        json({
          labels: [],
          subtasks: [],
          comments: [],
          attachments: [],
          reminders: [],
          reminder_specs: [],
          source_metadata: {},
          ...r,
        })
      })).*`,
    );
    return row(r.id);
  };
  const body = async (source, extra = {}) => {
    const clock = extra.completed_at ?? "2026-10-24T12:00:00Z",
      zone = extra.input_zone ?? "Europe/Copenhagen";
    const plan = await pg.scalar(
      `select coalesce(taskfold_private.automation_recurrence_plan(${
        json(source)
      },${lit(clock)}::timestamptz,${lit(zone)}),'null')`,
    );
    const series = plan
        ? (source.recurrence_parent_id ?? source.id)
        : source.id,
      parent = series === source.id ? source : await row(series);
    return {
      team_id: team,
      project_id: project,
      task_id: source.id,
      task_generation: source.task_generation,
      request_id: randomUUID(),
      record: source,
      completed_at: clock,
      input_zone: zone,
      next_generation: randomUUID(),
      planned_next_id: plan?.id ?? null,
      series_id: series,
      series_generation: parent.task_generation,
      series_project_id: parent.project_id,
      ...extra,
    };
  };
  const ok = (name, result) => {
    check(name, { code: result.code, reason: result.reason }, {
      code: null,
      reason: null,
    });
    return result.value;
  };
  const review=(b,who='editor',action='complete',opts={})=>run(who,`public.taskfold_review_team_completion(${lit(action)},${json(b)})`,opts);
  const cancel=(b,who='editor',action='complete',opts={})=>run(who,`public.taskfold_cancel_team_completion(${lit(action)},${json(b)})`,opts);
  const source=await create(),b=await body(source);
  check('default team reads closed',(await review(b)).code,'PT503');
  await pg.raw('update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true');
  check('editing defaults closed',ok('paused edit capabilities',await review(b)).can_edit_current,false);
  await pg.raw('update taskfold_private.team_project_config set native_task_edits_enabled=true');
  const current=await pg.scalar(`update public.tasks set title='Reviewed current title',description='Keep the current shared instructions',due_date='2026-10-26',recurrence_pattern='{"type":"daily","interval":2,"count":4}',source_metadata='{"future":{"keep":"server choice"}}',attachments='[{"id":"shared-file","url":"https://files.example.invalid/shared"}]' where id=${lit(source.id)} returning to_jsonb(tasks)`);
  check('old completion rejected',(await rpc('complete',b)).code,'PT409');
  const observation=ok('current version review',await review(b));check('current task editable',observation.can_edit_current,true);check('root series editable',observation.can_edit_series,true);
  check('current notes shown',observation.task.description,current.description);
  const cancelled=ok('cancel old completion before rebase',await cancel(b));check('old action durably cancelled',cancelled.state,'cancelled');
  const rebased=await body(current);const accepted=ok('new reviewed completion accepted',await rpc('complete',rebased));
  check('fresh request identity',rebased.request_id!==b.request_id);check('fresh successor generation',rebased.next_generation!==b.next_generation);
  check('original clock retained',rebased.completed_at,b.completed_at);check('current notes preserved',accepted.task.description,current.description);
  check('current repeat rule preserved',accepted.successor.recurrence_pattern.interval,2);check('new planned date uses current rule',accepted.successor.due_date,'2026-10-28');
  check('shared attachment retained',accepted.successor.attachments,current.attachments);check('opaque metadata retained',accepted.successor.source_metadata.future,current.source_metadata.future);
  check('new completion exact retry',ok('lost new response retry',await rpc('complete',rebased)),{...accepted,replayed:true});
  check('old request still fenced after rebase',(await rpc('complete',b)).code,'PT409');
  const fixture={account:users.editor.id,body:b,review:observation,cancelled,rebased_body:rebased,rebased_reply:accepted};
  const changed=await body(await create()),changedObservation=ok('second task review',await review(changed));
  const changedCancellation=ok('second task cancellation',await cancel(changed));
  await pg.raw(`update public.tasks set description='Changed again while reviewing' where id=${lit(changed.task_id)}`);
  const changedAgain=ok('changed observation refresh',await review(changed));
  check('changed current notes returned',changedAgain.task.description,'Changed again while reviewing');
  const staleRebase=await body(changedCancellation.task);
  check('stale rebase cannot overwrite latest task',(await rpc('complete',staleRebase)).code,'PT409');
  check('stale rebase leaves source open',(await row(changed.task_id)).completed,false);check('stale rebase leaves notes',(await row(changed.task_id)).description,'Changed again while reviewing');
  fixture.changed_body=changed;fixture.changed_review=changedObservation;fixture.changed_cancelled=changedCancellation;fixture.changed_again=changedAgain;
  const permission=await body(await create());
  check('viewer cannot rebase current',ok('viewer capability review',await review(permission,'viewer')).can_edit_current,false);
  await pg.raw(`update public.projects set is_archived=true where id=${lit(project)}`);
  check('archived project disables rebase',ok('archived capability review',await review(permission)).can_edit_current,false);
  await pg.raw(`update public.projects set is_archived=false where id=${lit(project)}`);
  check('active project restores capability',ok('unarchived capability review',await review(permission)).can_edit_current,true);
  const privateProject=randomUUID();
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(privateProject)},${lit(users.owner.id)},'Series project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(privateProject)},${lit(team)},'private');insert into taskfold_private.team_project_grants values(${lit(privateProject)},${lit(team)},${lit(users.editor.id)},'viewer')`);
  const parent=await create({project_id:privateProject,title:'Series parent'}),child=await create({recurrence_parent_id:parent.id}),childBody=await body(child);
  const parentViewer=ok('parent role independently checked',await review(childBody));check('child still editable',parentViewer.can_edit_current,true);check('viewer parent cannot authorize recurring completion',parentViewer.can_edit_series,false);
  await pg.raw(`update taskfold_private.team_project_grants set role='editor' where project_id=${lit(privateProject)} and user_id=${lit(users.editor.id)}`);
  check('editable parent authorizes series',ok('editable parent review',await review(childBody)).can_edit_series,true);
  await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(privateProject)} and user_id=${lit(users.editor.id)}`);
  const missingParent=ok('inaccessible parent review',await review(childBody));check('inaccessible parent hidden',missingParent.series,null);check('inaccessible parent cannot authorize series',missingParent.can_edit_series,false);
  fixture.parent_body=childBody;fixture.parent_viewer=parentViewer;fixture.parent_hidden=missingParent;
  const history=await body(await create());const completed=ok('Undo history setup',await rpc('complete',history));
  const undo={...history,request_id:randomUUID(),undoes:history.request_id};
  await pg.raw(`update public.tasks set completed=false,completed_at=null where id=${lit(history.task_id)};update public.tasks set completed=true,completed_at='2026-10-25T14:00:00Z',description='Newly completed shared version' where id=${lit(history.task_id)}`);
  check('old Undo rejected after completion cycle',(await rpc('undo',undo)).code,'PT409');
  const undoObservation=ok('current completion review',await review(undo,'editor','undo'));
  const undoCancellation=ok('cancel old Undo',await cancel(undo,'editor','undo'));
  const now=undoCancellation.task,reopen={team_id:team,project_id:project,task_id:now.id,task_generation:now.task_generation,request_id:randomUUID(),base:{task_generation:now.task_generation,completion_version:now.completion_version,project_id:project,completed:true,completed_at:now.completed_at},changes:{completed:false,completed_at:null}};
  const reopened=ok('explicit current reopen accepted',await run('editor',`public.taskfold_edit_team_task(${json(reopen)})`));
  check('current task reopened',reopened.task.completed,false);check('reopen preserves current notes',reopened.task.description,now.description);
  check('reopen keeps existing future',await row(history.planned_next_id),completed.successor);check('old Undo remains cancelled',(await rpc('undo',undo)).code,'PT409');
  check('reopen exact retry',ok('lost reopen response retry',await run('editor',`public.taskfold_edit_team_task(${json(reopen)})`)),{...reopened,replayed:true});
  fixture.undo_body=undo;fixture.undo_review=undoObservation;fixture.undo_cancelled=undoCancellation;fixture.reopen_body=reopen;fixture.reopen_reply=reopened;
  await pg.raw(`delete from public.tasks where id=${lit(permission.task_id)}`);
  const missing=ok('deleted source capability review',await review(permission));check('deleted source not editable',missing.can_edit_current,false);
  check('expired session cannot get capabilities',(await review(b,'editor','complete',{session:randomUUID()})).code,'28000');
  check('outsider cannot get capabilities',(await review(b,'outsider')).code,'42501');
  check('no task scopes leaked',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_task_edit_scope'),0);
  report.advisors=await pg.advisors();check('no new advisor warnings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
  report.containerRemoved=await pg.close();pg=null;report.checkCount=Object.keys(report.checks).length;
  if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');if(process.argv[3])await writeFile(process.argv[3],JSON.stringify(fixture,null,2)+'\n');
  console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
}finally{if(pg)await pg.close();}
