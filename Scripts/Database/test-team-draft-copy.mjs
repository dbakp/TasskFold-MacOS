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
  const {loadTeamDraftCopySchema,teamDraftCopyMigration}=await import('./team-draft-copy-schema.mjs');
  await loadTeamDraftCopySchema(pg.raw,{base:false});
  report.copyMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamDraftCopyMigration,import.meta.url))).digest('hex');
  const copy=(b,commit=false,who='editor',opts={})=>run(who,`public.taskfold_copy_team_draft(${json(b)},${commit})`,opts);
  const retire=(b)=>run('editor',`public.taskfold_retire_team_provisional(${json(b)})`);
  const section=randomUUID();await pg.raw(`insert into public.sections(id,user_id,project_id,name) values(${lit(section)},${lit(users.owner.id)},${lit(project)},'Design review')`);
  const relative={version:1,id:randomUUID(),kind:'relative',anchor:'planned',offset_minutes:15,channels:['local'],enabled:true};
  const privateReminder={version:1,id:randomUUID(),kind:'location',private_place:'synthetic place',enabled:true};
  const source=await create({title:'Review the workshop',description:'Review layout\nCheck contrast',section_id:section,assigned_to:users.owner.id,labels:['design'],duration_minutes:45,
   attachments:[{id:'synthetic-file',path:'fixture/review.pdf'}],source_metadata:{future:{schema:2,note:'Keep this opaque value'}},
   reminder_specs:[relative,privateReminder],subtasks:[{id:'original-child',title:'Approve contrast',description:'Check every state',completed:false,attachments:[{path:'fixture/child.pdf'}],comments:[],source_metadata:{future:'child extension'},subtasks:[],assigned_to:users.owner.id,reminder_specs:[relative]}]});
  const original=await body(source);
  const prototype=await pg.scalar(`select taskfold_private.automation_successor(${json(source)},${lit(users.editor.id)}::uuid,${lit(original.completed_at)}::timestamptz,${lit(original.input_zone)},${lit(original.request_id)}::uuid,${lit(original.next_generation)}::uuid)`);
  const saved=structuredClone(prototype);saved.title='Draft design review';saved.description+='\nSaved offline instructions';saved.priority=1;saved.deadline_date='2026-11-01';saved.subtasks[0].title='Approve all contrast';saved.subtasks[0].completed=true;
  const request=()=>({original,record:structuredClone(saved),request_id:randomUUID(),task_id:randomUUID(),task_generation:randomUUID(),copy_assignments:false,copy_reminders:false});
  const initial=request();
  check('copy defaults closed',(await copy(initial)).code,'PT503');
  await pg.raw('update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true');
  check('unrecorded baseline cannot certify copy',(await copy(initial)).code,'PT409');
  const shared=await create({id:original.planned_next_id,due_date:'2026-10-25',recurrence_parent_id:source.id});
  ok('recorded original adoption',await rpc('complete',original));
  check('live unretired draft cannot copy',(await copy(initial)).code,'PT409');
  ok('saved draft retirement',await retire(original));
  const beforeSource=await row(source.id),beforeShared=await row(shared.id);
  const preview=ok('preview full saved draft',await copy(initial));
  check('preview no recorded action',preview.recorded,false);check('preview no new task',await row(initial.task_id),null);
  const created=ok('copy full saved draft',await copy(initial,true));
  check('fresh independent identity',created.task.id,initial.task_id);check('fresh independent generation',created.task.task_generation,initial.task_generation);
  check('copy recorded',created.recorded,true);check('title kept',created.task.title,saved.title);check('full notes kept',created.task.description,saved.description);
  check('file references kept',created.task.attachments,saved.attachments);check('opaque metadata kept',created.task.source_metadata.future,saved.source_metadata.future);
  check('old lineage removed',created.task.recurrence_parent_id,null);check('old completion history removed',created.task.completion_version,0);check('old recurrence ownership removed','taskfold_recurrence_v1' in created.task.source_metadata,false);
  check('copy provenance bound',created.task.source_metadata.taskfold_draft_copy_v1.request_id,initial.request_id);
  check('section kept',created.task.section_id,section);check('labels kept',created.task.labels,['design']);check('priority kept',created.task.priority,1);check('estimate kept',created.task.duration_minutes,45);check('deadline kept',created.task.deadline_date,'2026-11-01');
  check('assignments off by choice',created.task.assigned_to,null);check('reminders off by choice',created.task.reminder_specs,[{"version":1,"id":"00000000-0000-4000-8000-000000000001","kind":"relative","anchor":"planned","offset_minutes":0,"channels":["local"],"enabled":false}]);
  const child=created.task.subtasks[0];check('child title kept',child.title,saved.subtasks[0].title);check('child notes kept',child.description,saved.subtasks[0].description);check('child files kept',child.attachments,saved.subtasks[0].attachments);check('child opaque value kept',child.source_metadata,saved.subtasks[0].source_metadata);check('child checked state kept',child.completed,true);check('child history starts fresh',child.taskfold_completion_v1.version,0);check('child completion date server stamped',child.completed_at!==null);check('child assignment cleared',child.assigned_to,null);check('child reminders cleared',child.reminder_specs,[{"version":1,"id":"00000000-0000-4000-8000-000000000001","kind":"relative","anchor":"planned","offset_minutes":0,"channels":["local"],"enabled":false}]);
  check('original task untouched',await row(source.id),beforeSource);check('shared occurrence untouched',await row(shared.id),beforeShared);
  const replay=ok('exact copy retry',await copy(initial,true));check('retry returns same identity',replay.task.id,initial.task_id);check('retry acknowledged',replay.replayed,true);
  const fixture={account:users.editor.id,body:initial,preview,created,replay};
  const previewOnly=request(),countsBeforePreview=await pg.scalar("select jsonb_build_array((select count(*) from public.tasks),(select count(*) from taskfold_private.team_task_edits),(select count(*) from taskfold_private.task_generations),(select count(*) from public.task_activity))");
  ok('separate read-only preview',await copy(previewOnly));
  check('preview has no task receipt generation or activity writes',await pg.scalar("select jsonb_build_array((select count(*) from public.tasks),(select count(*) from taskfold_private.team_task_edits),(select count(*) from taskfold_private.task_generations),(select count(*) from public.task_activity))"),countsBeforePreview);
  const privateChoice={...request(),copy_reminders:true};check('private reminder cannot be silently replayed',(await copy(privateChoice,true)).code,'22023');check('private rejection creates nothing',await row(privateChoice.task_id),null);
  const opted=request();opted.copy_reminders=true;opted.copy_assignments=true;opted.record.reminder_specs=[relative];
  const full=ok('reviewed portable reminders and assignments',await copy(opted,true));
  check('root assignee explicitly copied',full.task.assigned_to,users.owner.id);check('root portable reminder copied',full.task.reminder_specs,[relative]);check('child assignee explicitly copied',full.task.subtasks[0].assigned_to,users.owner.id);check('child portable reminder copied',full.task.subtasks[0].reminder_specs,[relative]);
  check('new root task attributed to copying actor',full.task.user_id,users.editor.id);check('new root creation clock',full.task.created_at!==saved.created_at);
  const changedOptions={...initial,copy_assignments:true};check('retry cannot change choices',(await copy(changedOptions,true)).code,'PT409');
  const forged=request();forged.original={...original,record:{...original.record,attachments:[{path:'another-account/secret.pdf'}]}};check('forged baseline cannot certify files',(await copy(forged,true)).code,'PT409');
  for(const key of ['attachments','source_metadata','comments','recurrence_parent_id']) {
   const bad=request();bad.record[key]=key==='source_metadata'?{forged:'extra data'}:key==='recurrence_parent_id'?randomUUID():[{path:'unattested'}];
   check('reject changed readonly root '+key,(await copy(bad,true)).code,'22023');check('no root written for '+key,await row(bad.task_id),null);
  }
  const childFile=request();childFile.record.subtasks[0].attachments=[{path:'unattested-child.pdf'}];check('reject changed child file reference',(await copy(childFile,true)).code,'22023');
  const childOpaque=request();childOpaque.record.subtasks[0].source_metadata.future='changed';check('reject changed child opaque field',(await copy(childOpaque,true)).code,'22023');
  const childToken=request();childToken.record.subtasks[0].completed_at='1999-01-01T00:00:00Z';childToken.record.subtasks[0].taskfold_completion_v1={epoch:randomUUID(),version:500};
  const reset=ok('new child history ignores archived timestamps and counters',await copy(childToken,true));check('child counter reset',reset.task.subtasks[0].taskfold_completion_v1.version,0);check('child timestamp not fabricated',reset.task.subtasks[0].completed_at!=='1999-01-01T00:00:00+00:00');
  const nested=request();nested.record.subtasks[0].subtasks=[{id:randomUUID(),title:'New authored checklist item',description:'Keep nested notes',completed:true,subtasks:[]}];
  const nestedCopy=ok('copy authored nested checklist additions',await copy(nested,true));check('nested notes retained',nestedCopy.task.subtasks[0].subtasks[0].description,'Keep nested notes');check('nested checked state retained',nestedCopy.task.subtasks[0].subtasks[0].completed,true);
  const newFile=request();newFile.record.subtasks.push({id:randomUUID(),title:'Forged new child',attachments:[{path:'unattested.pdf'}]});check('new child cannot mint file access',(await copy(newFile,true)).code,'22023');
  const duplicate=request();duplicate.record.subtasks.push(structuredClone(duplicate.record.subtasks[0]));check('duplicate child identity rejected',(await copy(duplicate,true)).code,'22023');
  const wrongProject=request();wrongProject.record.project_id=randomUUID();check('copy cannot change project',(await copy(wrongProject,true)).code,'22023');
  const sameTask=request();sameTask.task_id=original.planned_next_id;check('copy cannot reuse provisional task identity',(await copy(sameTask,true)).code,'22023');
  const oldGeneration=request();oldGeneration.task_generation=original.next_generation;check('copy cannot reuse retired generation',(await copy(oldGeneration,true)).code,'22023');
  const sameNonce=request();sameNonce.request_id=original.request_id;check('copy cannot reuse original completion nonce',(await copy(sameNonce,true)).code,'22023');
  const malformed=request();malformed.copy_reminders='yes';check('copy options require booleans',(await copy(malformed,true)).code,'22023');
  check('anonymous cannot copy',(await copy(request(),true,'editor',{role:'anon'})).code,'42501');check('service cannot call native copy',(await copy(request(),true,'editor',{role:'service_role'})).code,'42501');
  check('viewer cannot copy',(await copy({...request(),record:{...saved,user_id:users.viewer.id}},true,'viewer')).code,'42501');check('outsider cannot copy',(await copy({...request(),record:{...saved,user_id:users.outsider.id}},true,'outsider')).code,'42501');
  check('foreign actor cannot use recorded original',(await copy({...request(),record:{...saved,user_id:users.owner.id}},true,'owner')).code,'PT409');
  check('unknown session cannot preview',(await copy(request(),false,'editor',{session:randomUUID()})).code,'28000');
  await pg.raw(`update auth.users set banned_until=now()+interval '1 day' where id=${lit(users.editor.id)}`);check('banned actor cannot copy',(await copy(request(),true)).code,'28000');await pg.raw(`update auth.users set banned_until=null where id=${lit(users.editor.id)}`);
  await pg.raw('update taskfold_private.team_project_config set native_task_edits_enabled=false');check('edit pause denies copy retry',(await copy(initial,true)).code,'PT503');await pg.raw('update taskfold_private.team_project_config set native_task_edits_enabled=true,native_reads_enabled=false');check('read pause denies copy',(await copy(request())).code,'PT503');await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=true');
  await pg.raw(`update public.projects set is_archived=true where id=${lit(project)}`);check('archived project rejects copy',(await copy(request(),true)).code,'PT409');await pg.raw(`update public.projects set is_archived=false,ancestor_archived=true where id=${lit(project)}`);check('archived ancestor rejects copy',(await copy(request(),true)).code,'PT409');await pg.raw(`update public.projects set ancestor_archived=false where id=${lit(project)}`);
  const rejectedRecipient=request();rejectedRecipient.copy_assignments=true;rejectedRecipient.record.assigned_to=users.viewer.id;check('view-only assignee cannot be copied',(await copy(rejectedRecipient,true)).code,'42501');
  const unavailableSection=request();unavailableSection.record.section_id=randomUUID();check('missing section is reviewed not silently dropped',(await copy(unavailableSection,true)).code,'PT409');
  await pg.raw(`update public.tasks set description='Another edit after creation' where id=${lit(initial.task_id)}`);
  const latest=ok('retry reads current edited copy',await copy(initial,true));check('retry never overwrites later edits',latest.task.description,'Another edit after creation');fixture.editedReplay=latest;
  await pg.raw(`delete from public.tasks where id=${lit(initial.task_id)}`);const gone=ok('retry after deletion',await copy(initial,true));check('deleted copy unavailable',gone.unavailable,true);check('deleted copy not recreated',await row(initial.task_id),null);fixture.unavailableReplay=gone;
  check('deleted task identity cannot create new copy',(await copy({...request(),task_id:initial.task_id},true)).code,'PT409');
  const interrupted=request();await pg.raw(`create function public.fixture_copy_fail() returns trigger language plpgsql as $$begin if new.request_id=${lit(interrupted.request_id)}::uuid then raise exception 'Synthetic copy interruption';end if;return new;end$$;create trigger fixture_copy_fail after insert on taskfold_private.team_draft_copies for each row execute function public.fixture_copy_fail()`);
  check('interrupted copy fails',(await copy(interrupted,true)).code,'P0001');check('interruption rolls back task',await row(interrupted.task_id),null);check('interruption rolls back receipt',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.team_task_edits where request_id=${lit(interrupted.request_id)}`),0);check('interruption rolls back generation',await pg.scalar(`select to_jsonb(count(*)) from taskfold_private.task_generations where task_id=${lit(interrupted.task_id)}`),0);
  await pg.raw('drop trigger fixture_copy_fail on taskfold_private.team_draft_copies;drop function public.fixture_copy_fail()');ok('same interrupted request safely retries',await copy(interrupted,true));
  const concurrent=request(),hold=await pg.hold(`begin;select pg_advisory_xact_lock(hashtextextended(${lit(concurrent.task_id)},78137));`);
  const first=copy(concurrent,true,'editor',{app:'draft-copy-first'});await pg.waitForLock('draft-copy-first',hold.pid);
  const second=copy(concurrent,true,'editor',{app:'draft-copy-second'});await hold.release('commit');
  const pair=await Promise.all([first,second]);ok('concurrent first copy',pair[0]);ok('concurrent second copy',pair[1]);check('concurrent duplicate has one replay',pair.map(x=>x.value.replayed).sort(),[false,true]);check('concurrent duplicate creates one row',await pg.scalar(`select to_jsonb(count(*)) from public.tasks where id=${lit(concurrent.task_id)}`),1);
  const recipientRace=request();recipientRace.copy_assignments=true;const recipientHold=await pg.hold(`begin;update auth.users set banned_until=now()+interval '1 day' where id=${lit(users.owner.id)};`);
  const waiting=copy(recipientRace,true,'editor',{app:'draft-copy-recipient'});await pg.waitForLock('draft-copy-recipient',recipientHold.pid);await recipientHold.release('commit');check('recipient ban rechecked after real wait',(await waiting).code,'42501');check('recipient race creates nothing',await row(recipientRace.task_id),null);await pg.raw(`update auth.users set banned_until=null where id=${lit(users.owner.id)}`);
  const lifecycleCollision=run('editor',`public.taskfold_team_task_lifecycle('create',${json({team_id:team,project_id:project,task_id:initial.task_id,task_generation:initial.task_generation,request_id:initial.request_id,record:created.task})})`);
  check('copy nonce cannot be replayed as normal lifecycle',(await lifecycleCollision).code,'PT409');
  const roleRequest=request(),roleHold=await pg.hold(`begin;select id from taskfold_private.teams where id=${lit(team)} for update;`);
  const roleWait=copy(roleRequest,true,'editor',{app:'draft-copy-role'});await pg.waitForLock('draft-copy-role',roleHold.pid);
  await roleHold.release('commit',`insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer')`);
  check('role rechecked after actual team lock wait',(await roleWait).code,'42501');check('revoked edit creates nothing',await row(roleRequest.task_id),null);
  await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(users.editor.id)}`);
  const identityRace=request(),identityHold=await pg.hold(`begin;select pg_advisory_xact_lock(hashtextextended(${lit(identityRace.task_id)},78137));`);
  const identityWait=copy(identityRace,true,'editor',{app:'draft-copy-identity'});await pg.waitForLock('draft-copy-identity',identityHold.pid);
  const competing={...source,id:identityRace.task_id,task_generation:randomUUID(),title:'Competing task identity'};
  await identityHold.release('commit',`insert into public.tasks select (jsonb_populate_record(null::public.tasks,${json(competing)})).*`);
  check('task identity rechecked after actual lock wait',(await identityWait).code,'PT409');check('competing task is unchanged',(await row(identityRace.task_id)).title,competing.title);
  const malformedState=request();malformedState.record.completed='true';check('root completion requires boolean',(await copy(malformedState,true)).code,'22023');
  const cancelSource=await create(),cancelBody=await body(cancelSource);
  ok('cancelled baseline setup',await run('editor',`public.taskfold_cancel_team_completion('complete',${json(cancelBody)})`));
  const cancelPrototype=await pg.scalar(`select taskfold_private.automation_successor(${json(cancelSource)},${lit(users.editor.id)}::uuid,${lit(cancelBody.completed_at)}::timestamptz,${lit(cancelBody.input_zone)},${lit(cancelBody.request_id)}::uuid,${lit(cancelBody.next_generation)}::uuid)`);
  check('cancelled baseline cannot certify a copy',(await copy({...request(),original:cancelBody,record:cancelPrototype},true)).code,'PT409');
  const cancelCopy=(b,who='editor',opts={})=>run(who,`public.taskfold_copy_team_draft(${json(b)},false,true)`,opts);
  const parked=request();parked.copy_assignments=true;
  const cancelledCopy=ok('cancel unrecorded copy',await cancelCopy(parked));check('copy cancellation certified',cancelledCopy.cancelled,true);check('cancellation does not claim creation',cancelledCopy.recorded,false);check('cancellation creates no task',await row(parked.task_id),null);fixture.cancelBody=parked;fixture.cancelledCopy=cancelledCopy;
  const late=ok('late copy sees cancellation',await copy(parked,true));check('late request cannot create after cancellation',late.cancelled,true);check('late request leaves task absent',await row(parked.task_id),null);
  check('cancel exact retry',ok('cancel retry response',await cancelCopy(parked)).cancelled,true);
  const changedCopy={...parked,copy_assignments:false};check('cancelled nonce cannot change request body',(await copy(changedCopy,true)).code,'PT409');
  const firstWins=ok('cancelling recorded copy recovers receipt',await cancelCopy(opted));check('recorded copy never called cancelled',firstWins.cancelled,false);check('recorded copy still recorded',firstWins.recorded,true);check('recorded task preserved on cancel',firstWins.task.id,opted.task_id);fixture.cancelRecorded=firstWins;
  const failedChoices=request();failedChoices.copy_assignments=true;failedChoices.record.assigned_to=users.viewer.id;
  check('invalid recipient fails before recording',(await copy(failedChoices,true)).code,'42501');
  const failedCancel=ok('failed recipient choice can cancel',await cancelCopy(failedChoices));check('invalid recipient cancelled',failedCancel.cancelled,true);
  const reviewedAgain={...failedChoices,copy_assignments:false,request_id:randomUUID(),task_id:randomUUID(),task_generation:randomUUID()};ok('new reviewed choice after cancellation',await copy(reviewedAgain,true));
  const viewerCancel=request();await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer');update taskfold_private.team_project_config set native_task_edits_enabled=false;update public.projects set is_archived=true where id=${lit(project)}`);
  check('own cancellation works after losing edit access',ok('viewer archived cancellation',await cancelCopy(viewerCancel)).cancelled,true);
  await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(users.editor.id)};update taskfold_private.team_project_config set native_task_edits_enabled=true;update public.projects set is_archived=false where id=${lit(project)}`);
  const mixed=request(),mixedHold=await pg.hold(`begin;select pg_advisory_xact_lock(hashtextextended(${lit(team+':'+mixed.request_id)},79241));`);
  const mixedCreate=copy(mixed,true,'editor',{app:'draft-copy-mixed-create'});await pg.waitForLock('draft-copy-mixed-create',mixedHold.pid);
  const mixedCancel=cancelCopy(mixed,'editor',{app:'draft-copy-mixed-cancel'});await mixedHold.release('commit');
  const mixedResults=await Promise.all([mixedCreate,mixedCancel]);const m0=ok('mixed create result',mixedResults[0]),m1=ok('mixed cancel result',mixedResults[1]);
  check('copy cancellation race has one outcome',[m0.recorded,m0.cancelled],[m1.recorded,m1.cancelled]);check('mixed outcome matches actual task',Boolean(await row(mixed.task_id)),m0.recorded);
  check('copy receipt table private',await pg.scalar(`select to_jsonb(has_table_privilege('authenticated','taskfold_private.team_draft_copies','select,insert,update,delete'))`),false);
  await pg.raw(`delete from auth.users where id=${lit(users.editor.id)}`);check('actor removal purges copy receipts',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.team_draft_copies'),0);check('actor removal keeps actual shared copy',Boolean(await row(full.task_id)));check('removed actor cannot retry',(await copy(opted,true)).code,'28000');
  report.advisors=await pg.advisors();check('no new advisor warnings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
  report.containerRemoved=await pg.close();pg=null;report.checkCount=Object.keys(report.checks).length;
  if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');if(process.argv[3])await writeFile(process.argv[3],JSON.stringify(fixture,null,2)+'\n');console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
}finally{if(pg)await pg.close();}
