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
  if(process.env.TASKFOLD_TEAM_REBASE_REGRESSION === '1') {
    const {loadTeamCompletionRebaseSchema,teamCompletionRebaseMigration}=await import('./team-completion-rebase-schema.mjs');
    await loadTeamCompletionRebaseSchema(pg.raw,{base:false});
    report.rebaseMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamCompletionRebaseMigration,import.meta.url))).digest('hex');
  }
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
  check('cancel defaults closed',(await cancel(b)).code,'PT503');
  await pg.raw('update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true');
  check('outsider cannot cancel',(await cancel(b,'outsider')).code,'42501');
  for(const role of ['anon','service_role'])check(role+' cannot cancel',(await cancel(b,'editor','complete',{role})).code,'42501');
  check('expired session cannot cancel',(await cancel(b,'editor','complete',{session:randomUUID()})).code,'28000');
  const before=await row(source.id),cancelled=ok('cancel unrecorded action',await cancel(b));
  check('durable cancelled state',cancelled.state,'cancelled');check('no fabricated completion receipt',cancelled.receipt,null);
  check('source unchanged',await row(source.id),before);check('next occurrence not created',await row(b.planned_next_id),null);
  check('no completion counters changed',(await row(source.id)).completion_version,0);
  check('nonce reserved in shared namespace',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_edits where team_id=${lit(team)} and request_id=${lit(b.request_id)}`),1);
  check('no completion receipt',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_completions where team_id=${lit(team)} and request_id=${lit(b.request_id)}`),0);
  check('cancel exact retry',ok('repeated cancellation',await cancel(b)),cancelled);
  check('cancel recoverable through read',ok('read durable cancellation',await review(b)),cancelled);
  const edit={team_id:team,project_id:project,task_id:source.id,task_generation:source.task_generation,request_id:b.request_id,base:{project_id:project,task_generation:source.task_generation,title:source.title},changes:{title:'Must not replace cancellation'}};
  check('ordinary edit cannot reuse cancelled nonce',(await run('editor',`public.taskfold_edit_team_task(${json(edit)})`)).code,'PT409');
  const deletion={team_id:team,project_id:project,task_id:source.id,task_generation:source.task_generation,request_id:b.request_id,record:source};
  check('lifecycle cannot reuse cancelled nonce',(await run('editor',`public.taskfold_team_task_lifecycle('delete',${json(deletion)})`)).code,'PT409');
  check('old completion cannot apply',(await rpc('complete',b)).code,'PT409');check('old completion preserves source',await row(source.id),before);check('old completion cannot clone',await row(b.planned_next_id),null);
  check('changed payload cannot inspect cancellation',(await review({...b,record:{...source,title:'Changed'}})).code,'PT409');
  check('changed payload cannot cancel same nonce',(await cancel({...b,completed_at:'2026-10-25T12:00:00Z'})).code,'PT409');
  check('another actor cannot cancel same nonce',(await cancel(b,'owner')).code,'PT409');
  const fixture={account:users.editor.id,body:b,cancelled};
  const completedBody=await body(await create()),done=ok('already completed setup',await rpc('complete',completedBody));
  const recorded=ok('cannot cancel recorded action',await cancel(completedBody));check('recorded action returned',recorded.state,'recorded');check('recorded receipt preserved',recorded.receipt,{...done,replayed:true});
  fixture.recorded_body=completedBody;fixture.recorded=recorded;
  const undo={...completedBody,request_id:randomUUID(),undoes:completedBody.request_id};
  const undoCancelled=ok('Undo cancellation',await cancel(undo,'editor','undo'));check('cancel pending Undo',undoCancelled.state,'cancelled');
  fixture.undo_body=undo;fixture.undo_cancelled=undoCancelled;
  check('cancelled Undo cannot reopen',(await rpc('undo',undo)).code,'PT409');check('completed root remains completed',(await row(completedBody.task_id)).completed,true);
  const fresh={...b,request_id:randomUUID(),next_generation:randomUUID()};ok('fresh intentional completion allowed',await rpc('complete',fresh));
  check('old cancelled request remains fenced',(await rpc('complete',b)).code,'PT409');
  check('fresh completion owns next',(await row(b.planned_next_id)).task_generation,fresh.next_generation);
  const viewerBody=await body(await create());
  check('viewer may cancel own unsent intent',ok('viewer cancellation',await cancel(viewerBody,'viewer')).project_role,'viewer');
  check('viewer cancellation is durable',(await review(viewerBody,'viewer')).value.state,'cancelled');
  await pg.raw('update taskfold_private.team_project_config set native_task_edits_enabled=false');
  const paused=await body(await create());check('edit pause permits own cancellation',ok('cancel with edits paused',await cancel(paused)).state,'cancelled');
  await pg.raw('update taskfold_private.team_project_config set native_task_edits_enabled=true,native_reads_enabled=false');
  check('read pause denies cancellation',(await cancel(await body(await create()))).code,'PT503');
  await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=true');
  const inFlight=await body(await create());
  let hold=await pg.hold(`set local role authenticated;set local request.jwt.claim.sub=${lit(users.editor.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:users.editor.id,session_id:users.editor.session}))};select public.taskfold_complete_team_task('complete',${json(inFlight)})`);
  let waiting=cancel(inFlight,'editor','complete',{app:'cancel-after-complete'});await pg.waitForLock('cancel-after-complete',hold.pid);await hold.release('commit');
  check('completion wins concurrent cancellation',ok('waited recorded result',await waiting).state,'recorded');
  const cancelFirst=await body(await create());
  hold=await pg.hold(`set local role authenticated;set local request.jwt.claim.sub=${lit(users.editor.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:users.editor.id,session_id:users.editor.session}))};select public.taskfold_cancel_team_completion('complete',${json(cancelFirst)})`);
  waiting=rpc('complete',cancelFirst,'editor',{app:'complete-after-cancel'});await pg.waitForLock('complete-after-cancel',hold.pid);await hold.release('commit');
  check('cancellation wins concurrent completion',(await waiting).code,'PT409');check('concurrent cancellation leaves root open',(await row(cancelFirst.task_id)).completed,false);check('no concurrent successor',await row(cancelFirst.planned_next_id),null);
  const interrupted=await body(await create());
  await pg.raw(`create function public.fixture_cancel_fail() returns trigger language plpgsql as $$begin raise exception 'Synthetic cancellation interruption';end$$;create trigger fixture_cancel_fail after insert on taskfold_private.team_task_completion_cancellations for each row execute function public.fixture_cancel_fail()`);
  check('interrupted cancellation fails',(await cancel(interrupted)).code,'P0001');
  check('interrupted cancellation rolls back nonce',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_edits where request_id=${lit(interrupted.request_id)}`),0);
  await pg.raw('drop trigger fixture_cancel_fail on taskfold_private.team_task_completion_cancellations;drop function public.fixture_cancel_fail()');
  ok('completion still allowed after failed cancellation',await rpc('complete',interrupted));
  const privacy=await body(await create());
  hold=await pg.hold(`select id from taskfold_private.teams where id=${lit(team)} for update`);
  waiting=cancel(privacy,'editor','complete',{app:'cancel-role-loss'});await pg.waitForLock('cancel-role-loss',hold.pid);await hold.release('commit',`update taskfold_private.team_content_projects set visibility='private' where project_id=${lit(project)}`);
  check('permission rechecked after wait',(await waiting).code,'42501');
  check('denied cancellation reserves nothing',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_edits where request_id=${lit(privacy.request_id)}`),0);
  await pg.raw(`update taskfold_private.team_content_projects set visibility='team' where project_id=${lit(project)}`);
  const removeActor=await body(await create());ok('actor removal setup',await cancel(removeActor,'viewer'));
  await pg.raw(`delete from auth.users where id=${lit(users.viewer.id)}`);
  check('actor removal purges cancellation',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_completion_cancellations where request_id=${lit(removeActor.request_id)}`),0);
  check('revoked actor cannot reuse request',(await rpc('complete',removeActor,'viewer')).code,'28000');
  check('private table has no client grants',await pg.scalar(`select to_jsonb(has_table_privilege('authenticated','taskfold_private.team_task_completion_cancellations','select,insert,update,delete'))`),false);
  check('private table has RLS',await pg.scalar(`select to_jsonb(relrowsecurity) from pg_class where oid='taskfold_private.team_task_completion_cancellations'::regclass`),true);
  check('no task scopes leaked',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_task_edit_scope'),0);
  await pg.raw(`update taskfold_private.teams set state='deleted',name=null,owner_id=null where id=${lit(team)}`);
  check('team deletion purges cancellations',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_completion_cancellations where team_id=${lit(team)}`),0);
  check('team deletion purges cancelled headers',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_edits where request_id in(${lit(b.request_id)},${lit(cancelFirst.request_id)},${lit(paused.request_id)})`),0);
  report.advisors=await pg.advisors();check('no new advisor warnings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
  report.containerRemoved=await pg.close();pg=null;report.checkCount=Object.keys(report.checks).length;
  if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');if(process.argv[3])await writeFile(process.argv[3],JSON.stringify(fixture,null,2)+'\n');
  console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
}finally{if(pg)await pg.close();}
