import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
const output=process.argv[2];assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));let runtime;
const report={sourceSHA256:createHash('sha256').update(await readFile(new URL(import.meta.url))).digest('hex'),checks:{},hostedChanges:false,normalGatesChanged:false};
const lit=x=>"'"+String(x).replaceAll("'","''")+"'",json=x=>lit(JSON.stringify(x))+'::jsonb';
const check=(n,v)=>{assert.equal(v,true,n);report.checks[n]=true;console.log('passed',n)};
const ok=(n,r,status=200)=>{if(r.status!==status)report.lastFailure={name:n,status:r.status,code:r.value?.code,message:r.value?.message};check(n,r.status===status);return r.value};
try{
 runtime=await createFullSchemaRuntime();report.migrations=runtime.migrations;report.images=runtime.images;
 const signup=()=>runtime.request('auth','/signup',{method:'POST',body:{email:'keep-'+randomUUID()+'@example.invalid',password:randomUUID()+'Aa42!'}});
 const owner=ok('owner signup',await signup()),other=ok('other signup',await signup()),account=owner.user.id,authorization=owner.access_token;
 const api=(path,body,token=authorization)=>runtime.request('rest',path,{method:'POST',authorization:token,body,includeText:true});
 const state=()=>runtime.raw("select jsonb_build_object('tasks',(select jsonb_agg(to_jsonb(t) order by id) from public.tasks t),'records',(select jsonb_agg(to_jsonb(t) order by task_id,node_key) from taskfold_private.child_task_records t),'projection',(select jsonb_agg(to_jsonb(t) order by task_id) from taskfold_private.child_task_projections t),'authority',(select jsonb_agg(to_jsonb(t) order by task_id) from taskfold_private.child_task_record_authority t),'originals',(select jsonb_agg(to_jsonb(t) order by id) from taskfold_private.child_task_repair_originals t where not(t.original ? 'budget_fixture')),'repairs',(select jsonb_agg(to_jsonb(t) order by actor_id,request_id) from taskfold_private.child_task_repairs t),'restorations',(select jsonb_agg(to_jsonb(t) order by actor_id,restore_id) from taskfold_private.child_repair_restorations t),'payloads',(select jsonb_agg(to_jsonb(t) order by actor_id,restore_id) from taskfold_private.child_repair_restore_payloads t),'restore_requests',(select jsonb_agg(to_jsonb(t) order by actor_id,request_id) from taskfold_private.child_repair_restore_requests t),'pins',(select jsonb_agg(to_jsonb(t) order by archive_id,object_id) from taskfold_private.child_adoption_archive_files t),'oldpins',(select jsonb_agg(to_jsonb(t) order by actor_id,restore_id,object_id) from taskfold_private.child_repair_restore_files t),'history',(select jsonb_agg(to_jsonb(t) order by sequence) from public.task_node_activity t),'root_history',(select jsonb_agg(to_jsonb(t) order by sequence) from public.task_activity t),'scope',(select jsonb_agg(to_jsonb(t) order by task_id) from taskfold_private.child_mapping_scope t),'team_scope',(select jsonb_agg(to_jsonb(t) order by task_id) from taskfold_private.team_task_edit_scope t))::text");
 check('new adoption gate defaults off',await runtime.raw('select not archive_restore_adoption_enabled from taskfold_private.child_task_record_config')==='t');
 await runtime.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true,adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true,copy_reconciliation_enabled=true,mapping_reconciliation_enabled=true,archive_restore_enabled=true,archive_restore_reversals_enabled=true');
 const restoreKeys=['protocol','account','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest','mode','restore_id','revision','review_digest'];
 const identity=r=>Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,r[k]]));
 async function fixture(label,project=null,user=account,beforeRestore=async()=>{}){
  const id=randomUUID(),note=randomUUID();
  const initial={id,user_id:user,project_id:project,title:label,description:'Current root notes',priority:2,subtasks:[{id:'parent',title:'Older parent',subtasks:['Original instruction']}]};
  if(project!==null)await runtime.raw(`insert into public.tasks(id,user_id,project_id,title,description,priority,subtasks) values(${lit(id)},${lit(user)},${lit(project)},${lit(label)},'Current root notes',2,${json(initial.subtasks)})`);
  else ok('create '+label,await api('/tasks',initial),201);
  await runtime.raw(`update public.tasks set subtasks=jsonb_set(subtasks,'{0,future}','{"exact":9007199254740993,"huge":1e500,"é":1,"é":2}'::jsonb) where id=${lit(id)}`);
  const root=JSON.parse(await runtime.raw(`select to_jsonb(t)::text from public.tasks t where id=${lit(id)}`));
  const read=ok('review initial '+label,await api('/rpc/taskfold_review_child_adoption',{_id:id,_generation:root.task_generation}));
  const b={...identity(read),changes:[{kind:'wrap_item',path:[0,0],reference:note,title:'Newer formatted instruction'}]};
  const pv=ok('preview initial '+label,await api('/rpc/taskfold_preview_child_repair',{_body:b}));
  const first=ok('save initial '+label,await api('/rpc/taskfold_repair_children',{_operation:'send',_body:{...b,request_id:randomUUID(),repair_digest:pv.repair_digest}}));
  const row=JSON.parse(await runtime.raw(`select to_jsonb(t)::text from taskfold_private.child_task_records t where task_id=${lit(id)} and node_key=${lit(note)}`));
  const baseline=JSON.parse(await runtime.raw(`select taskfold_private.child_task_completion_state(fields)::text from taskfold_private.child_task_records where task_id=${lit(id)} and node_key=${lit(note)}`));
  ok('earn completion '+label,await api('/rpc/taskfold_complete_child_task',{_body:{protocol:1,account,request_id:randomUUID(),task_id:id,task_generation:root.task_generation,project_id:project,node_key:note,incarnation:row.incarnation,revision:row.revision,action:'complete',baseline}}));
  await beforeRestore({id,root,first});
  const rv=ok('review restore '+label,await api('/rpc/taskfold_review_child_restore',{_mode:'restore',_repair:first.request_id,_archive:first.archive_id,_restore:null}));
  const restoreCommand={...Object.fromEntries(restoreKeys.map(k=>[k,rv[k]])),request_id:randomUUID()};
  const restored=ok('restore '+label,await api('/rpc/taskfold_restore_child_original',{_operation:'send',_body:restoreCommand}));
  return {id,note,root,first,restored,restoreCommand};
 }
 async function prepare(f,token=authorization,actor=account){
  const readWire=await api('/rpc/taskfold_review_child_adoption',{_id:f.id,_generation:f.root.task_generation},token),read=ok('review restored source',readWire);
  const heldWire=await api('/rpc/taskfold_review_restored_child_copies',{_body:identity(read),_actor:actor,_restore:f.restored.restoration_id},token),held=ok('review retained newer records',heldWire);
  const rows=JSON.parse(await runtime.raw(`select jsonb_agg(to_jsonb(t) order by node_key)::text from taskfold_private.child_task_records t where task_id=${lit(f.id)}`));
  const mapping={version:1,nodes:rows.map(r=>({source_key:r.node_key==='parent'?'parent':'kept-note',history_key:r.node_key,incarnation:r.incarnation,lifecycle:'recorded'})),retire:[]};
  const body={...identity(read),changes:[{kind:'choose_copy',path:[],source:'task',copy_digest:held.copies.copy_digest,mapping,format_changes:[{kind:'wrap_item',path:[0,0],reference:'kept-note',title:'Kept older instruction'}],restoration:held.restoration}]};
  return {readWire,heldWire,body};
 }
 const statusIdentity=f=>Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest'].map(k=>[k,f.restoreCommand[k]]));
 const live=(f,token=authorization,caller=account,actor=account,extra={})=>api('/rpc/taskfold_child_restore_status',{_body:{...statusIdentity(f),account:caller,...extra},_actor:actor,_restore:f.restored.restoration_id},token);
 const preview=(b,token=authorization)=>api('/rpc/taskfold_preview_child_repair',{_body:b},token);
 const send=(b,op='send',token=authorization)=>api('/rpc/taskfold_repair_children',{_operation:op,_body:b},token);
 const f=await fixture('Keep older editable version'),p=await prepare(f),before=await state();
 const activeStatusWire=await live(f),activeStatus=ok('live restored status with adoption paused',activeStatusWire);
 check('active status is contentless and current',activeStatus.phase==='restored'&&activeStatus.revision===1&&activeStatus.structure_current===true&&activeStatus.newer_retained===false&&Buffer.byteLength(activeStatusWire.text)<2048&&Object.keys(activeStatus).length===15);
 check('status does not mutate any saved work',await state()===before);
 ok('unrelated account cannot read known restoration',await live(f,other.access_token,other.user.id),403);
 ok('wrong restoration actor cannot be substituted',await live(f,authorization,account,other.user.id),403);
 ok('extra status input refused',await live(f,authorization,account,account,{unexpected:true}),400);
 ok('wrong task generation refused by live status',await live(f,authorization,account,account,{task_generation:randomUUID()}),403);
 for(const [table,operation] of [['tasks','select'],['task_node_activity','select']]){
  await runtime.raw(`create policy live_status_deny on public.${table} as restrictive for ${operation} to authenticated using(false)`);
  ok('live status respects caller '+table+' RLS',await live(f),403);
  await runtime.raw(`drop policy live_status_deny on public.${table}`);
 }
 check('status refusals preserve every source and receipt',await state()===before);
 report.liveStatusContract={command:f.restoreCommand,receipt:f.restored,active:activeStatus};
 const paused=ok('bound mapping preview while adoption paused',await preview(p.body));check('paused adoption not offered',!paused.mutation_available&&paused.custody_blocker===null);
 ok('paused new adoption refused',await send({...p.body,request_id:randomUUID(),repair_digest:paused.repair_digest}),503);check('paused refusal exact',await state()===before);
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_adoption_enabled=true');
 const pvWire=await preview(p.body),pv=ok('enabled bound format and mapping',pvWire);check('adoption offered after full review',pv.mutation_available&&pv.custody_blocker===null);
 const cmd={...p.body,request_id:randomUUID(),repair_digest:pv.repair_digest};
 const originalRoot=await runtime.raw(`select to_jsonb(t)::text from public.tasks t where id=${lit(f.id)}`);
 const oldPayload=await runtime.raw(`select payload::text from taskfold_private.child_repair_restore_payloads where restore_id=${lit(f.restored.restoration_id)}`);
 const history=await runtime.raw(`select jsonb_agg(to_jsonb(h) order by sequence)::text from public.task_node_activity h where task_id=${lit(f.id)}`);
 // All failure paths must leave the same held source, inverse, history and
 // decision ledger. Restrictive caller policies remain authoritative.
 const heldBefore=await state();
 for(const [name,change] of [['wrong digest',{digest:'a'.repeat(64)}],['wrong revision',{revision:2}],['extra binding field',{extra:true}]]){
  const response=await preview({...p.body,changes:[{...p.body.changes[0],restoration:{...p.body.changes[0].restoration,...change}}]});
  check(name+' refused',response.status>=400);check(name+' keeps work',await state()===heldBefore);
 }
 ok('unrelated actor cannot adopt',await send({...cmd,account:other.user.id},'send',other.access_token),403);
 check('unrelated adoption refused atomically',await state()===heldBefore);
 for(const table of ['tasks','task_node_activity']){
  const name='keep_deny_'+table;
  await runtime.raw(`create policy ${name} on public.${table} as restrictive for ${table==='tasks'?'update':'select'} to authenticated using(false) ${table==='tasks'?'with check(false)':''}`);
  ok('caller '+table+' RLS refuses adoption',await send(cmd),403);
  await runtime.raw(`drop policy ${name} on public.${table}`);check(table+' refusal keeps held work',await state()===heldBefore);
 }
 await runtime.raw(`create function taskfold_private.keep_test_fault() returns trigger language plpgsql set search_path='' as $$begin raise exception using errcode='PT409',message='Synthetic adoption fault';end$$;create trigger keep_after_mirror after update of subtasks on public.tasks for each row when(new.id=${lit(f.id)}) execute function taskfold_private.keep_test_fault()`);
 ok('post-mirror failure rolls back',await send(cmd),409);
 await runtime.raw('drop trigger keep_after_mirror on public.tasks');check('post-mirror rollback exact',await state()===heldBefore);
 await runtime.raw(`create constraint trigger keep_after_decision after update on taskfold_private.child_repair_restorations deferrable initially deferred for each row when(new.restore_id=${lit(f.restored.restoration_id)} and new.phase='adopted') execute function taskfold_private.keep_test_fault()`);
 ok('deferred commit failure rolls back',await send(cmd),409);
 await runtime.raw('drop trigger keep_after_decision on taskfold_private.child_repair_restorations;drop function taskfold_private.keep_test_fault()');check('deferred rollback exact',await state()===heldBefore);
 const claims=JSON.parse(Buffer.from(authorization.split('.')[1],'base64url').toString());
 const asActor=`set local request.jwt.claim.sub=${lit(account)};set local request.jwt.claims=${lit(JSON.stringify({sub:account,session_id:claims.session_id}))};set local role authenticated;`;
 let stageRefused=false;try{await runtime.raw(asActor+`select taskfold_private.commit_child_repair('send',${json(cmd)})->>'archive_bytes'`)}catch(e){report.privateStageRefusalCode=e.code;stageRefused=e.code==='PT409'}
 check('private staging cannot commit a partial adoption',stageRefused);check('private staging rollback exact',await state()===heldBefore);
 const predicted=Number(await runtime.raw(`savepoint estimate;${asActor}select taskfold_private.commit_child_repair('send',${json(cmd)})->>'archive_bytes';rollback to savepoint estimate;`));
 check('rolled-back quota estimate leaves all work exact',predicted>0&&await state()===heldBefore);
 const inverseBytes=Number(await runtime.raw(`select bytes from taskfold_private.child_repair_restore_payloads where restore_id=${lit(f.restored.restoration_id)}`));
 async function fillBudget(target){
  await runtime.raw(`do $$declare remaining bigint;amount integer;value jsonb;overhead integer;begin
   select ${target}-coalesce((select sum(bytes) from taskfold_private.child_task_repair_originals where actor_id=${lit(account)}),0)-coalesce((select sum(bytes) from taskfold_private.child_repair_restore_payloads where actor_id=${lit(account)}),0) into remaining;
   overhead:=octet_length(jsonb_build_object('budget_fixture','keep','padding','')::text);
   while remaining>0 loop amount:=least(7999000,remaining);value:=jsonb_build_object('budget_fixture','keep','padding',repeat('x',amount-overhead));
    insert into taskfold_private.child_task_repair_originals(id,actor_id,owner_id,task_id,task_generation,request_id,original,bytes,digest) values(gen_random_uuid(),${lit(account)},${lit(account)},${lit(f.id)},${lit(f.root.task_generation)},gen_random_uuid(),value,octet_length(value::text),taskfold_private.child_restore_digest(value));remaining:=remaining-amount;
   end loop;end$$`);
 }
 const clearBudget=()=>runtime.raw("delete from taskfold_private.child_task_repair_originals where original->>'budget_fixture'='keep'");
 await fillBudget(63999000);ok('full retained budget refuses adoption',await send(cmd),429);check('budget refusal preserves every real copy',await state()===heldBefore);await clearBudget();
 await fillBudget(64000000-predicted+inverseBytes-8);
 const resultWire=await send(cmd),result=ok('atomic older-version adoption',resultWire);check('one applied decision',result.state==='applied'&&result.request_id===cmd.request_id&&!result.replayed);
 check('quota credits exactly the moved inverse',await runtime.raw(`select coalesce((select sum(bytes) from taskfold_private.child_task_repair_originals where actor_id=${lit(account)}),0)+coalesce((select sum(bytes) from taskfold_private.child_repair_restore_payloads where actor_id=${lit(account)}),0)=63999992`)==='t');await clearBudget();
 check('old restoration ended as adopted',await runtime.raw(`select phase='adopted' and revision=2 and adopted_actor_id=${lit(account)} and adopted_request_id=${lit(cmd.request_id)} and adopted_archive_id=${lit(result.archive_id)} from taskfold_private.child_repair_restorations where restore_id=${lit(f.restored.restoration_id)}`)==='t');
 const adoptedStatus=ok('live status reports adoption after old receipt',await live(f));
 check('live adopted state revokes old reversal',adoptedStatus.phase==='adopted'&&adoptedStatus.revision===2&&!adoptedStatus.structure_current&&adoptedStatus.newer_retained);
 const oldReceipt=ok('old restoration receipt remains immutable',await api('/rpc/taskfold_restore_child_original',{_operation:'check',_body:f.restoreCommand}));
 check('receipt is a past event not current state',oldReceipt.phase==='restored'&&oldReceipt.next_revision===1);
 report.liveStatusContract.adopted=adoptedStatus;
 check('old inverse removed only after transfer',await runtime.raw(`select not exists(select 1 from taskfold_private.child_repair_restore_payloads where restore_id=${lit(f.restored.restoration_id)})`)==='t');
 check('new immutable archive retains entire inverse',await runtime.raw(`select (original->'retained_restoration'->'payload')::text=${lit(oldPayload)} and (original->'root')::text=${lit(originalRoot)} and (original->'retained_restoration'->'payload'->'before'->'tree'->0->'future'->'exact')::text='9007199254740993' from taskfold_private.child_task_repair_originals where id=${lit(result.archive_id)}`)==='t');
 check('prior history kept byte exact',await runtime.raw(`select not exists(select 1 from jsonb_array_elements(${lit(history)}::jsonb) e where not exists(select 1 from public.task_node_activity h where h.id=(e->>'id')::uuid and to_jsonb(h)::text=e::text))`)==='t');
 check('kept root preserves opaque fields and exact numeric spellings',await runtime.raw(`select (t.subtasks->0->'future')::text=(o.original->'root'->'subtasks'->0->'future')::text from public.tasks t join taskfold_private.child_task_repair_originals o on o.id=${lit(result.archive_id)} where t.id=${lit(f.id)}`)==='t');
 check('completion earned once',await runtime.raw(`select count(*)=1 from public.task_node_activity where task_id=${lit(f.id)} and 'completed'=any(kinds)`)==='t');
 check('no transaction scope survives',await runtime.raw('select not exists(select 1 from taskfold_private.child_mapping_scope) and not exists(select 1 from taskfold_private.team_task_edit_scope)')==='t');
 const originalWire=await send(cmd,'original');ok('export adopted original',originalWire);
 if(process.argv[3])await writeFile(process.argv[3],'{"root":'+originalRoot+',"review":'+p.readWire.text+',"held":'+p.heldWire.text+',"preview":'+pvWire.text+',"command":'+JSON.stringify(cmd)+',"receipt":'+resultWire.text+',"original":'+originalWire.text+'}\n');
 const after=await state();await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_adoption_enabled=false');
 check('lost reply confirmed by exact retry',ok('retry while adoption paused',await send(cmd)).replayed);ok('status after final adoption',await send(cmd,'check'));check('all recovery is immutable',await state()===after);
 ok('same nonce cannot change chosen restoration',await send({...cmd,changes:[{...cmd.changes[0],restoration:{...cmd.changes[0].restoration,digest:'a'.repeat(64)}}]}),409);check('nonce conflict keeps work',await state()===after);
 const row=JSON.parse(await runtime.raw(`select to_jsonb(r)::text from taskfold_private.child_task_records r where task_id=${lit(f.id)} and node_key=${lit(f.note)}`));
 ok('kept version supports normal field editing',await api('/rpc/taskfold_edit_child_task',{_body:{protocol:1,account,request_id:randomUUID(),task_id:f.id,task_generation:f.root.task_generation,project_id:null,node_key:f.note,incarnation:row.incarnation,revision:row.revision,changes:{description:'Independent edits work after adoption'}}}));
 check('independent edit reaches kept root and preserves current root notes',await runtime.raw(`select description='Current root notes' and priority=2 and subtasks->0->'subtasks'->0->>'description'='Independent edits work after adoption' from public.tasks where id=${lit(f.id)}`)==='t');
 // Current-role custody and actual private file bytes survive the transfer.
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_adoption_enabled=true');
 const team=randomUUID(),project=randomUUID();
 await runtime.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(other.user.id)},'Keep version workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(other.user.id)},'admin'),(${lit(team)},${lit(account)},'admin');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_task_types_enabled=true;insert into public.projects(id,user_id,name) values(${lit(project)},${lit(other.user.id)},'Shared kept version');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(project)},${lit(team)},'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(project)},${lit(team)},${lit(account)},'editor');insert into storage.buckets(id,name,public) values('task-attachments','task-attachments',false) on conflict(id) do update set public=false`);
 const fileName=account+'/keep-proof.txt',fileBytes=Buffer.from('Retained file bytes 🪴');let object;
 const storage=(path,options={})=>fetch(runtime.urls.storage+path,{...options,headers:{apikey:runtime.anon,Authorization:'Bearer '+runtime.service,...options.headers},signal:AbortSignal.timeout(30000)});
 const sf=await fixture('Shared file adoption',project,other.user.id,async({id,root})=>{
  check('private file uploaded',(await storage('/object/task-attachments/'+fileName,{method:'POST',headers:{'Content-Type':'text/plain'},body:fileBytes})).status===200);
  object=await runtime.raw(`select id from storage.objects where bucket_id='task-attachments' and name=${lit(fileName)}`);
  await runtime.raw(`update storage.objects set owner=${lit(account)},owner_id=${lit(account)} where id=${lit(object)};insert into taskfold_private.team_content_files(object_id,project_id,task_id,task_generation) values(${lit(object)},${lit(project)},${lit(id)},${lit(root.task_generation)});update public.tasks set attachments=${json([{id:randomUUID(),storage_object_id:object,name:'Kept file',url:'https://example.invalid/proof'}])} where id=${lit(id)}`);
 });
 const sp=await prepare(sf),sv=ok('shared adoption preview',await preview(sp.body)),sc={...sp.body,request_id:randomUUID(),repair_digest:sv.repair_digest};
 await runtime.raw(`update taskfold_private.team_members set role='member' where team_id=${lit(team)} and user_id=${lit(account)}`);
 const demoted=await state();ok('demoted admin cannot adopt prepared version',await send(sc),403);check('demotion refusal retains all files and work',await state()===demoted);
 await runtime.raw(`update taskfold_private.team_members set role='admin' where team_id=${lit(team)} and user_id=${lit(account)}`);
 const sr=ok('shared current admin adopts',await send(sc));
 const crossStatus=ok('current second custodian reads live status',await live(sf,other.access_token,other.user.id));check('second custodian sees adopted phase without contents',crossStatus.phase==='adopted'&&crossStatus.newer_retained);
 await runtime.raw(`update taskfold_private.team_members set role='member' where team_id=${lit(team)} and user_id=${lit(other.user.id)}`);ok('workspace owner remains authorized despite membership role label',await live(sf,other.access_token,other.user.id));
 const reader=ok('current status administrator signup',await signup());await runtime.raw(`insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(reader.user.id)},'admin');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(project)},${lit(team)},${lit(reader.user.id)},'editor')`);
 ok('another current administrator reads retained status',await live(sf,reader.access_token,reader.user.id));await runtime.raw(`update taskfold_private.team_members set role='member' where team_id=${lit(team)} and user_id=${lit(reader.user.id)}`);ok('demoted administrator cannot read another actor status',await live(sf,reader.access_token,reader.user.id),403);
 await runtime.raw(`update taskfold_private.team_members set role='admin' where team_id=${lit(team)} and user_id=${lit(other.user.id)}`);
 check('file protection transferred to independent archive',await runtime.raw(`select exists(select 1 from taskfold_private.child_adoption_archive_files where archive_id=${lit(sr.archive_id)} and object_id=${lit(object)}) and not exists(select 1 from taskfold_private.child_repair_restore_files where restore_id=${lit(sf.restored.restoration_id)})`)==='t');
 for(const [name,sql] of [['file binding delete',`delete from taskfold_private.team_content_files where object_id=${lit(object)}`],['file identity change',`update storage.objects set name='changed' where id=${lit(object)}`]]){
  const protectedState=await state();let rejected=false;try{await runtime.raw(sql)}catch(e){rejected=e.code==='PT409'||e.code==='23503'}check(name+' protected after adoption',rejected);check(name+' leaves retained work exact',await state()===protectedState);
 }
 const controlName=fileName+'.unbound';
 check('unbound deletion control uploaded',(await storage('/object/task-attachments/'+controlName,{method:'POST',headers:{'Content-Type':'text/plain'},body:Buffer.from('Disposable control')})).status===200);
 const removeFile=name=>storage('/object/task-attachments',{method:'DELETE',headers:{'Content-Type':'application/json'},body:JSON.stringify({prefixes:[name]})});
 check('real Storage deletion works for unbound control',(await removeFile(controlName)).status===200);
 const boundRemoval=await removeFile(fileName);report.retainedFileDeleteStatus=boundRemoval.status;
 check('real Storage API cannot delete retained file',boundRemoval.status>=400);
 const downloaded=await storage('/object/authenticated/task-attachments/'+fileName);check('actual retained bytes intact',downloaded.status===200&&Buffer.from(await downloaded.arrayBuffer()).equals(fileBytes));
 await runtime.raw(`update taskfold_private.team_members set role='member' where team_id=${lit(team)} and user_id=${lit(account)}`);
 ok('receipt check survives role loss',await send(sc,'check'));ok('retained inverse export requires current custody',await send(sc,'original'),403);ok('discovered inverse export requires current custody',await api('/rpc/taskfold_child_repair_original',{_request:sc.request_id,_archive:sr.archive_id}),403);
 await runtime.raw(`update taskfold_private.team_members set role='admin' where team_id=${lit(team)} and user_id=${lit(account)}`);
 ok('custody recovery permits exact original export',await send(sc,'original'));
 await runtime.raw('update taskfold_private.child_task_record_config set archive_cleanup_enabled=true');
 const liveRoot=await runtime.raw(`select to_jsonb(t)::text from public.tasks t where id=${lit(sf.id)}`);
 const cleanupBody={_request:sc.request_id,_archive:sr.archive_id,_digest:sr.archive_digest,_bytes:sr.archive_bytes};
 const retention=ok('review removal of adoption archive',await api('/rpc/taskfold_child_repair_original_cleanup',{_operation:'review',...cleanupBody}));
 check('explicit retention review keeps inverse protected',retention.state==='retained'&&await runtime.raw(`select exists(select 1 from taskfold_private.child_adoption_archive_files where archive_id=${lit(sr.archive_id)})`)==='t');
 const removed=ok('explicitly remove only adopted original',await api('/rpc/taskfold_child_repair_original_cleanup',{_operation:'remove',...cleanupBody}));
 check('retention removal releases archive file pins',removed.state==='unavailable'&&await runtime.raw(`select not exists(select 1 from taskfold_private.child_adoption_archive_files where archive_id=${lit(sr.archive_id)})`)==='t');
 check('retention removal keeps live task exact',await runtime.raw(`select to_jsonb(t)::text from public.tasks t where id=${lit(sf.id)}`)===liveRoot);
 check('live status does not claim a removed newer archive remains',!ok('status after archive retention removal',await live(sf)).newer_retained);
 const retainedDownload=await storage('/object/authenticated/task-attachments/'+fileName);check('retention removal keeps actual current file bytes',retainedDownload.status===200&&Buffer.from(await retainedDownload.arrayBuffer()).equals(fileBytes));
 const cross=await fixture('Other administrator adoption',project,other.user.id),cp=await prepare(cross,other.access_token),cv=ok('other custodian maps prior restoration',await preview(cp.body,other.access_token));
 const cr=ok('other custodian adopts prior actors version',await send({...cp.body,request_id:randomUUID(),repair_digest:cv.repair_digest},'send',other.access_token));
 check('archive owns inverse independently of restoration actor',await runtime.raw(`select actor_id=${lit(other.user.id)} and team_id=${lit(team)} and original->'retained_restoration'->'binding'->>'actor_id'=${lit(account)} from taskfold_private.child_task_repair_originals where id=${lit(cr.archive_id)}`)==='t');
 const stale=await fixture('Changed review and safe Stop'),stp=await prepare(stale),stpv=ok('prepare stale adoption',await preview(stp.body)),stc={...stp.body,request_id:randomUUID(),repair_digest:stpv.repair_digest};
 ok('root notes remain editable before decision',await runtime.request('rest','/tasks?id=eq.'+stale.id,{method:'PATCH',authorization,body:{description:'Later root notes'}}),204);
 const changed=await state();ok('stale restoration binding refuses save',await send(stc),409);check('stale refusal retains latest notes and inverse',await state()===changed);
 const stopped=ok('Stop remains possible after source changes',await send(stc,'close'));check('stopped adoption makes no source change',stopped.state==='closed');const stoppedState=await state();check('stopped exact send cannot adopt later',ok('stopped request replay',await send(stc)).state==='closed'&&await state()===stoppedState);
 check('all scoped state removed',await runtime.raw('select not exists(select 1 from taskfold_private.child_mapping_scope) and not exists(select 1 from taskfold_private.team_task_edit_scope)')==='t');
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_adoption_enabled=false');
 const ordinaryRead=ok('ordinary mapping source after adoption',await api('/rpc/taskfold_review_child_adoption',{_id:f.id,_generation:f.root.task_generation})),ordinaryIdentity=identity(ordinaryRead);
 const ordinaryCopies=ok('ordinary copies after adoption',await api('/rpc/taskfold_review_child_copies',{_body:ordinaryIdentity}));
 const ordinaryRows=JSON.parse(await runtime.raw(`select jsonb_agg(to_jsonb(r) order by node_key)::text from taskfold_private.child_task_records r where task_id=${lit(f.id)}`));
 const ordinaryBody={...ordinaryIdentity,changes:[{kind:'choose_copy',path:[],source:'task',copy_digest:ordinaryCopies.copy_digest,mapping:{version:1,nodes:ordinaryRows.map(r=>({source_key:r.node_key,history_key:r.node_key,incarnation:r.incarnation,lifecycle:'recorded'})),retire:[]}}]};
 const ordinaryPreview=ok('ordinary mapping unaffected by adoption pause',await preview(ordinaryBody));check('ordinary mapping still offered',ordinaryPreview.mutation_available);
 const ordinarySaved=ok('ordinary mapping saves without restoration binding',await send({...ordinaryBody,request_id:randomUUID(),repair_digest:ordinaryPreview.repair_digest}));
 check('ordinary original retains its existing schema',await runtime.raw(`select not(original ? 'retained_restoration') and jsonb_typeof(original->'authority')='object' from taskfold_private.child_task_repair_originals where id=${lit(ordinarySaved.archive_id)}`)==='t');
 // Live phase is independent from immutable events, rollout flags and root notes.
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_finish_enabled=true');
 const cycle=await fixture('Live recovery lifecycle');report.liveStatusContract.lifecycle=[];report.liveStatusContract.lifecycleCommand=cycle.restoreCommand;report.liveStatusContract.lifecycleReceipt=cycle.restored;
 for(const mode of ['undo','redo','undo']){
  const reviewed=ok('live cycle review '+mode,await api('/rpc/taskfold_review_child_restore',{_mode:mode,_repair:cycle.first.request_id,_archive:cycle.first.archive_id,_restore:cycle.restored.restoration_id}));
  const command={...Object.fromEntries(restoreKeys.map(k=>[k,reviewed[k]])),request_id:randomUUID()};
  ok('live cycle apply '+mode,await api('/rpc/taskfold_restore_child_original',{_operation:'send',_body:command}));
  const status=ok('fresh cycle state '+mode,await live(cycle));check('cycle state matches '+mode+' revision '+status.revision,status.phase===(mode==='undo'?'undone':'restored')&&status.structure_current&&!status.newer_retained);report.liveStatusContract.lifecycle.push(status);
 }
 ok('root note update after Undo',await runtime.request('rest','/tasks?id=eq.'+cycle.id,{method:'PATCH',authorization,body:{description:'Current root notes after Undo'}}),204);
 check('root notes do not falsely revoke structural reversal',ok('status after root notes',await live(cycle)).structure_current);
 const editable=JSON.parse(await runtime.raw(`select to_jsonb(r)::text from taskfold_private.child_task_records r where task_id=${lit(cycle.id)} and node_key=${lit(cycle.note)}`));
 ok('normal field edit after Undo',await api('/rpc/taskfold_edit_child_task',{_body:{protocol:1,account,request_id:randomUUID(),task_id:cycle.id,task_generation:cycle.root.task_generation,project_id:null,node_key:cycle.note,incarnation:editable.incarnation,revision:editable.revision,changes:{description:'New work after Undo'}}}));
 const changedStatus=ok('status notices changed editable work',await live(cycle));check('changed work keeps undone phase but revokes stale Redo',changedStatus.phase==='undone'&&!changedStatus.structure_current);report.liveStatusContract.lifecycle.push(changedStatus);
 const finish=ok('review Finish after new work',await api('/rpc/taskfold_review_child_restore',{_mode:'finish',_repair:cycle.first.request_id,_archive:cycle.first.archive_id,_restore:cycle.restored.restoration_id}));
 ok('Finish keeps current editable work',await api('/rpc/taskfold_restore_child_original',{_operation:'send',_body:{...Object.fromEntries(restoreKeys.map(k=>[k,finish[k]])),request_id:randomUUID()}}));
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_enabled=false,archive_restore_reversals_enabled=false,archive_restore_finish_enabled=false,archive_restore_adoption_enabled=false');
 const finished=ok('live status remains readable with mutation gates off',await live(cycle));check('live finished state has no reversal or retained newer adoption archive',finished.phase==='finished'&&finished.revision===5&&!finished.structure_current&&!finished.newer_retained);report.liveStatusContract.lifecycle.push(finished);

 report.advisors=await runtime.advisors();report.passed=true;
}catch(e){report.failure={message:e.message,migration:e.migration,startupCleanup:e.cleanedUp,stack:e.stack?.split('\n').slice(0,4)};process.exitCode=1;}finally{if(runtime)report.cleanup=await runtime.close();await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:report.passed??false,checks:Object.keys(report.checks).length,lastFailure:report.lastFailure,failure:report.failure,cleanup:report.cleanup}));}
