import assert from 'node:assert/strict';
import {createHash,randomUUID} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadMixedTaskCompletionDependencies,mixedTaskCompletionMigration} from './mixed-task-completion-schema.mjs';
const sql=await readFile(new URL('../../supabase/migrations/'+mixedTaskCompletionMigration,import.meta.url),'utf8');
const report={checks:{},deployed:false,candidateSHA256:createHash('sha256').update(sql).digest('hex')};
const check=(name,a,b)=>{assert.deepEqual(a,b,name);report.checks[name]=true;};
const json=x=>lit(JSON.stringify(x))+'::jsonb';let pg;
try {
 report.stage='owned schema and advisors';pg=await createPostgresFixture({advisors:true});await loadMixedTaskCompletionDependencies(pg);
 report.baselineAdvisors=await pg.advisors();
 const schema=await pg.scalar(`create temp table load_result(code text,reason text,context text);do $load$declare c text;begin begin execute ${lit(sql)};insert into load_result values(null,null,null);exception when others then get stacked diagnostics c=PG_EXCEPTION_CONTEXT;insert into load_result values(sqlstate,sqlerrm,c);end;end$load$;select to_jsonb(r) from load_result r;`);
 report.schemaDiagnostic=schema;if(schema.code)throw new Error(schema.reason);
 const people=Object.fromEntries(['owner','writer','viewer','outside'].map(name=>[name,{id:randomUUID(),session:randomUUID()}]));
 for(const u of Object.values(people))await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(u.id)},${lit(u.id+'@example.invalid')},now());insert into public.profiles(user_id) values(${lit(u.id)});insert into auth.sessions(id,user_id) values(${lit(u.session)},${lit(u.id)});`);
 const owner=people.owner,project=randomUUID(),team=randomUUID(),teamProject=randomUUID();
 await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(project)},${lit(owner.id)},'Synthetic mixed project');insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'Synthetic mixed team');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin'),(${lit(team)},${lit(people.writer.id)},'member'),(${lit(team)},${lit(people.viewer.id)},'member');insert into public.projects(id,user_id,name) values(${lit(teamProject)},${lit(owner.id)},'Synthetic team project');insert into taskfold_private.team_content_projects(team_id,project_id,visibility) values(${lit(team)},${lit(teamProject)},'private');insert into taskfold_private.team_project_grants(team_id,project_id,user_id,role) values(${lit(team)},${lit(teamProject)},${lit(people.writer.id)},'editor'),(${lit(team)},${lit(teamProject)},${lit(people.viewer.id)},'viewer');`);
 const exact=`'{"exact":9007199254740993,"large":1e1000,"é":1,"é":2}'::jsonb`;
 async function root({p=project,user=owner.id,recurring=false,heading=false}={}) {
  const id=randomUUID();await pg.raw(`insert into public.tasks(id,user_id,project_id,title,is_recurring,recurrence_pattern,due_date,is_heading,subtasks,source_metadata) values(${lit(id)},${lit(user)},${p?lit(p):'null'},'Synthetic selected root',${recurring},${recurring?`'{"type":"daily","interval":1}'::jsonb`:'null'},${recurring?"'2026-10-31'":'null'},${heading},jsonb_build_array(jsonb_build_object('id','child','title','Chosen child','completed',false,'completed_at',null,'taskfold_completion_v1',jsonb_build_object('epoch',gen_random_uuid(),'version',0),'future',${exact},'subtasks',null)),${exact});select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(id)};`);return id;
 }
 const row=id=>pg.scalar(`select coalesce((select to_jsonb(t) from public.tasks t where id=${lit(id)}),'null'::jsonb)`);
 const guardRoot=id=>pg.scalar(`select jsonb_build_object('task_id',t.id,'baseline',taskfold_private.completion_selection_root_baseline(t),'source_hash',taskfold_private.completion_selection_root_hash(t)) from public.tasks t where id=${lit(id)}`);
 const guardChild=id=>pg.scalar(`select jsonb_build_object('task_id',t.id,'task_generation',t.task_generation,'project_id',t.project_id,'node_key',n.node_key,'incarnation',n.incarnation,'revision',n.revision,'baseline',taskfold_private.child_task_completion_state(n.fields)) from public.tasks t join taskfold_private.child_task_records n on n.task_id=t.id where t.id=${lit(id)} and n.node_key='child'`);
 async function command(roots,children,{who='owner',action='complete',childFirst=false}={}) {
  const rg=await Promise.all(roots.map(guardRoot)),cg=await Promise.all(children.map(guardChild));
  const r=rg.filter(x=>x.baseline.completed!==(action==='complete')).map(x=>({kind:'root',request_id:randomUUID(),task_id:x.task_id}));
  const c=cg.filter(x=>(x.baseline.completed??false)!==(action==='complete')).map(x=>({kind:'child',command:{protocol:1,account:people[who].id,request_id:randomUUID(),...x,action}}));
  return {protocol:1,account:people[who].id,batch_id:randomUUID(),action,completed_at:'2026-10-31T09:00:00Z',input_zone:'Europe/Copenhagen',roots:rg,children:cg,items:childFirst?[...c,...r]:[...r,...c]};
 }
 const run=(b,{who='owner',session=people[who].session,fn='public.taskfold_complete_mixed_tasks',app='mixed-completion'}={})=>pg.scalar(`begin;set application_name=${lit(app)};create temp table result(value jsonb,code text,reason text,context text) on commit drop;grant all on result to authenticated;set local role authenticated;set local request.jwt.claim.sub=${lit(people[who].id)};set local request.jwt.claims=${lit(JSON.stringify({sub:people[who].id,session_id:session}))};do $op$declare ctx text;begin begin insert into result values(${fn}(${json(b)}),null,null,null);exception when others then get stacked diagnostics ctx=PG_EXCEPTION_CONTEXT;insert into result values(null,sqlstate,left(sqlerrm,200),ctx);end;end$op$;select jsonb_build_object('value',value,'code',code,'reason',reason,'context',context) from result;commit;`);
 const close=(b,options={})=>run(b,{...options,fn:'public.taskfold_close_mixed_completion'});
 report.stage='default gate and first atomic mixed completion';const first=await root(),second=await root({p:null});const initial=await command([first],[first,second],{childFirst:true});
 check('mixed completion disabled by default',(await run(initial)).code,'PT503');
 await pg.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true,mixed_completions_enabled=true');
 check('read enablement cannot enable mixed writes',(await run(initial)).code,'PT503');
 await pg.raw('update taskfold_private.child_task_record_config set mixed_completion_writes_enabled=true;update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_task_types_enabled=true');
 const applied=await run(initial);report.firstCommand=initial;report.firstReply=applied;check('root and children apply atomically',applied.code,null);
 check('receipt retains caller order',applied.value.receipts.map(x=>x.request_id),initial.items.map(x=>x.request_id??x.command.request_id));
 check('parent and both selected children complete',[(await row(first)).completed,(await row(first)).subtasks[0].completed,(await row(second)).subtasks[0].completed],[true,true,true]);
 check('unselected second parent stays open',(await row(second)).completed,false);
 check('temporary scope cleared',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.mixed_completion_scope'),0);
 report.stage='recurring private and shared roots';
 for(const [label,p,who] of [['private',project,'owner'],['shared',teamProject,'writer']]) {
  const id=await root({p,recurring:true}),b=await command([id],[id],{who,childFirst:true}),r=await run(b,{who});report[label+'RecurringReply']=r;check(label+' recurring root and child apply',r.code,null);
  const proof=r.value.receipts.find(x=>x.kind==='root'),next=await row(proof.successor.id);check(label+' creates one successor',proof.successor.state,'created');
  check(label+' successor is open with reset children',[next.completed,next.subtasks[0].completed,next.due_date],[false,false,'2026-11-01']);
  check(label+' original chosen child completed',(await row(id)).subtasks[0].completed,true);
  check(label+' successor creator is current actor',next.user_id,people[who].id);
  check(label+' successor children are independently readable',await pg.scalar(`select to_jsonb(state='ready') from taskfold_private.child_task_projections where task_id=${lit(next.id)}`),true);
 }

 const full=()=>pg.scalar(`select to_jsonb(encode(extensions.digest(convert_to(jsonb_build_array(
 (select jsonb_agg(to_jsonb(t) order by id) from public.tasks t),
 (select jsonb_agg(to_jsonb(n) order by task_id,node_key) from taskfold_private.child_task_records n),
 (select jsonb_agg(to_jsonb(p) order by task_id) from taskfold_private.child_task_projections p),
 (select jsonb_agg(to_jsonb(a) order by task_id) from taskfold_private.child_task_record_authority a),
 (select jsonb_agg(to_jsonb(a) order by sequence) from public.task_node_activity a),
 (select jsonb_agg(to_jsonb(g) order by task_id,generation) from taskfold_private.task_generations g),
 (select jsonb_agg(to_jsonb(e) order by team_id,request_id) from taskfold_private.team_task_edits e),
 (select jsonb_agg(to_jsonb(e) order by actor_id,request_id) from taskfold_private.child_task_completion_receipts e),
 (select jsonb_agg(to_jsonb(e) order by actor_id,request_id) from taskfold_private.child_task_completion_closures e),
 (select jsonb_agg(to_jsonb(b) order by actor_id,batch_id) from taskfold_private.mixed_completion_batches b),
 (select jsonb_agg(to_jsonb(m) order by actor_id,request_id) from taskfold_private.mixed_completion_members m),
 (select jsonb_agg(to_jsonb(v) order by transaction_id,actor_id,request_id) from taskfold_private.mixed_completion_scope v)
 )::text,'UTF8'),'sha256'),'hex'))`);
 async function unchanged(name,b,code,options={}) {const before=await full(),r=await run(b,options);if(r.code!==code)report[name+'Diagnostic']=r;check(name,r.code,code);check(name+' leaves every task/node/history/receipt unchanged',await full(),before);}
 const withoutReplay=value=>Array.isArray(value)?value.map(withoutReplay):value&&typeof value==='object'?Object.fromEntries(Object.entries(value).filter(([k])=>k!=='replayed').map(([k,v])=>[k,withoutReplay(v)])):value;
 const legacy=(id,action='complete',request_id=randomUUID(),undo_of=null)=>guardChild(id).then(g=>({protocol:1,account:owner.id,request_id,...g,action,...(undo_of?{undo_of}:{})})).then(c=>{if(undo_of)delete c.baseline;return c;});
 report.stage='exact replay and whole-request identity';
 let before=await full(),replay=await run(initial);check('exact retry preserves entire original confirmation',withoutReplay(replay.value),withoutReplay(applied.value));check('exact retry sets every replay marker',[replay.value.replayed,...replay.value.receipts.map(x=>x.replayed),...replay.value.receipts.filter(x=>x.kind==='child').map(x=>x.receipt.replayed)].every(Boolean),true);check('exact retry never writes again',await full(),before);
 const edited=structuredClone(initial);edited.completed_at='2026-10-31T10:00:00Z';await unchanged('same group identity with changed clock refused',edited,'PT409');
 const reused=await command([await root()],[]);reused.items[0].request_id=initial.items[0].command.request_id;await unchanged('member from another mixed selection cannot be adopted',reused,'PT409');
 report.stage='reopen and selected no-op guards';
 const reopen=await command([first],[first,second],{action:'reopen'}),reopened=await run(reopen);report.reopenReply=reopened;check('mixed reopen succeeds',reopened.code,null);check('mixed reopen changes every requested state',[(await row(first)).completed,(await row(first)).subtasks[0].completed,(await row(second)).subtasks[0].completed],[false,false,false]);
 const openRoot=await root(),doneRoot=await root();await pg.raw(`update public.tasks set completed=true where id=${lit(doneRoot)}`);
 const rootNoOp=await command([doneRoot],[openRoot]);check('no-op parent has no write member',rootNoOp.items.map(x=>x.kind),['child']);
 await pg.raw(`update public.tasks set completed=false where id=${lit(doneRoot)}`);await unchanged('changed selected no-op parent refuses entire action',rootNoOp,'PT409');
 const doneChild=await root();let c=await legacy(doneChild);check('prepare selected completed child',(await run(c,{fn:'public.taskfold_complete_child_task'})).code,null);
 const childNoOp=await command([openRoot],[doneChild]);check('no-op child has no write member',childNoOp.items.map(x=>x.kind),['root']);
 c=await legacy(doneChild,'reopen');check('change selected no-op child before send',(await run(c,{fn:'public.taskfold_complete_child_task'})).code,null);await unchanged('changed selected no-op child refuses entire action',childNoOp,'PT409');
 const heading=await root({heading:true}),ordinary=await root(),headingGroup=await command([ordinary],[heading]);check('child below an unselected heading remains actionable',(await run(headingGroup)).code,null);check('heading itself stays open',(await row(heading)).completed,false);
 report.stage='stale later member cannot leave earlier parent/successor writes';
 const repeatRollback=await root({recurring:true}),staleChild=await root(),stale=await command([repeatRollback],[staleChild]);c=await legacy(staleChild);await run(c,{fn:'public.taskfold_complete_child_task'});await unchanged('stale child refuses root and successor together',stale,'PT409');
 const denied=await root({user:people.outside.id,p:null}),permitted=await root();await unchanged('later inaccessible branch refuses whole action',await command([permitted],[denied]),'42501');
 const sharedDenied=await root({p:teamProject});await unchanged('shared viewer cannot perform mixed selection',await command([sharedDenied],[sharedDenied],{who:'viewer'}),'42501',{who:'viewer'});
 const archivedRoot=await root(),archiveBody=await command([archivedRoot],[archivedRoot]);await pg.raw(`update public.projects set is_archived=true where id=${lit(project)}`);await unchanged('archived source project refuses complete selection',archiveBody,'PT409');await pg.raw(`update public.projects set is_archived=false where id=${lit(project)}`);
 report.stage='identity reservation and rollback inside legacy APIs';
 const undoSource=await root(),undoBody=await command([undoSource],[undoSource]);check('prepare certified-undo boundary',(await run(undoBody)).code,null);
 const originalChild=undoBody.items.find(x=>x.kind==='child').command;
 await unchanged('individual certified Undo cannot reverse one mixed member',await legacy(undoSource,'undo',randomUUID(),originalChild.request_id),'PT409',{fn:'public.taskfold_complete_child_task'});
 const individual=await root(),individualCommand=await legacy(individual);check('prepare used individual request',(await run(individualCommand,{fn:'public.taskfold_complete_child_task'})).code,null);
 const used=await command([await root()],[]);used.items[0].request_id=individualCommand.request_id;await unchanged('mixed group cannot adopt individual request identity',used,'PT409');
 const closedRoot=await root(),closed=await command([closedRoot],[closedRoot]);before=await full();const closedReply=await close(closed);check('unknown group closes metadata only',closedReply.value.outcome,'closed');check('closure does not change root or child',[(await row(closedRoot)).completed,(await row(closedRoot)).subtasks[0].completed],[false,false]);
 await unchanged('closed group never applies',closed,'PT410');
 for(const request of [closed.items[0].request_id,closed.items[1].command.request_id])await unchanged('legacy child cannot adopt closed mixed member '+request,await legacy(closedRoot,'complete',request),'PT409',{fn:'public.taskfold_complete_child_task'});
 check('repeated close preserves terminal outcome',(await close(closed)).value.outcome,'closed');
 report.stage='busy resources and concurrency';
 const busyRoot=await root(),busyOther=await root(),busy=await command([busyOther],[busyRoot]);let holder=await pg.hold(`select id from public.tasks where id=${lit(busyRoot)} for update;`);
 try{await unchanged('busy later root refuses without partial writes',busy,'55P03');}finally{await holder.release('rollback');}
 check('same original request works after busy resource releases',(await run(busy)).code,null);
 const nonceRoot=await root(),nonce=await command([nonceRoot],[nonceRoot]),nonceID=nonce.items[1].command.request_id;
 holder=await pg.hold(`select pg_advisory_xact_lock(hashtextextended(${lit(owner.id+':'+nonceID)},73920));`);
 try{await unchanged('busy member reservation refuses atomically',nonce,'55P03');}finally{await holder.release('rollback');}
 check('member reservation can retry exact original body',(await run(nonce)).code,null);
 const competing=await root(),left=await command([competing],[competing]),right=await command([competing],[competing]);const outcomes=await Promise.all([run(left),run(right)]);check('concurrent same-state writers have one winner',outcomes.filter(x=>x.code===null).length,1);check('concurrent loser is refused',[null,'PT409','55P03'].includes(outcomes.find(x=>x.code!==null).code),true);
 report.stage='recurring families, successors and source preservation';
 const existingParent=await root({recurring:true}),existingFirst=await command([existingParent],[]),existingReply=await run(existingFirst),existingNext=existingReply.value.receipts[0].successor.id;
 const existingChild=await root(); // Reopen the root directly as a new actor action, without removing its next occurrence.
 await pg.raw(`update public.tasks set completed=false where id=${lit(existingParent)}`);
 const existingAgain=await command([existingParent],[existingChild]),existingResult=await run(existingAgain);check('recompletion preserves existing next occurrence',existingResult.value.receipts.find(x=>x.kind==='root').successor.state,'existing');check('existing occurrence not duplicated',await pg.scalar(`select to_jsonb(count(*)) from public.tasks where recurrence_parent_id=${lit(existingParent)} and due_date='2026-11-01'`),1);
 check('opaque successor metadata remains exact in PostgreSQL',await pg.scalar(`select to_jsonb(source_metadata->'exact'='9007199254740993'::jsonb and source_metadata->'large'='1e1000'::jsonb and source_metadata->'é'='1'::jsonb and source_metadata->'é'='2'::jsonb) from public.tasks where id=${lit(existingNext)}`),true);
 const familyChild=await command([existingNext],[]);await pg.raw(`update public.tasks set project_id=null where id=${lit(existingParent)}`);await unchanged('changed series parent identity invalidates saved source',familyChild,'PT409');
 const retiredParent=await root({recurring:true}),retiredReply=await run(await command([retiredParent],[])),retiredNext=retiredReply.value.receipts[0].successor.id;
 await pg.raw(`delete from public.tasks where id=${lit(retiredNext)};update public.tasks set completed=false where id=${lit(retiredParent)}`);
 const retiredAgain=await run(await command([retiredParent],[]));check('deleted occurrence is not recreated',retiredAgain.value.receipts[0].successor.state,'retired');check('retired occurrence stays deleted',await row(retiredNext),null);
 report.stage='legacy roots and rollback after root writes';
 const nullable=await root();await pg.raw(`update public.tasks set is_heading=null where id=${lit(nullable)}`);
 check('legacy null heading can complete',(await run(await command([nullable],[nullable]))).code,null);
 check('legacy null flags stay unchanged',[(await row(nullable)).is_heading,(await row(nullable)).is_recurring],[null,false]);
 const childOnly=await root();check('child-only envelope succeeds',(await run(await command([],[childOnly]))).code,null);
 const lateRoot=await root({recurring:true}),lateChild=await root();await pg.raw(`select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(lateRoot)}`);const late=await command([lateRoot],[lateChild]);
 await pg.raw(`create function taskfold_private.synthetic_late_failure() returns trigger language plpgsql as $f$begin raise exception using errcode='54000',message='Synthetic late receipt failure';end$f$;create trigger synthetic_late_failure before insert on taskfold_private.child_task_completion_receipts for each row execute function taskfold_private.synthetic_late_failure();`);
 await unchanged('late child receipt failure rolls back root successor and projections',late,'54000');
 await pg.raw('drop trigger synthetic_late_failure on taskfold_private.child_task_completion_receipts;drop function taskfold_private.synthetic_late_failure()');
 check('exact original applies after late failure removed',(await run(late)).code,null);
 report.stage='foreign occurrence identity';
 const inboxRepeat=await root({p:null,recurring:true});
 const planned=await pg.scalar(`select taskfold_private.automation_recurrence_plan(to_jsonb(t),'2026-10-31T09:00:00Z','Europe/Copenhagen') from public.tasks t where id=${lit(inboxRepeat)}`);
 await pg.raw(`insert into public.tasks(id,user_id,title,recurrence_parent_id,due_date) values(${lit(planned.id)},${lit(people.outside.id)},'Foreign private occurrence',${lit(inboxRepeat)},${lit(planned.due_date)})`);
 await unchanged('foreign Inbox occurrence cannot be adopted or exposed',await command([inboxRepeat],[]),'PT409');
 report.stage='malformed complete-selection contracts';
 const valid=await command([await root()],[await root()]);
 for(const [name,mutate] of [['unknown body key',b=>b.unexpected=true],['wrong protocol',b=>b.protocol=2],['duplicate root observation',b=>b.roots.push(b.roots[0])],['duplicate child observation',b=>b.children.push(b.children[0])],['duplicate member request',b=>b.items[0].request_id=b.items[1].command.request_id],['missing changed member',b=>b.items.pop()],['mixed action',b=>b.items[1].command.action='reopen'],['unknown member kind',b=>b.items[0].kind='other'],['wrong child observation',b=>b.children[0].incarnation=randomUUID()],['invalid zone',b=>b.input_zone='Not/AZone'],['invalid clock',b=>b.completed_at='now']]){const bad=structuredClone(valid);mutate(bad);await unchanged(name+' refused',bad,'22023');}
 report.stage='paused and lost-access metadata outcome recovery';
 await pg.raw('update taskfold_private.child_task_record_config set reads_enabled=false,edits_enabled=false,completions_enabled=false,mixed_completions_enabled=false,mixed_completion_writes_enabled=false');
 before=await full();check('applied exact retry survives rollout pause',(await run(initial)).value.outcome,'applied');check('applied metadata close survives rollout pause',(await close(initial)).value.outcome,'applied');check('paused known recovery is metadata-only',await full(),before);
 const unknownPaused={...valid,batch_id:randomUUID(),items:valid.items.map(x=>x.kind==='root'?{...x,request_id:randomUUID()}:{...x,command:{...x.command,request_id:randomUUID()}})};check('unknown original can be closed with rollout paused',(await close(unknownPaused)).value.outcome,'closed');
 await pg.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true,mixed_completions_enabled=true,mixed_completion_writes_enabled=true');
 report.stage='bounded source and effect budgets';
 const big=await root();await pg.raw(`update public.tasks set description=repeat('x',2000000) where id=${lit(big)}`);await unchanged('individual source budget',await command([big],[]),'54000');
 const aggregate=[];for(let i=0;i<3;i++){const id=await root();await pg.raw(`update public.tasks set description=repeat('x',1450000) where id=${lit(id)}`);aggregate.push(id);}await unchanged('aggregate source budget',await command(aggregate,[]),'54000');
 report.stage='record-authoritative mixed completion';
 const authoritative=await root({recurring:true});await pg.raw(`select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(authoritative)}`);
 const authoritativeReply=await run(await command([authoritative],[authoritative]));check('record-authoritative parent and child complete together',authoritativeReply.code,null);
 check('record-authoritative mirror stays exact',await pg.scalar(`select to_jsonb(t.subtasks=taskfold_private.materialize_child_task_records(t.id,a.root_kind)) from public.tasks t join taskfold_private.child_task_record_authority a on a.task_id=t.id where t.id=${lit(authoritative)}`),true);
 check('authoritative parent and chosen child are completed',[(await row(authoritative)).completed,(await row(authoritative)).subtasks[0].completed],[true,true]);
 check('authoritative source produces an open future child',(await row(authoritativeReply.value.receipts.find(x=>x.kind==='root').successor.id)).subtasks[0].completed,false);
 report.stage='root timestamp confirmation';
 const clockRoot=await root(),clockBody=await command([clockRoot],[]);
 await pg.raw(`create function taskfold_private.synthetic_clock_tamper() returns trigger language plpgsql as $f$begin if new.id=${lit(clockRoot)}::uuid and new.completed then new.completed_at=new.completed_at+interval '1 hour';end if;return new;end$f$;create trigger zz_synthetic_clock_tamper before update on public.tasks for each row execute function taskfold_private.synthetic_clock_tamper();`);
 await unchanged('changed completion clock cannot produce a confirmation',clockBody,'PT409');
 await pg.raw('drop trigger zz_synthetic_clock_tamper on public.tasks;drop function taskfold_private.synthetic_clock_tamper()');
 check('saved original completion clock succeeds after tamper removed',(await run(clockBody)).code,null);
 check('parent completion keeps the original group clock',await pg.scalar(`select to_jsonb(completed_at='2026-10-31T09:00:00Z'::timestamptz) from public.tasks where id=${lit(clockRoot)}`),true);
 report.stage='selection boundaries and unrelated ordinary edits';
 const boundaryRoots=[];for(let i=0;i<32;i++)boundaryRoots.push(await root());
 const boundaryBody=await command(boundaryRoots,[]);check('32-root selection applies atomically',(await run(boundaryBody)).code,null);check('all 32 roots completed',await pg.scalar(`select to_jsonb(count(*)=32 and bool_and(completed)) from public.tasks where id in(${boundaryRoots.map(lit).join(',')})`),true);
 const overBoundary=structuredClone(boundaryBody);overBoundary.batch_id=randomUUID();overBoundary.roots.push(boundaryBody.roots[0]);await unchanged('more than 32 selected observations refused',overBoundary,'22023');
 const unrelated=await root(),unrelatedBody=await command([unrelated],[]);await pg.raw(`update public.tasks set title='Keep newer unrelated title' where id=${lit(unrelated)}`);check('ordinary root admits unrelated source edit',(await run(unrelatedBody)).code,null);check('ordinary completion preserves newer title',(await row(unrelated)).title,'Keep newer unrelated title');
 report.stage='aggregate recurring effect budget';
 const effectRoots=[];for(let i=0;i<3;i++){
  const id=await root({recurring:true});
  await pg.raw(`update public.tasks set description=repeat('x',1315000),subtasks=(select jsonb_agg(jsonb_build_object('id','node-'||n,'title','Child','completed',false,'subtasks',null)) from generate_series(1,100)n) where id=${lit(id)};select taskfold_private.sync_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(id)}`);effectRoots.push(id);
 }
 check('effect fixture source fits aggregate budget',await pg.scalar(`select to_jsonb(sum(octet_length(to_jsonb(t)::text))<4000000) from public.tasks t where id in(${effectRoots.map(lit).join(',')})`),true);
 report.stage='aggregate effect prepare';const effectBody=await command(effectRoots,[]);report.stage='aggregate effect before hash';before=await full();report.stage='aggregate effect send';const effectReply=await run(effectBody);report.effectBudgetRefusal=effectReply;
 check('expanded recurring copies exceed aggregate effect budget',effectReply.code,'54000');check('aggregate effect refusal occurs after generated copies',effectReply.reason,'The next occurrences are too large for one selection');check('aggregate effect refusal rolls every copy and ledger back',await full(),before);
 report.stage='whole-request quota and lost-access recovery';
 const gone=await root(),goneBody=await command([gone],[]),goneReply=await run(goneBody);await pg.raw(`delete from public.tasks where id=${lit(gone)}`);
 before=await full();check('exact outcome remains recoverable after root deletion',withoutReplay((await run(goneBody)).value),withoutReplay(goneReply.value));check('deleted-root recovery changes no saved data',await full(),before);
 await pg.raw(`insert into taskfold_private.mixed_completion_batches(actor_id,batch_id,fingerprint,outcome) select ${lit(owner.id)},gen_random_uuid(),repeat('a',64),'closed' from generate_series(1,128)`);
 await unchanged('fresh group quota refuses all writes',await command([await root()],[]),'PT429');check('known outcome remains recoverable at quota',(await close(initial)).value.outcome,'applied');
 report.stage='private ledger security';
 for(const table of ['mixed_completion_batches','mixed_completion_members','mixed_completion_scope']){
  check(table+' has RLS',await pg.scalar(`select to_jsonb(relrowsecurity) from pg_class where oid=${lit('taskfold_private.'+table)}::regclass`),true);
  for(const role of ['anon','authenticated','service_role'])check(role+' has no direct '+table+' access',await pg.scalar(`select to_jsonb(has_table_privilege(${lit(role)},${lit('taskfold_private.'+table)},'select,insert,update,delete'))`),false);
 }
 for(const fn of ['taskfold_complete_mixed_tasks','taskfold_close_mixed_completion']){check(fn+' is a public invoker wrapper',await pg.scalar(`select to_jsonb(not prosecdef) from pg_proc where oid=${lit('public.'+fn+'(jsonb)')}::regprocedure`),true);check(fn+' refuses anonymous execute',await pg.scalar(`select to_jsonb(has_function_privilege('anon',${lit('public.'+fn+'(jsonb)')},'execute'))`),false);}
 for(const signature of ['completion_selection_task(uuid,boolean)','mixed_completion_legacy_identity(uuid,uuid)','guard_mixed_completion_identity()','validate_mixed_completion(jsonb,uuid)','guard_mixed_completion_children(jsonb)','mixed_completion_recipient(uuid,uuid,uuid,uuid)','mixed_completion_successor_children(jsonb,uuid,uuid,uuid,uuid)','apply_mixed_completion_root(jsonb,jsonb,jsonb)','mixed_completion_reply(taskfold_private.mixed_completion_batches,boolean)','mixed_completion_can_edit(public.tasks)'])for(const role of ['anon','authenticated','service_role'])check(role+' cannot execute private '+signature,await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},${lit('taskfold_private.'+signature)},'execute'))`),false);
 check('no transaction scope remains after all outcomes',await pg.scalar('select to_jsonb(count(*)) from taskfold_private.mixed_completion_scope'),0);

 report.stage='advisors';report.finalAdvisors=await pg.advisors();const old=new Set(report.baselineAdvisors.result.map(x=>x.cache_key));check('no added advisor findings',report.finalAdvisors.result.filter(x=>!old.has(x.cache_key)),[]);report.passed=true;console.log('PASS '+Object.keys(report.checks).length+' mixed task completion database checks');
} catch(error){report.passed=false;report.error={name:error.name,code:error.code??null,message:error.message,stack:error.stack};process.exitCode=1;console.error('FAIL '+report.stage+': '+error.message+' '+(error.code??''));}
finally {if(pg)report.containerRemoved=await pg.close();await writeFile(process.argv[2]??'/tmp/taskfold-mixed-task-completion.json',JSON.stringify(report,null,2)+'\n');}
