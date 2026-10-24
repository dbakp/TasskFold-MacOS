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
  const {loadTeamProvisionalRetirementSchema,teamProvisionalRetirementMigration}=await import('./team-provisional-retirement-schema.mjs');
  await loadTeamProvisionalRetirementSchema(pg.raw,{base:false});
  report.retirementMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamProvisionalRetirementMigration,import.meta.url))).digest('hex');
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
  const retire=(b,who='editor',opts={})=>run(who,`public.taskfold_retire_team_provisional(${json(b)})`,opts);
  const source=await create(),b=await body(source);
  check('retirement defaults closed',(await retire(b)).code,'PT503');
  await pg.raw('update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true');
  check('unrecorded request cannot reserve generation',(await retire(b)).code,'PT409');
  check('no unrecorded generation reserved',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.task_generations where task_id=${lit(b.planned_next_id)} and generation=${lit(b.next_generation)}`),0);
  const shared=await create({id:b.planned_next_id,title:'Existing shared occurrence',due_date:'2026-10-25',recurrence_parent_id:source.id});
  const accepted=ok('completion adopts shared occurrence',await rpc('complete',b));check('original completion did not create provisional',accepted.created_successor,false);
  const beforeSource=await row(source.id),beforeNext=await row(shared.id),beforeActivity=await pg.scalar('select to_jsonb(count(*)) from public.task_activity');
  const sealed=ok('retire unused generation',await retire(b));
  check('retirement protocol',sealed.draft_retirement_protocol,1);check('generation certified unavailable',sealed.generation_unavailable,true);
  check('retired exact original generation',sealed.task_generation,b.next_generation);check('current shared task returned',sealed.current_proposed,beforeNext);
  check('source untouched',await row(source.id),beforeSource);check('shared occurrence untouched',await row(shared.id),beforeNext);
  check('no phantom public task',await pg.scalar('select to_jsonb(count(*)) from public.tasks'),2);check('no activity from retirement',await pg.scalar('select to_jsonb(count(*)) from public.task_activity'),beforeActivity);
  check('generation is a tombstone',await pg.scalar(`select to_jsonb(deleted_at is not null) from taskfold_private.task_generations where task_id=${lit(shared.id)} and generation=${lit(b.next_generation)}`),true);
  check('custody survives actor removal',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_content_tasks where task_id=${lit(shared.id)} and generation=${lit(b.next_generation)} and team_id=${lit(team)} and project_id=${lit(project)}`),1);
  check('exact retirement retry',ok('lost retirement response retry',await retire(b)),sealed);
  const oldEdit={team_id:team,project_id:project,task_id:shared.id,task_generation:b.next_generation,request_id:randomUUID(),base:{project_id:project,task_generation:b.next_generation,title:source.title},changes:{title:'Must remain a local draft'}};
  check('old patch cannot reach shared occurrence',(await run('editor',`public.taskfold_edit_team_task(${json(oldEdit)})`)).code,'PT409');
  check('failed old patch keeps current shared title',(await row(shared.id)).title,beforeNext.title);
  let recreationCode;try {await pg.raw(`begin;delete from public.tasks where id=${lit(shared.id)};insert into public.tasks select (jsonb_populate_record(null::public.tasks,${json({...beforeNext,task_generation:b.next_generation,user_id:users.editor.id})})).*;rollback;`)}catch(e){recreationCode=e.code}
  check('retired identity cannot ever become live',recreationCode,'P0001');check('failed recreation rolls back shared deletion',await row(shared.id),beforeNext);
  const fixture={account:users.editor.id,body:b,reply:accepted,retirement:sealed};
  check('other actor cannot retire another action',(await retire(b,'owner')).code,'PT409');
  check('changed body cannot retire another identity',(await retire({...b,next_generation:randomUUID()})).code,'PT409');
  check('outsider cannot retire',(await retire(b,'outsider')).code,'42501');
  check('expired session cannot retire',(await retire(b,'editor',{session:randomUUID()})).code,'28000');
  for(const role of ['anon','service_role'])check(role+' cannot retire',(await retire(b,'editor',{role})).code,'42501');
  const ownBody=await body(await create()),own=ok('own live future setup',await rpc('complete',ownBody));
  check('live owned generation cannot be retired',(await retire(ownBody)).code,'PT409');check('live owned future remains unchanged',await row(own.successor_id),own.successor);
  const raceSource=await create(),race=await body(raceSource),raceShared=await create({id:race.planned_next_id,due_date:'2026-10-25',recurrence_parent_id:raceSource.id});
  ok('race adoption setup',await rpc('complete',race));
  let hold=await pg.hold(`select pg_advisory_xact_lock(hashtextextended(${lit(raceShared.id)},78137))`);
  const waiting=retire(race,'editor',{app:'retirement-generation-wait'});await pg.waitForLock('retirement-generation-wait',hold.pid);
  await hold.release('commit',`delete from public.tasks where id=${lit(raceShared.id)};insert into public.tasks select (jsonb_populate_record(null::public.tasks,${json({...raceShared,user_id:users.editor.id,task_generation:race.next_generation})})).*`);
  check('live generation rechecked after wait',(await waiting).code,'PT409');check('racing live generation not retired',(await row(raceShared.id)).task_generation,race.next_generation);
  const legacySource=await create(),legacyBody=await body(legacySource),legacyFuture=await create({due_date:'2026-10-25',recurrence_parent_id:legacySource.id});
  ok('legacy occurrence adoption',await rpc('complete',legacyBody));
  const historyBefore=await pg.scalar(`select to_jsonb(taskfold_private.team_completion_generation_history(${lit(legacyBody.planned_next_id)}::uuid))`);
  ok('retire unused legacy canonical generation',await retire(legacyBody));
  check('provisional marker is private',await pg.scalar(`select to_jsonb(has_table_privilege('authenticated','taskfold_private.team_provisional_retirements','select,insert,update,delete'))`),false);
  check('virtual marker does not poison Undo history',await pg.scalar(`select to_jsonb(taskfold_private.team_completion_generation_history(${lit(legacyBody.planned_next_id)}::uuid))`),historyBefore);
  await pg.raw(`delete from public.tasks where id=${lit(legacyFuture.id)};update public.tasks set completed=false,completed_at=null where id=${lit(legacySource.id)}`);
  const freshBody=await body(await row(legacySource.id));
  check('exact retired generation still rejected',(await rpc('complete',{...freshBody,next_generation:legacyBody.next_generation})).code,'PT409');
  const freshResult=ok('fresh canonical generation after virtual retirement',await rpc('complete',freshBody));
  check('fresh generation can become actual work',freshResult.successor.task_generation,freshBody.next_generation);check('fresh canonical identity correct',freshResult.successor.id,legacyBody.planned_next_id);
  await pg.raw(`delete from public.tasks where id=${lit(own.successor_id)}`);
  const realHistory=await pg.scalar(`select to_jsonb(taskfold_private.team_completion_generation_history(${lit(own.successor_id)}::uuid))`);
  ok('retire already deleted real generation',await retire(ownBody));
  check('real deletion never marked provisional',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_provisional_retirements where task_id=${lit(own.successor_id)} and generation=${lit(ownBody.next_generation)}`),0);
  check('real deletion history retained',await pg.scalar(`select to_jsonb(taskfold_private.team_completion_generation_history(${lit(own.successor_id)}::uuid))`),realHistory);
  const failureSource=await create(),failure=await body(failureSource);await create({id:failure.planned_next_id,due_date:'2026-10-25',recurrence_parent_id:failureSource.id});ok('interruption adoption setup',await rpc('complete',failure));
  await pg.raw(`create function public.fixture_retirement_fail() returns trigger language plpgsql as $$begin if new.task_id=${lit(failure.planned_next_id)}::uuid and new.generation=${lit(failure.next_generation)}::uuid then raise exception 'Synthetic retirement interruption';end if;return new;end$$;create trigger fixture_retirement_fail after insert on taskfold_private.task_generations for each row execute function public.fixture_retirement_fail()`);
  check('retirement interruption fails',(await retire(failure)).code,'P0001');check('interruption rolls back generation',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.task_generations where task_id=${lit(failure.planned_next_id)} and generation=${lit(failure.next_generation)}`),0);check('interruption rolls back custody',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_content_tasks where task_id=${lit(failure.planned_next_id)} and generation=${lit(failure.next_generation)}`),0);
  await pg.raw('drop trigger fixture_retirement_fail on taskfold_private.task_generations;drop function public.fixture_retirement_fail()');
  await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer');update taskfold_private.team_project_config set native_task_edits_enabled=false`);
  check('read-only actor may retire own unused identity',ok('viewer retirement',await retire(failure)).generation_unavailable,true);
  await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=false');check('read pause denies retirement',(await retire(b)).code,'PT503');await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=true');
  await pg.raw(`delete from auth.users where id=${lit(users.editor.id)}`);
  check('actor removal retains retirement tombstone',await pg.scalar(`select to_jsonb(deleted_at is not null) from taskfold_private.task_generations where task_id=${lit(shared.id)} and generation=${lit(b.next_generation)}`),true);
  check('removed actor cannot replay retirement',(await retire(b)).code,'28000');
  await pg.raw(`update taskfold_private.teams set state='deleted',name=null,owner_id=null where id=${lit(team)}`);
  check('team deletion retains generation fence',await pg.scalar(`select to_jsonb(deleted_at is not null) from taskfold_private.task_generations where task_id=${lit(shared.id)} and generation=${lit(b.next_generation)}`),true);
  report.advisors=await pg.advisors();check('no new advisor warnings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
  report.containerRemoved=await pg.close();pg=null;report.checkCount=Object.keys(report.checks).length;
  if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');if(process.argv[3])await writeFile(process.argv[3],JSON.stringify(fixture,null,2)+'\n');console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
}finally{if(pg)await pg.close();}
