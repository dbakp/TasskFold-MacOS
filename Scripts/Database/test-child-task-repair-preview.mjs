import assert from 'node:assert/strict';
import {readFile,writeFile} from 'node:fs/promises';
import {randomUUID,createHash} from 'node:crypto';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadChildAuthorityDependencies,childAuthorityMigration} from './child-task-authority-schema.mjs';
const migrations=["20261030093035_child_record_reviewed_team_transfers.sql", "20261030102036_child_record_project_adoption_custody.sql", "20261030104147_personal_child_record_task_moves.sql", "20261030114138_cross_root_child_task_transfers.sql", "20261030134132_reviewed_child_record_adoption.sql", "20261030170753_child_adoption_metadata_discovery.sql", "20261030183133_child_task_repair_previews.sql"];
const candidate=await readFile(new URL('../../supabase/migrations/'+migrations.at(-1),import.meta.url),'utf8');
const report={checks:{},candidateSHA256:createHash('sha256').update(candidate).digest('hex'),deployed:false};
const check=(name,value,expected=true)=>{assert.deepEqual(value,expected,name);report.checks[name]=true;};
const json=x=>lit(JSON.stringify(x))+'::jsonb';let pg;
try {
 pg=await createPostgresFixture({advisors:true});await loadChildAuthorityDependencies(pg);
 for(const name of [childAuthorityMigration,...migrations.slice(0,-1)])await pg.raw(await readFile(new URL('../../supabase/migrations/'+name,import.meta.url),'utf8'));
 report.baselineAdvisors=await pg.advisors();
 // Keep server diagnostics in the owned fixture, with no credentials or real data.
 const migration=await pg.scalar(`create temp table diagnostic(value jsonb);do $m$declare c text;begin begin execute ${lit(candidate)};exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into diagnostic values(jsonb_build_object('code',sqlstate,'reason',sqlerrm,'context',c));end;end$m$;select coalesce((select value from diagnostic),'{}'::jsonb);drop table diagnostic;`);
 if(migration.code){report.migrationDiagnostic=migration;throw Object.assign(new Error(migration.reason),{code:migration.code});}
 const users=Object.fromEntries(['owner','outside'].map(k=>[k,{id:randomUUID(),session:randomUUID()}]));const owner=users.owner;
 for(const u of Object.values(users))await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit(u.id+'@example.invalid')},now());insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});insert into public.profiles(user_id) values(${lit(u.id)});`);
 const run=async(expr,who='owner')=>{const u=users[who],v=await pg.scalar(`begin;create temp table fixture_result(value jsonb,code text,reason text,context text) on commit drop;grant all on fixture_result to authenticated;set local request.jwt.claim.sub=${lit(u.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:u.id,session_id:u.session}))};set local role authenticated;do $r$declare c text;begin begin insert into fixture_result values(to_jsonb(${expr}),null,null,null);exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into fixture_result values(null,sqlstate,sqlerrm,c);end;end$r$;select to_jsonb(r) from fixture_result r;commit;`);if(v.code){report.lastExpectedDiagnostic=v;throw Object.assign(new Error(v.reason),{code:v.code});}return v.value;};
 const expect=async(name,fn,code='22023')=>{let actual;try{await fn();}catch(e){actual=e.code;}check(name,actual,code);};
 const plan=(tree,changes)=>pg.scalar(`select taskfold_private.plan_child_repair(${json(tree)},${json(changes)})`);
 const project=randomUUID();await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(project)},${lit(owner.id)},'Synthetic repair workshop')`);
 const seed=async(tree,p=project)=>{const id=randomUUID();await pg.raw(`insert into public.tasks(id,user_id,project_id,title,subtasks) values(${lit(id)},${lit(owner.id)},${p?lit(p):'null'},'Repair source',${json(tree)})`);return id;};
 const row=id=>pg.scalar(`select to_jsonb(t) from public.tasks t where id=${lit(id)}`);
 const state=()=>pg.scalar(`select jsonb_build_object('roots',(select jsonb_agg(to_jsonb(t) order by id) from public.tasks t),'projections',(select coalesce(jsonb_agg(to_jsonb(p)),'[]') from taskfold_private.child_task_projections p),'records',(select coalesce(jsonb_agg(to_jsonb(r)),'[]') from taskfold_private.child_task_records r),'authority',(select coalesce(jsonb_agg(to_jsonb(a)),'[]') from taskfold_private.child_task_record_authority a),'history',(select count(*) from public.task_node_activity),'receipts',(select count(*) from taskfold_private.child_task_adoptions))`);
 const review=async(id,who='owner')=>run(`public.taskfold_review_child_adoption(${lit(id)},${lit((await row(id)).task_generation)})`,who);
 const body=(r,changes)=>Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,r[k]]).concat([['changes',changes]]));
 const preview=(b,who='owner')=>run(`public.taskfold_preview_child_repair(${json(b)})`,who);
 const assign=(path,reference)=>({kind:'assign_reference',path,reference});
 const wrap=(path,reference,title)=>({kind:'wrap_item',path,reference,title});
 const rootList={kind:'make_root_list',path:[]};
 const childList=path=>({kind:'make_children_list',path});
 const move=(path,parent,index)=>({kind:'move_item',path,parent,index});
 const opaque={title:'Retain notes',future:{'é':1,'e\u0301':2,flag:false,empty:null},id:7};
 let p=await plan(opaque,[rootList,assign([0],'fixed')]);
 check('root object becomes list without field loss',p.proposed_tree,[{...opaque,id:'fixed'}]);check('root and identity proposal validates',p.proposal_valid);
 check('operations remain explicit and ordered',p.steps.map(s=>[s.ordinal,s.kind,s.path]),[[1,'make_root_list',[]],[2,'assign_reference',[0]]]);
 for(const value of ['Original task text',42,false,null,[1,'two']]){p=await plan([value],[wrap([0],'wrapped','Reviewed title')]);check('scalar wrapper retains '+JSON.stringify(value),p.proposed_tree,[{id:'wrapped',title:'Reviewed title',legacy_original:value}]);check('wrapper validates '+JSON.stringify(value),p.proposal_valid);}
 p=await plan([{id:'a',subtasks:{id:'b',notes:'Keep child'}}],[childList([0])]);check('malformed child object is retained in list',p.proposed_tree,[{id:'a',subtasks:[{id:'b',notes:'Keep child'}]}]);check('child object proposal validates',p.proposal_valid);
 p=await plan([{id:'a',subtasks:'Old child text'}],[childList([0]),wrap([0,0],'b','Reviewed child')]);check('nested scalar is retained',p.proposed_tree[0].subtasks[0].legacy_original,'Old child text');check('nested scalar validates',p.proposal_valid);
 p=await plan([{id:'é'},{id:'e\u0301',notes:'Independent task'}],[assign([1],'new-reference')]);check('explicit duplicate repair retains other raw ID',p.proposed_tree[0].id,'é');check('explicit duplicate repair validates',p.proposal_valid);
 p=await plan([{id:'same'},{id:'same'},{id:8}],[assign([2],'fixed')]);check('partial proposal stays invalid',p.proposal_valid,false);check('partial proposal reports remaining duplicate',p.remaining_issue,'duplicate_identity');check('partial proposal makes no misleading node total',p.node_count,null);
 p=await plan([{id:'same'},{id:'same'}],[assign([1],'same-again'),assign([0],'same-again')]);check('new collisions are detected',p.remaining_issue,'duplicate_identity');
 const tree=[{id:'a',notes:'Move intact',subtasks:[{id:'aa',opaque:[1,false]}]},{id:'b'},{id:'c',subtasks:null}];
 p=await plan(tree,[move([0],[2],0)]);check('destination position adjusts after earlier source removal',p.proposed_tree,[{id:'b'},{id:'c',subtasks:[tree[0]]}]);check('null child list becomes explicit list on move',p.proposal_valid);
 p=await plan(tree,[move([0,0],[],3)]);check('nested branch can lift to root end',p.proposed_tree,[{...tree[0],subtasks:[]},tree[1],tree[2],tree[0].subtasks[0]]);
 p=await plan(tree,[move([2],[],0)]);check('root move retains exact subtree',p.proposed_tree,[tree[2],tree[0],tree[1]]);
 p=await plan([{id:'a',subtasks:[{id:'x'},{id:'y'},{id:'z'}]}],[move([0,0],[0],2)]);check('same-parent index is defined after removal',p.proposed_tree[0].subtasks.map(n=>n.id),['y','z','x']);
 p=await plan(tree,[move([0],[1],0)]);check('missing child list created only for explicit move',p.proposed_tree,[{id:'b',subtasks:[tree[0]]},tree[2]]);
 let deep={id:'depth25',notes:'deep preserved'};for(let i=24;i>=1;i--)deep={id:'depth'+i,subtasks:[deep]};
 p=await plan([deep],[move(Array(25).fill(0),[],1)]);check('depth25 branch lifts without data loss',p.proposal_valid);check('deep lifted value intact',p.proposed_tree[1],{id:'depth25',notes:'deep preserved'});check('deep repair retains all 25 tasks',p.node_count,25);
 p=await plan(Array.from({length:1001},(_,i)=>({id:'node'+i})),[assign([0],'changed')]);check('node overflow remains an explicit unresolved issue',p.remaining_issue,'node_limit');check('node overflow proposal retains every task',p.proposed_tree.length,1001);check('node overflow has no partial success count',p.node_count,null);
 p=await plan(tree,[move([0],[1],0),move([0,0],[],1)]);check('sequential paths refer to preceding proposal',p.proposed_tree,[{id:'b',subtasks:[]},tree[0],tree[2]]);
 p=await plan('Root text',[rootList,wrap([0],'new','Reviewed root')]);check('scalar root survives two explicit operations',p.proposed_tree[0].legacy_original,'Root text');
 p=await plan([{id:'a',future:{id:'a',subtasks:'opaque'}}],[assign([0],'new')]);check('repair never descends into unknown fields',p.proposed_tree[0].future,{id:'a',subtasks:'opaque'});
 const invalid=[
 ['empty operations',tree,[]],['too many operations',tree,Array(65).fill(assign([0],'x'))],['unknown operation',tree,[{kind:'drop',path:[0]}]],
 ['extra operation fields',tree,[{...assign([0],'x'),delete:true}]],['missing operation fields',tree,[{kind:'wrap_item',path:[0]}]],
 ['negative position',tree,[assign([-1],'x')]],['decimal position',tree,[assign([0.5],'x')]],['string position',tree,[assign(['0'],'x')]],
 ['out of range position',tree,[assign([3],'x')]],['position above bound',tree,[assign([1000],'x')]],['too deep path',tree,[assign(Array(65).fill(0),'x')]],
 ['scalar path',tree,[{kind:'assign_reference',path:0,reference:'x'}]],['scalar ancestor',['old'],[assign([0,0],'x')]],['missing child list',tree,[assign([1,0],'x')]],
 ['empty reference',tree,[assign([0],'')]],['oversized reference',tree,[assign([0],'é'.repeat(65))]],['numeric reference',tree,[assign([0],9)]],
 ['same reference',tree,[assign([0],'a')]],['assign scalar',['old'],[assign([0],'x')]],['wrap object',tree,[wrap([0],'x','Title')]],
 ['blank title',['old'],[wrap([0],'x','   ')]],['linebreak-only title',['old'],[wrap([0],'x','\n\t')]],['long title',['old'],[wrap([0],'x','a'.repeat(501))]],['multibyte title limit',['old'],[wrap([0],'x','🎉'.repeat(251))]],
 ['root wrapper on list',tree,[rootList]],['root wrapper on null',null,[rootList]],['root wrapper needs root path',tree,[{...rootList,path:[0]}]],
 ['reference needs node path',tree,[assign([],'x')]],['missing children',tree,[childList([1])]],['null children',tree,[childList([2])]],['array children',tree,[childList([0])]],
 ['move into own branch',tree,[move([0],[0,0],0)]],['move into self',tree,[move([0],[0],0)]],['move after invalid position',tree,[move([0],[],3)]],
 ['move negative index',tree,[move([0],[],-1)]],['move fractional index',tree,[move([0],[],0.2)]],['move string index',tree,[move([0],[],'0')]],['move bound',tree,[move([0],[],1001)]],
 ['move to scalar parent',['old',{id:'b'}],[move([1],[0],0)]],['move to malformed children',[{id:'a',subtasks:'old'},{id:'b'}],[move([1],[0],0)]],
 ['move noop',tree,[move([1],[],1)]],['later move noop',tree,[assign([0],'new'),move([1],[],1)]]
 ];
 for(const [name,source,changes] of invalid)await expect(name,()=>plan(source,changes));
 await expect('oversized source rejected without truncation',()=>pg.raw(`select taskfold_private.plan_child_repair(jsonb_build_array(jsonb_build_object('id','a','notes',repeat('x',2000000))),${json([assign([0],'b')])})`));
 await expect('oversized request rejected',()=>pg.raw(`select taskfold_private.plan_child_repair('[]',jsonb_build_array(jsonb_build_object('kind','wrap_item','path','[0]'::jsonb,'reference','a','title',repeat('x',65536))))`));
 const sourceID=await seed([opaque]),r=await reviewEnable();
 async function reviewEnable(){check('repair rollout defaults off',await pg.scalar('select to_jsonb(repair_reviews_enabled) from taskfold_private.child_task_record_config where singleton'),false);await pg.raw('update taskfold_private.child_task_record_config set adoption_enabled=true');return review(sourceID);}
 const b=body(r,[assign([0],'reviewed')]);await expect('repair gate denies before preview',()=>preview(b),'PT503');
 await pg.raw('update taskfold_private.child_task_record_config set repair_reviews_enabled=true');
 const before=await state(),v=await preview(b);report.preview=v;
 check('preview includes exact original',v.original_tree,[opaque]);check('preview contains only reviewed proposal',v.proposed_tree,[{...opaque,id:'reviewed'}]);check('preview is valid',v.proposal_valid);check('valid preview still cannot mutate',v.mutation_available,false);
 check('unindexed preview has no custody success claim',v.custody_blocker,null);
 check('preview makes no source index history or receipt writes',await state(),before);check('repeat preview digest stable',(await preview(b)).repair_digest,v.repair_digest);check('repair digest is full sha256',/^[0-9a-f]{64}$/.test(v.repair_digest));
 await pg.raw(`update public.tasks set title='A changed root title' where id=${lit(sourceID)}`);check('full-root title change invalidates repair digest',(await preview(b)).repair_digest!==v.repair_digest);
 await expect('foreign account blocked by caller RLS',()=>preview(b,'outside'),'42501');await expect('different account in body denied',()=>preview({...b,account:users.outside.id}),'42501');
 await expect('unknown top-level fields refused',()=>preview({...b,proposed_tree:[]}));await expect('invalid digest refused',()=>preview({...b,review_digest:'bad'}));
 await expect('stale review digest refused',()=>preview({...b,review_digest:'0'.repeat(64)}),'PT409');await expect('stale project refused',()=>preview({...b,project_id:null}),'PT409');await expect('stale workspace refused',()=>preview({...b,workspace_id:randomUUID()}),'PT409');await expect('stale generation refused',()=>preview({...b,task_generation:randomUUID()}),'42501');
 await pg.raw(`update public.tasks set subtasks='[{"id":4,"notes":"Newer work"}]' where id=${lit(sourceID)}`);await expect('changed children reject old review',()=>preview(b),'PT409');check('stale preview preserves newer source',(await row(sourceID)).subtasks,[{id:4,notes:'Newer work'}]);
 const lockBody=body(await review(sourceID),[assign([0],'new')]),holder=await pg.hold(`select 1 from public.tasks where id=${lit(sourceID)} for update`);
 try{await expect('concurrent root writer refuses preview without waiting',()=>preview(lockBody),'55P03');}finally{await holder.release('rollback');}
 const partialID=await seed([{id:'duplicate'},{id:'duplicate'},{id:2}]);const partialState=await state();const partial=await preview(body(await review(partialID),[assign([2],'new')]));check('service returns unresolved proposal honestly',partial.proposal_valid,false);check('service names remaining repair issue',partial.remaining_issue,'duplicate_identity');check('invalid preview is completely read-only',await state(),partialState);
 const archivedID=await seed([opaque]);await pg.raw(`update public.projects set is_archived=true where id=${lit(project)}`);check('archived source may be reviewed without mutation',(await preview(body(await review(archivedID),[assign([0],'archived')]))).mutation_available,false);await pg.raw(`update public.projects set is_archived=false where id=${lit(project)}`);
 const indexed=await seed([{id:'a',notes:'Original'}]);await pg.raw(`select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(indexed)};update taskfold_private.child_task_records set fields=fields||'{"notes":"Other saved copy"}' where task_id=${lit(indexed)}`);
 const indexedState=await state(),iv=await preview(body(await review(indexed),[assign([0],'replacement')]));check('indexed copies require separate custody repair',iv.custody_blocker,'indexed_custody');check('indexed custody blocks mutation',iv.mutation_available,false);check('conflicting copies retained exactly',await state(),indexedState);
 const team=randomUUID(),tp=randomUUID();await pg.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'Repair team');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin'),(${lit(team)},${lit(users.outside.id)},'guest');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true;insert into public.projects(id,user_id,name) values(${lit(tp)},${lit(owner.id)},'Shared source');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(tp)},${lit(team)},'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(tp)},${lit(team)},${lit(users.outside.id)},'viewer')`);
 const shared=await seed([opaque],tp),sharedBody=body(await review(shared,'outside'),[assign([0],'fixed')]);check('current shared viewer may inspect proposal',(await preview(sharedBody,'outside')).mutation_available,false);
 await pg.raw(`delete from taskfold_private.team_project_grants where project_id=${lit(tp)} and user_id=${lit(users.outside.id)}`);await expect('revoked shared viewer cannot inspect stale preview',()=>preview(sharedBody,'outside'),'42501');
 await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=false');await expect('shared read rollout enforced by caller RLS',()=>preview(bodyFromShared()),'42501');function bodyFromShared(){return {...sharedBody,account:owner.id};}await pg.raw('update taskfold_private.team_project_config set native_reads_enabled=true');
 await pg.raw(`update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id=${lit(owner.session)}`);await expect('expired session cannot preview',()=>preview(lockBody),'28000');await pg.raw(`update auth.sessions set not_after=null where id=${lit(owner.session)}`);
 await pg.raw('update taskfold_private.child_task_record_config set adoption_enabled=false');await expect('parent rollout enforced',()=>preview(lockBody),'PT503');await pg.raw('update taskfold_private.child_task_record_config set adoption_enabled=true');
 // JSONB precision and Unicode are checked inside PostgreSQL, never JS numbers.
 const rawID=randomUUID();await pg.raw(`insert into public.tasks(id,user_id,title,subtasks) values(${lit(rawID)},${lit(owner.id)},'Opaque precision','[{"id":9,"number":9007199254740993,"large":1e1000,"é":1,"é":2}]')`);
 const rawBody=body(await review(rawID),[assign([0],'exact')]);
 const rawReply=await pg.raw(`begin;set local request.jwt.claim.sub=${lit(owner.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:owner.id,session_id:owner.session}))};set local role authenticated;select public.taskfold_preview_child_repair(${json(rawBody)})::text;commit;`);
 const rawHash=createHash('sha256').update(rawReply).digest('hex');report.opaqueReplySHA256=rawHash;
 const stored=await pg.scalar(`select jsonb_build_object('int',subtasks->0->>'number','huge',length(subtasks->0->>'large'),'distinct_keys',(subtasks->0->>'é')<> (subtasks->0->>'é')) from public.tasks where id=${lit(rawID)}`);
 check('source integer remains exact',stored.int,'9007199254740993');check('large original number retains precision',stored.huge,1001);check('distinct Unicode keys remain distinct',stored.distinct_keys);
 check('raw preview keeps exact integer on both sides',(rawReply.match(/9007199254740993/g)||[]).length,2);check('raw preview keeps huge number on both sides',(rawReply.match(new RegExp('1'+'0'.repeat(1000),'g'))||[]).length,2);
 await writeFile(process.env.TASKFOLD_REPAIR_RAW_REPLY??'/tmp/taskfold-child-repair-opaque-reply.json',rawReply+'\n');
 const sqlNull=await seed(null);await pg.raw(`update public.tasks set subtasks=null where id=${lit(sqlNull)}`);const nbody=body(await review(sqlNull),[rootList]);await expect('SQL null needs no manufactured task',()=>preview(nbody));check('SQL null original distinction preserved',await pg.scalar(`select to_jsonb(subtasks is null) from public.tasks where id=${lit(sqlNull)}`));
 for(const role of ['anon','service_role'])check(role+' cannot call public preview',await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},'public.taskfold_preview_child_repair(jsonb)','EXECUTE'))`),false);
 for(const role of ['anon','authenticated','service_role'])for(const helper of ['child_repair_path(jsonb,jsonb)','plan_child_repair(jsonb,jsonb)'])check(role+' cannot call pure helper '+helper,await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},${lit('taskfold_private.'+helper)},'EXECUTE'))`),false);
 check('public preview is caller RLS invoker',await pg.scalar("select to_jsonb(not prosecdef) from pg_proc where oid='public.taskfold_preview_child_repair(jsonb)'::regprocedure"));
 report.finalAdvisors=await pg.advisors();check('no new advisor findings',report.finalAdvisors,report.baselineAdvisors);report.passed=true;
} catch(e){report.failure={code:e.code,message:e.message};process.exitCode=1;} finally {if(pg)report.fixtureRemoved=await pg.close();await writeFile(process.env.TASKFOLD_REPAIR_REPORT??'/tmp/taskfold-child-repair-preview.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:report.passed??false,checks:Object.keys(report.checks).length,failure:report.failure,diagnostic:report.migrationDiagnostic??(report.failure?report.lastExpectedDiagnostic:undefined),fixtureRemoved:report.fixtureRemoved}));}
