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
  if(process.env.TASKFOLD_TEAM_CANCELLATION_REGRESSION === '1' || process.env.TASKFOLD_TEAM_REBASE_REGRESSION === '1') {
    const {loadTeamCompletionCancellationSchema,teamCompletionCancellationMigration}=await import('./team-completion-cancellation-schema.mjs');
    await loadTeamCompletionCancellationSchema(pg.raw,{base:false});
    report.cancellationMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamCompletionCancellationMigration,import.meta.url))).digest('hex');
  }
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
  const source=await create();const b=await body(source);
  check('defaults closed',(await review(b)).code,'PT503');
  await pg.raw('update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true');
  const unrecorded=ok('unrecorded observation',await review(b));
  check('absence is explicit',unrecorded.state,'unrecorded');check('no fabricated receipt',unrecorded.receipt,null);
  check('read does not complete source',(await row(source.id)).completed,false);
  check('read does not create successor',await row(b.planned_next_id),null);
  check('read does not reserve nonce',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_edits where request_id=${lit(b.request_id)}`),0);
  check('viewer can read current source',ok('viewer review',await review(b,'viewer')).task.id,source.id);
  check('outsider denied',(await review(b,'outsider')).code,'42501');
  check('expired session denied',(await review(b,'editor','complete',{session:randomUUID()})).code,'28000');
  for(const role of ['anon','service_role'])check(role+' denied',(await review(b,'editor','complete',{role})).code,'42501');
  check('wrong team denied',(await review({...b,team_id:randomUUID()})).code,'PT404');
  check('unknown envelope denied',(await review({...b,extra:true})).code,'22023');
  check('wrong source identity denied',(await review({...b,record:{...source,id:randomUUID()}})).code,'22023');
  const completed=ok('complete after harmless read',await rpc('complete',b));
  const recorded=ok('recorded observation',await review(b));
  check('recorded state',recorded.state,'recorded');check('receipt exact replay',recorded.receipt,{...completed,replayed:true});
  check('coherent source row',recorded.task,recorded.receipt.task);check('coherent next row',recorded.successor,recorded.receipt.successor);
  const fixture={account:users.editor.id,body:b,unrecorded,recorded,completion:completed};
  const historySource=await create(),historyBody=await body(historySource);
  ok('history completion setup',await rpc('complete',historyBody));
  const undoBody={...historyBody,request_id:randomUUID(),undoes:historyBody.request_id};
  const undoResult=ok('Undo before review',await rpc('undo',undoBody));
  const undoReview=ok('recorded Undo review',await review(undoBody,'editor','undo'));
  check('Undo receipt exact replay',undoReview.receipt,{...undoResult,replayed:true});
  check('Undo review source stays open',undoReview.task.completed,false);check('Undo review does not recreate successor',undoReview.successor,null);
  fixture.undo_body=undoBody;fixture.undo_review=undoReview;
  const plain=await body(await create({is_recurring:false,recurrence_pattern:null}));
  check('nonrecurring review has no successor',ok('nonrecurring review',await review(plain)).successor,null);
  const bigSource=await create(),bigBody=await body(bigSource);ok('large review setup',await rpc('complete',bigBody));
  await pg.raw(`update public.tasks set description=repeat('x',510000) where id=${lit(bigSource.id)}`);
  check('bounded outgoing review',(await review(bigBody)).code,'54000');
  for(const [label,change] of [['clock',{completed_at:'2026-10-25T12:00:00Z'}],['baseline',{record:{...source,title:'Forged'}}],['generation',{next_generation:randomUUID()}]])check(label+' cannot inspect another command',(await review({...b,...change})).code,'PT409');
  check('another actor cannot inspect receipt',(await review(b,'owner')).code,'PT409');
  await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer')`);
  const down=ok('downgraded actor can review own receipt',await review(b));check('current role returned',down.project_role,'viewer');
  check('downgrade cannot retry complete',(await rpc('complete',b)).code,'42501');
  await pg.raw('update taskfold_private.team_project_config set native_task_edits_enabled=false');
  check('read survives edit pause',ok('read with edits off',await review(b)).state,'recorded');
  await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=false');
  check('native read pause denies recorded',(await review(b)).code,'PT503');
  await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true');
  await pg.raw(`update public.projects set is_archived=true where id=${lit(project)}`);
  check('archived source still reviewable',ok('archive review',await review(b)).task.id,source.id);
  await pg.raw(`update public.projects set is_archived=false where id=${lit(project)};delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(users.editor.id)}`);
  const originalNext=await row(b.planned_next_id);
  await pg.raw(`update public.tasks set title='Current collaborator title' where id=${lit(b.planned_next_id)}`);
  check('review returns current successor',ok('updated successor review',await review(b)).successor.title,'Current collaborator title');
  await pg.raw(`delete from public.tasks where id=${lit(b.planned_next_id)}`);
  check('deleted successor not resurrected',ok('removed successor review',await review(b)).successor,null);
  await pg.raw(`insert into public.tasks select (jsonb_populate_record(null::public.tasks,${json({...originalNext,task_generation:randomUUID(),title:'Replacement content'})})).*`);
  check('replacement generation hidden',ok('replacement review',await review(b)).successor,null);
  const freshBody=await body(await create());
  await pg.raw(`insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation) values(${lit(team)},${lit(freshBody.request_id)},${lit(users.editor.id)},'other',${lit(freshBody.task_id)},${lit(freshBody.task_generation)})`);
  check('ordinary command nonce denied',(await review(freshBody)).code,'PT409');
  const privateProject=randomUUID();
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(privateProject)},${lit(users.owner.id)},'Private series');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(privateProject)},${lit(team)},'private')`);
  const privateParent=await create({project_id:privateProject,title:'Private parent text'}),child=await create({recurrence_parent_id:privateParent.id}),childBody=await body(child);
  const hiddenParent=ok('series parent independently authorized',await review(childBody));
  check('private series parent hidden',hiddenParent.series,null);check('authorized child still visible',hiddenParent.task.id,child.id);
  const inFlightSource=await create(),inFlight=await body(inFlightSource);
  let hold=await pg.hold(`set local role authenticated;set local request.jwt.claim.sub=${lit(users.editor.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:users.editor.id,session_id:users.editor.session}))};select public.taskfold_complete_team_task('complete',${json(inFlight)})`);
  let waiting=review(inFlight,'editor','complete',{app:'review-after-completion'});
  await pg.waitForLock('review-after-completion',hold.pid);await hold.release('commit');
  const observed=ok('review waits for in-flight command',await waiting);check('committed receipt observed after wait',observed.state,'recorded');
  hold=await pg.hold(`select id from taskfold_private.teams where id=${lit(team)} for update`);
  waiting=review(b,'editor','complete',{app:'review-role-loss'});await pg.waitForLock('review-role-loss',hold.pid);
  await hold.release('commit',`update taskfold_private.team_content_projects set visibility='private' where project_id=${lit(project)}`);
  check('access rechecked after actual lock wait',(await waiting).code,'42501');
  await pg.raw(`update taskfold_private.team_content_projects set visibility='team' where project_id=${lit(project)};delete from public.tasks where id=${lit(source.id)};insert into public.tasks select (jsonb_populate_record(null::public.tasks,${json({...source,task_generation:randomUUID(),title:'Replacement source secrets'})})).*`);
  const replaced=ok('replacement source review',await review(b));check('replacement source generation hidden',replaced.task,null);check('replacement parent generation hidden',replaced.series,null);
  check('bounded incoming body',(await review({...b,record:{...b.record,description:'x'.repeat(128001)}})).code,'22023');
  await pg.raw(`update taskfold_private.team_content_projects set visibility='private' where project_id=${lit(project)}`);
  check('revoked project hides existing receipt',(await review(b)).code,'42501');
  await pg.raw(`update taskfold_private.team_content_projects set visibility='team' where project_id=${lit(project)};update taskfold_private.teams set state='archived' where id=${lit(team)}`);
  check('paused team hides receipt',(await review(b)).code,'PT503');
  await pg.raw(`update taskfold_private.teams set state='active' where id=${lit(team)};delete from auth.sessions where id=${lit(users.editor.session)}`);
  check('revoked session hides receipt',(await review(b)).code,'28000');
  check('no writes or scopes from review',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_edit_scope`),0);
  check('private reader no anonymous privilege',await pg.scalar(`select to_jsonb(has_function_privilege('anon','taskfold_private.review_team_completion(text,jsonb)','execute'))`),false);
  report.advisors=await pg.advisors();check('no new advisor warnings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
  report.containerRemoved=await pg.close();pg=null;report.checkCount=Object.keys(report.checks).length;
  if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');
  if(process.argv[3])await writeFile(process.argv[3],JSON.stringify(fixture,null,2)+'\n');
  console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
} finally {if(pg)await pg.close();}
