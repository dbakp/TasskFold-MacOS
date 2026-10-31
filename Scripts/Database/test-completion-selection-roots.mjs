import assert from 'node:assert/strict';
import {createHash,randomUUID} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadChildAuthorityDependencies,childAuthorityMigration} from './child-task-authority-schema.mjs';
const migration='20261031031909_completion_selection_root_observations.sql';
const sql=await readFile(new URL('../../supabase/migrations/'+migration,import.meta.url),'utf8');
const report={checks:{},deployed:false,candidateSHA256:createHash('sha256').update(sql).digest('hex')};
const check=(name,a,b)=>{assert.deepEqual(a,b,name);report.checks[name]=true;};
const json=x=>lit(JSON.stringify(x))+'::jsonb';let pg;
try {
 report.stage='owned schema and advisors';pg=await createPostgresFixture({advisors:true});if(process.env.TASKFOLD_TEST_MIXED_COMPLETION_UPGRADE==='1') {
   const {loadMixedTaskCompletionRegression}=await import('./mixed-task-completion-schema.mjs');
   await loadMixedTaskCompletionRegression(pg,report);
 } else {
await loadChildAuthorityDependencies(pg);
 await pg.raw(await readFile(new URL('../../supabase/migrations/'+childAuthorityMigration,import.meta.url),'utf8'));
 report.baselineAdvisors=await pg.advisors();
 const schema=await pg.scalar(`create temp table load_result(code text,reason text,context text);do $load$declare c text;begin begin execute ${lit(sql)};insert into load_result values(null,null,null);exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into load_result values(sqlstate,sqlerrm,c);end;end$load$;select to_jsonb(r) from load_result r;`);
 report.schemaDiagnostic=schema;if(schema.code)throw new Error(schema.reason);

 }
 const people=Object.fromEntries(['owner','writer','viewer','outside'].map(name=>[name,{id:randomUUID(),session:randomUUID()}]));
 for(const u of Object.values(people))await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit(u.id+'@example.invalid')},now());insert into public.profiles(user_id) values(${lit(u.id)});insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});`);
 const owner=people.owner,project=randomUUID(),team=randomUUID(),teamProject=randomUUID();
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(project)},${lit(owner.id)},'Synthetic root observation project');insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'Synthetic root observation team');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin'),(${lit(team)},${lit(people.writer.id)},'member'),(${lit(team)},${lit(people.viewer.id)},'member');insert into public.projects(id,user_id,name) values(${lit(teamProject)},${lit(owner.id)},'Synthetic team project');insert into taskfold_private.team_content_projects(team_id,project_id,visibility) values(${lit(team)},${lit(teamProject)},'private');insert into taskfold_private.team_project_grants(team_id,project_id,user_id,role) values(${lit(team)},${lit(teamProject)},${lit(people.writer.id)},'editor'),(${lit(team)},${lit(teamProject)},${lit(people.viewer.id)},'viewer');`);
 async function root({p=project,user=owner.id,recurring=false}={}) {
  const id=randomUUID();await pg.raw(`insert into public.tasks(id,user_id,project_id,title,is_recurring,subtasks,source_metadata) values(${lit(id)},${lit(user)},${p?lit(p):'null'},'Synthetic selected root',${recurring},'[{"id":"child","title":"Unchanged child","completed":false,"future":{"keep":[false,null]}}]'::jsonb,'{"exact":9007199254740993,"large":1e1000,"é":1,"é":2}'::jsonb);`);return id;
 }
 const body=ids=>({protocol:1,account:owner.id,task_ids:ids});
 const claims=(who='owner',session=people[who].session)=>`set local request.jwt.claim.sub=${lit(people[who].id)};set local request.jwt.claims=${lit(JSON.stringify({sub:people[who].id,session_id:session}))};`;
 const run=(b,{who='owner',session=people[who].session,guard=false,timezone='UTC'}={})=>pg.scalar(`begin;set local timezone=${lit(timezone)};create temp table result(value jsonb,code text,reason text) on commit drop;grant all on result to authenticated;${guard?'':'set local role authenticated;'}${claims(who,session)}do $op$begin begin ${guard?`perform taskfold_private.guard_completion_selection_roots(${json(b)});insert into result values('true',null,null);`:`insert into result values(public.taskfold_read_completion_selection_roots(${json(b)}),null,null);`}exception when others then insert into result values(null,sqlstate,left(sqlerrm,200));end;end$op$;select jsonb_build_object('value',value,'code',code,'reason',reason) from result;commit;`);
 const guards=r=>({protocol:1,account:r.account,roots:r.roots.map(x=>({task_id:x.task.id,baseline:x.baseline,source_hash:x.source_hash}))});
 const hash=()=>pg.scalar(`select to_jsonb(encode(extensions.digest(convert_to(jsonb_build_array((select jsonb_agg(to_jsonb(t) order by id) from public.tasks t),(select jsonb_agg(to_jsonb(n) order by task_id,node_key) from taskfold_private.child_task_records n),(select jsonb_agg(to_jsonb(a) order by sequence) from public.task_node_activity a))::text,'UTF8'),'sha256'),'hex'))`);
 report.stage='disabled gates';const first=await root(),second=await root({p:null}),repeat=await root({recurring:true});
 check('mixed read disabled by default',(await run(body([first]))).code,'PT503');
 await pg.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true');
 check('mixed read has separate disabled gate',(await run(body([first]))).code,'PT503');
 await pg.raw('update taskfold_private.child_task_record_config set mixed_completions_enabled=true');
 report.stage='ordered coherent read and exact source';let before=await hash();const read=await run(body([second,first,repeat]));report.initialRead={code:read.code,rootIDs:read.value?.roots.map(x=>x.task.id),sourceHashes:read.value?.roots.map(x=>x.source_hash)};check('read succeeds',read.code,null);
 check('caller root order preserved',read.value.roots.map(x=>x.task.id),[second,first,repeat]);
 check('baseline includes the complete identity/cohort',Object.keys(read.value.roots[0].baseline).sort(),['id','user_id','task_generation','project_id','section_id','completed','completed_at','completion_version','is_heading','is_recurring'].sort());
 check('hashes are bounded canonical server digests',read.value.roots.every(x=>/^[0-9a-f]{64}$/.test(x.source_hash)),true);
 check('reads do not change task node or history state',await hash(),before);
 const wire=await pg.raw(`begin;${claims()}select taskfold_private.read_completion_selection_roots(${json(body([second,first,repeat]))});commit;`);
 if(process.env.TASKFOLD_TEST_MIXED_COMPLETION_UPGRADE!=='1')await writeFile(new URL('../../TaskfoldTests/Fixtures/completion-selection-root-observations.json',import.meta.url),wire+'\n');
 report.rawWireSHA256=createHash('sha256').update(wire+'\n').digest('hex');
 const original=guards(read.value);check('all original guards pass',(await run(original,{guard:true})).code,null);
 check('guards do not change task node or history state',await hash(),before);
 // Compare opaque values in PostgreSQL itself; JavaScript numbers are not proof.
 check('exact opaque source remains unchanged',await pg.scalar(`select to_jsonb(source_metadata->'exact'= '9007199254740993'::jsonb and source_metadata->'large'='1e1000'::jsonb and source_metadata->'é'='1'::jsonb and source_metadata->'é'='2'::jsonb) from public.tasks where id=${lit(first)}`),true);
 const scoped=ids=>({...body(ids),account:people.writer.id});const shared=await root({p:teamProject});
 await pg.raw('update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true');
 check('shared editor can observe roots',(await run(scoped([shared]),{who:'writer'})).code,null);
 check('shared viewer cannot prepare a completion',(await run({...body([shared]),account:people.viewer.id},{who:'viewer'})).code,'42501');
 check('outside account cannot observe private roots',(await run({...body([first]),account:people.outside.id},{who:'outside'})).code,'42501');
 check('foreign Inbox remains private',(await run(scoped([second]),{who:'writer'})).code,'42501');
 check('account mismatch refused',(await run({...body([first]),account:people.outside.id})).code,'42501');
 check('missing live session refused',(await run(body([first]),{session:randomUUID()})).code,'28000');
 check('root observation is stable across caller time zones',(await run(body([first,repeat]),{timezone:'Pacific/Auckland'})).value,(await run(body([first,repeat]),{timezone:'UTC'})).value);
 report.stage='ordinary merge and recurring successor guard';
 await pg.raw(`update public.tasks set title='Fresh unrelated title' where id=${lit(first)}`);
 check('ordinary roots allow unrelated title edits',(await run(original,{guard:true})).code,null);
 await pg.raw(`update public.tasks set title='Changed successor source' where id=${lit(repeat)}`);
 check('recurring root source edit refuses whole guard',(await run(original,{guard:true})).code,'PT409');
 const fresh=guards((await run(body([first,second,repeat]))).value);
 await pg.raw(`update public.tasks set completed=true where id=${lit(second)}`);
 check('selected completion change refuses whole guard',(await run(fresh,{guard:true})).code,'PT409');
 await pg.raw(`update public.tasks set completed=false where id=${lit(second)}`);
 check('complete reopen cycle cannot restore an old guard',(await run(fresh,{guard:true})).code,'PT409');
 const current=(await run(body([first,second,repeat]))).value;const wrong=guards(current);wrong.roots[1].baseline.task_generation=randomUUID();check('replaced generation guard refused',(await run(wrong,{guard:true})).code,'PT409');
 const badHash=guards(current);badHash.roots[2].source_hash='0'.repeat(64);check('wrong recurring source hash refused',(await run(badHash,{guard:true})).code,'PT409');
 report.stage='malformed bounds and whole-read refusal';
 for(const [label,b] of [['empty',body([])],['duplicate',body([first,first])],['too many',body(Array(33).fill(first))],['malformed identity',body(['not-a-uuid'])],['unknown key',{...body([first]),unexpected:true}],['wrong protocol',{...body([first]),protocol:2}],['non-array',{...body([first]),task_ids:{}}]])check(label+' read refused',(await run(b)).code,'22023');
 const missing=randomUUID();before=await hash();check('later missing root refuses entire read',(await run(body([first,missing]))).code,'42501');check('failed whole read does not change content',await hash(),before);
 for(const [label,b] of [['empty',{...guards(current),roots:[]}],['duplicate',{...guards(current),roots:[guards(current).roots[0],guards(current).roots[0]]}],['unknown guard key',{...guards(current),future:true}],['malformed digest',{...guards(current),roots:[{...guards(current).roots[0],source_hash:'bad'}]}]])check(label+' guards refused',(await run(b,{guard:true})).code,'22023');
 await pg.raw(`update public.projects set is_archived=true where id=${lit(project)}`);check('archived project refused',(await run(body([first]))).code,'PT409');await pg.raw(`update public.projects set is_archived=false where id=${lit(project)}`);
 const heading=await root();await pg.raw(`update public.tasks set is_heading=true where id=${lit(heading)}`);check('heading cannot prepare completion',(await run(body([heading]))).code,'PT409');
 report.stage='busy roots and later access loss';
 const currentGuards=guards((await run(body([first,second]))).value);
 const holder=await pg.hold(`select id from public.tasks where id=${lit(second)} for update;`);
 try {before=await hash();check('busy later root refuses entire read',(await run(body([first,second]))).code,'55P03');check('busy later root refuses all guards',(await run(currentGuards,{guard:true})).code,'55P03');check('busy refusal does not change content',await hash(),before);}finally{await holder.release('rollback');}
 check('same guarded roots succeed after lock release',(await run(currentGuards,{guard:true})).code,null);
 const sharedRead=(await run(scoped([shared]),{who:'writer'})).value;
 await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(teamProject)} and user_id=${lit(people.writer.id)}`);
 check('saved observation cannot bypass later shared access loss',(await run(guards(sharedRead),{who:'writer',guard:true})).code,'42501');
 await pg.raw('update taskfold_private.team_config set enabled=false');check('team rollout pause refuses read',(await run(body([shared]))).code,'PT503');await pg.raw('update taskfold_private.team_config set enabled=true');
 await pg.raw('update taskfold_private.child_task_record_config set mixed_completions_enabled=false');check('mixed pause refuses saved guards',(await run(currentGuards,{guard:true})).code,'PT503');await pg.raw('update taskfold_private.child_task_record_config set mixed_completions_enabled=true');
 const boundRoots=[];for(let i=0;i<32;i++)boundRoots.push(await root({p:null}));
 check('32 distinct roots fit the read bound',(await run(body(boundRoots))).value.roots.length,32);
 const large=await root({p:null});await pg.raw(`update public.tasks set description=repeat('x',2000000) where id=${lit(large)}`);
 check('oversized root refused',(await run(body([large]))).code,'54000');
 const aggregate=[];for(let i=0;i<3;i++){const id=await root({p:null});await pg.raw(`update public.tasks set description=repeat('x',1450000) where id=${lit(id)}`);aggregate.push(id);}
 check('aggregate root source budget enforced',(await run(body(aggregate))).code,'54000');
 report.stage='security and advisors';
 for(const role of ['anon','service_role'])check(role+' cannot execute public read',await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},'public.taskfold_read_completion_selection_roots(jsonb)','execute'))`),false);
 check('authenticated can execute public read',await pg.scalar("select to_jsonb(has_function_privilege('authenticated','public.taskfold_read_completion_selection_roots(jsonb)','execute'))"),true);
 for(const fn of ['completion_selection_root(uuid)','completion_selection_root_hash(public.tasks)','completion_selection_root_baseline(public.tasks)','guard_completion_selection_roots(jsonb)'])for(const role of ['anon','authenticated','service_role'])check(role+' cannot directly call '+fn,await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},${lit('taskfold_private.'+fn)},'execute'))`),false);
 check('public read wrapper is invoker',await pg.scalar("select to_jsonb(not prosecdef) from pg_proc where oid='public.taskfold_read_completion_selection_roots(jsonb)'::regprocedure"),true);
 report.finalAdvisors=await pg.advisors();const old=new Set(report.baselineAdvisors.result.map(x=>x.cache_key));check('no added advisor findings',report.finalAdvisors.result.filter(x=>!old.has(x.cache_key)),[]);report.passed=true;console.log('PASS '+Object.keys(report.checks).length+' root completion observation database checks');
} catch(error){report.passed=false;report.error={name:error.name,code:error.code??null,message:error.message};process.exitCode=1;console.error('FAIL '+report.stage+': '+error.message+' '+(error.code??''));}
finally {if(pg)report.containerRemoved=await pg.close();await writeFile(process.argv[2]??'/tmp/taskfold-completion-selection-roots-database.json',JSON.stringify(report,null,2)+'\n');}
