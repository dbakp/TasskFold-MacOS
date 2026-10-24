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
  const {loadTeamDraftCopySchema}=await import('./team-draft-copy-schema.mjs');await loadTeamDraftCopySchema(pg.raw,{base:false});
  const {loadTeamWorkspaceSchema,teamWorkspaceMigration}=await import('./team-workspace-schema.mjs');await loadTeamWorkspaceSchema(pg.raw,{base:false});
  report.workspaceMigrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+teamWorkspaceMigration,import.meta.url))).digest('hex');
  const boundary=(who='editor',opts={})=>run(who,'public.taskfold_workspace_boundary()',opts);
  const personal=randomUUID(),legacy=randomUUID(),hidden=randomUUID();
  await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(personal)},${lit(users.editor.id)},'Personal studio'),(${lit(legacy)},${lit(users.outsider.id)},'Legacy shared'),(${lit(hidden)},${lit(users.outsider.id)},'Unrelated private');insert into public.profiles(user_id) values(${lit(users.outsider.id)}),(${lit(users.editor.id)}) on conflict do nothing;set request.jwt.claim.sub=${lit(users.outsider.id)};insert into public.project_collaborators(id,project_id,invited_by,invited_email,role,status) values(${lit(randomUUID())},${lit(legacy)},${lit(users.outsider.id)},'editor@example.invalid','collaborator','pending');set request.jwt.claim.sub=${lit(users.editor.id)};update public.project_collaborators set status='accepted' where project_id=${lit(legacy)};set request.jwt.claim.sub=''`);
  const closed=ok('boundary available while team reads closed',await boundary());
  check('closed boundary returns personal and accepted legacy only',closed.projects.map(x=>x.id).sort(),[personal,legacy].sort());check('closed boundary returns no teams',closed.teams,[]);
  check('native team reads remain disabled by default',closed.native_team_reads_enabled,false);check('boundary actor bound',closed.account,users.editor.id);
  await pg.raw('update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true');
  const initial=ok('current member boundary',await boundary());check('team role current editor',initial.projects.find(x=>x.id===project).role,'editor');check('team binding explicit',initial.projects.find(x=>x.id===project).team_id,team);check('server guarded send capability current',initial.projects.find(x=>x.id===project).can_send_tasks,true);check('personal ownership separate',initial.projects.find(x=>x.id===personal).role,'owner');check('legacy sharing separate',initial.projects.find(x=>x.id===legacy).role,'collaborator');check('unknown private project omitted',initial.projects.some(x=>x.id===hidden),false);
  check('boundary deterministic without change',ok('unchanged read',await boundary()).token,initial.token);
  const task=await create();await pg.raw(`update public.tasks set title='Concurrent ordinary task edit' where id=${lit(task.id)}`);
  check('ordinary content edits do not invalidate access epoch',ok('content concurrency read',await boundary()).token,initial.token);
  await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer')`);
  const viewer=ok('current viewer boundary',await boundary());check('viewer cannot send task mutations',viewer.projects.find(x=>x.id===project).can_send_tasks,false);check('viewer role explicit',viewer.projects.find(x=>x.id===project).role,'viewer');check('grant changes invalidate old access token',viewer.token!==initial.token);
  await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(users.editor.id)}`);
  const restored=ok('editor restored boundary',await boundary());check('role restored',restored.projects.find(x=>x.id===project).role,'editor');check('access ABA remains detectable',restored.token!==initial.token);
  await pg.raw(`begin;insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer');rollback`);
  check('rolled back access changes do not invalidate token',ok('rollback read',await boundary()).token,restored.token);
  await pg.raw(`update public.projects set is_archived=true where id=${lit(project)}`);const archived=ok('archived project remains readable',await boundary());check('archived project cannot send',archived.projects.find(x=>x.id===project).can_send_tasks,false);check('archival invalidates access boundary',archived.token!==restored.token);
  await pg.raw(`update public.projects set is_archived=false where id=${lit(project)};update taskfold_private.teams set state='archived' where id=${lit(team)}`);const archivedTeam=ok('archived team boundary',await boundary());check('archived team cannot send',archivedTeam.projects.find(x=>x.id===project).can_send_tasks,false);
  await pg.raw(`update taskfold_private.teams set state='active' where id=${lit(team)}`);
  const hold=await pg.hold(`begin;select id from taskfold_private.teams where id=${lit(team)} for update;`);
  const waiting=boundary('editor',{app:'workspace-role-wait'});await pg.waitForLock('workspace-role-wait',hold.pid);await hold.release('commit',`insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer')`);
  const afterWait=ok('role boundary after actual lock wait',await waiting);check('role rechecked after wait',afterWait.projects.find(x=>x.id===project).role,'viewer');
  await pg.raw(`update taskfold_private.team_content_projects set visibility='private' where project_id=${lit(project)};delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(users.editor.id)}`);
  const revoked=ok('revoked private project boundary',await boundary());check('revoked project omitted',revoked.projects.some(x=>x.id===project),false);check('membership alone does not expose private projects',revoked.teams.length,1);
  await pg.raw(`update auth.users set raw_user_meta_data='{"role":"owner","team_role":"admin"}' where id=${lit(users.editor.id)}`);check('editable JWT metadata grants nothing',ok('forged metadata read',await boundary('editor',{claims:{user_metadata:{role:'owner',team_id:team}}})).projects.some(x=>x.id===project),false);
  await pg.raw(`update taskfold_private.team_content_projects set visibility='team' where project_id=${lit(project)}`);
  check('outsider sees only own personal projects',ok('outsider boundary',await boundary('outsider')).projects.map(x=>x.id).sort(),[legacy,hidden].sort());
  check('anonymous boundary denied',(await boundary('editor',{role:'anon'})).code,'42501');check('service role boundary denied',(await boundary('editor',{role:'service_role'})).code,'42501');check('invalid session denied',(await boundary('editor',{session:randomUUID()})).code,'28000');
  const epochHold=await pg.hold(`begin;insert into taskfold_private.team_project_grants values(${lit(project)},${lit(team)},${lit(users.editor.id)},'viewer');`);
  const epochWait=boundary('editor',{app:'workspace-epoch-wait'});await pg.waitForLock('workspace-epoch-wait',epochHold.pid);await epochHold.release('commit');
  check('role rechecked after epoch wait',ok('boundary after direct maintenance wait',await epochWait).projects.find(x=>x.id===project).role,'viewer');
  await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(project)} and user_id=${lit(users.editor.id)};update taskfold_private.team_config set enabled=false`);
  const paused=ok('paused setup boundary',await boundary());check('setup pause preserves current read role',paused.projects.find(x=>x.id===project).role,'editor');check('setup pause disables server sends',paused.projects.find(x=>x.id===project).can_send_tasks,false);
  await pg.raw('update taskfold_private.team_config set enabled=true');
  const active=ok('active boundary fixture',await boundary());const fixture={account:users.editor.id,team,project,personal,legacy,active,viewer,revoked,archived,closed,paused};
  const survivingProject=randomUUID();await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(survivingProject)},${lit(users.outsider.id)},'Surviving shared project');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(survivingProject)},${lit(team)},'team')`);
  await pg.raw(`delete from auth.users where id=${lit(users.outsider.id)}`);
  const survivor=ok('boundary after shared creator removal',await boundary());check('removed creator does not remove membership access',survivor.projects.find(x=>x.id===survivingProject).role,'editor');check('shared content keeps historical creator UUID',await pg.scalar(`select to_jsonb(user_id) from public.projects where id=${lit(survivingProject)}`),users.outsider.id);
  await pg.raw(`delete from taskfold_private.team_members where team_id=${lit(team)} and user_id=${lit(users.editor.id)}`);const left=ok('left team boundary',await boundary());check('left team content omitted',left.projects.some(x=>x.id===project),false);check('left team directory omitted',left.teams,[]);check('personal work stays available',left.projects.some(x=>x.id===personal),true);fixture.left=left;
  check('private epochs not exposed',await pg.scalar(`select to_jsonb(has_table_privilege('authenticated','taskfold_private.team_access_epochs','select,insert,update,delete'))`),false);
  report.advisors=await pg.advisors();check('no new advisor warnings',report.advisors.result.filter(x=>['WARN','ERROR'].includes(x.level)&&x.name!=='auth_rls_initplan'),[]);
  report.containerRemoved=await pg.close();pg=null;report.checkCount=Object.keys(report.checks).length;
  if(process.argv[2])await writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');if(process.argv[3])await writeFile(process.argv[3],JSON.stringify(fixture,null,2)+'\n');console.log(JSON.stringify({checks:report.checkCount,containerRemoved:report.containerRemoved}));
}finally{if(pg)await pg.close();}
