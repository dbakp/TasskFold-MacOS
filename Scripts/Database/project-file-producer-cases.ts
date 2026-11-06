// @ts-nocheck -- Genuine service/Storage cases run inside the owning full schema.
import assert from 'node:assert/strict';
import {Buffer} from 'node:buffer';
import {randomUUID,createHash} from 'node:crypto';
import {createProjectFilesHandler} from '../../supabase/functions/project-files/handler.ts';
import {createTaskFileMaintenanceHandler} from '../../supabase/functions/task-file-maintenance/handler.ts';

export async function exerciseProjectFileProducers(runtime,check){
 const lit=x=>"'"+String(x).replaceAll("'","''")+"'";
 const auth=await runtime.request('auth','/signup',{method:'POST',body:{email:'producer-'+randomUUID()+'@example.invalid',password:'Synthetic-'+randomUUID()+'!'}});assert.equal(auth.status,200);
 const owner={id:auth.value.user.id,token:auth.value.access_token,session:JSON.parse(Buffer.from(auth.value.access_token.split('.')[1],'base64url')).session_id};
 const outside=await runtime.request('auth','/signup',{method:'POST',body:{email:'outside-'+randomUUID()+'@example.invalid',password:'Synthetic-'+randomUUID()+'!'}});assert.equal(outside.status,200);
 const api=(path,body,method='POST')=>runtime.request('rest',path,{method,authorization:owner.token,headers:{Prefer:'return=representation'},...(body===undefined?{}:{body})});
 const rpc=(action,body)=>runtime.request('rest','/rpc/taskfold_project_file_preparation',{method:'POST',authorization:runtime.service,body:{_action:action,_actor:owner.id,_session:owner.session,_body:body}});
 const terminal=(body,actor=owner.id,authorization=runtime.service)=>runtime.request('rest','/rpc/taskfold_project_file_producer_terminal',{method:'POST',authorization,body:{_actor:actor,_body:body}});
 const project=(await api('/projects',{user_id:owner.id,name:'Producer recovery workshop'})).value[0],team=randomUUID();
 const original=Buffer.from('Private producer recovery source\n'),name=owner.id+'/'+randomUUID()+'.txt';
 const origin=new URL(runtime.urls.storage).origin;
 const stored=await fetch(origin+'/storage/v1/object/task-attachments/'+name,{method:'POST',headers:{apikey:runtime.anon,Authorization:'Bearer '+owner.token,'Content-Type':'text/plain','x-upsert':'false'},body:original});assert.equal(stored.status,200);await stored.arrayBuffer();
 const object=JSON.parse(await runtime.raw(`select to_jsonb(o) from storage.objects o where bucket_id='task-attachments' and name=${lit(name)}`));
 const task=(await api('/tasks',{user_id:owner.id,project_id:project.id,title:'Private source stays intact',attachments:[{id:randomUUID(),storage_object_id:object.id,name:'Source.txt'}]})).value[0];
 await runtime.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'Producer fixture');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_project_adoption_enabled=true;update taskfold_private.project_file_preparation_config set enabled=true,transfer_enabled=true;update taskfold_private.task_file_upload_config set enabled=true;`);
 const scope={team_id:team,roots:[project.id],visibility:'private',folder_id:null,parent_id:null};
 const inspection=await api('/rpc/taskfold_team_project_adoption',{operation:'inspect',body:scope});assert.equal(inspection.status,200);
 const invoke=async(handler,action,body)=>{const r=await handler(new Request('http://127.0.0.1/?action='+action,{method:'POST',headers:{Authorization:'Bearer '+owner.token,'Content-Type':'application/json'},body:JSON.stringify(body)}));return{status:r.status,value:await r.json()}};
 const plain=createProjectFilesHandler({url:origin,serviceKey:runtime.service,enabled:true});
 const prepare=async()=>{const r=await invoke(plain,'prepare',{request_id:randomUUID(),scope,inspection_token:inspection.value.inspection_token});assert.equal(r.status,200);return{plan_id:r.value.plan.plan_id,operation_id:r.value.plan.items[0].operation_id}};
 const cancel=async ids=>{assert.equal((await invoke(plain,'cancel',{plan_id:ids.plan_id})).status,200)};
 const maintenanceKey='synthetic-maintenance-'+randomUUID();let deletes=0;
 const maintain=createTaskFileMaintenanceHandler({url:'https://project-file-producer-fixture.invalid/',serviceKey:runtime.service,maintenanceKey,enabled:true},{send:async r=>{const u=new URL(r.url);assert.equal(u.origin,'https://project-file-producer-fixture.invalid');if(r.method==='DELETE'&&u.pathname.startsWith('/storage/v1/'))deletes++;return fetch(new Request(origin+u.pathname+u.search,{method:r.method,headers:r.headers,body:r.body,signal:r.signal,redirect:'error'}))}});
 const clean=async()=>{const r=await maintain(new Request('http://127.0.0.1/',{method:'POST',headers:{'X-Taskfold-File-Maintenance':maintenanceKey},body:'{}'}));const value=await r.json();assert.equal(r.status,200,JSON.stringify(value));return value};
 const state=async ids=>JSON.parse(await runtime.raw(`select jsonb_build_object('open',(select count(*) from taskfold_private.task_file_write_attempts where operation_id=${lit(ids.operation_id)} and state='open'),'settled',(select count(*) from taskfold_private.task_file_write_attempts where operation_id=${lit(ids.operation_id)} and state='settled'),'charged',(select provider_cleanup_confirmed_at is null from taskfold_private.task_file_uploads where operation_id=${lit(ids.operation_id)}),'producers',(select coalesce(jsonb_agg(jsonb_build_object('id',producer_id,'ticket',ticket_id,'proof',proof,'closed',closed_at is not null)),'[]') from taskfold_private.project_file_copy_producers where operation_id=${lit(ids.operation_id)}))`));
 const digest=createHash('sha256').update(original).digest('hex');
 const reservation=(ids,producer)=>({...ids,producer_id:producer,byte_count:original.length,sha256:digest});

 // A committed reservation reply and the following terminal acknowledgement
 // are both lost. Only the handler's own unstarted ticket may be settled.
 const lost=await prepare();let posts=0,closureCount=0;
 const loss=createProjectFilesHandler({url:origin,serviceKey:runtime.service,enabled:true},{send:async r=>{
  const path=new URL(r.url).pathname;
  if(path.startsWith('/storage/v1/object/')&&r.method==='POST')posts++;
  const body=path.startsWith('/rest/v1/rpc/')?await r.clone().json():null;
  const result=await fetch(r);
  if(body?._action==='reserve_producer'||path.endsWith('taskfold_project_file_producer_terminal')){assert.equal(result.status,200);await result.arrayBuffer();if(path.endsWith('terminal'))closureCount++;throw Error('Synthetic acknowledgement loss')}
  return result;
 }});
 check('producer lost reservation is retryable',(await invoke(loss,'copy',lost)).status,503);
 check('producer reservation loss issues no provider POST',posts,0);
 let known=await state(lost);check('producer no-POST attestation settles only its ticket',[known.open,known.settled,known.producers[0].proof,known.producers[0].closed],[0,1,'not_started',true]);
 check('producer terminal acknowledgement really committed before loss',closureCount,1);
 check('producer settlement does not release storage charge',known.charged,true);
 const closed=known.producers[0].id;
 check('producer closed identity refuses late reservation',(await rpc('reserve_producer',reservation(lost,closed))).value.status,'producer_closed');
 check('producer native caller cannot attest',(await terminal({...lost,producer_id:closed,proof:'not_started'},owner.id,owner.token)).status>=400,true);
 check('producer outside caller cannot attest',(await terminal({...lost,producer_id:closed,proof:'not_started'},owner.id,outside.value.access_token)).status>=400,true);
 check('producer foreign actor cannot close known identity',(await terminal({...lost,producer_id:closed,proof:'not_started'},outside.value.user.id)).value.settled,false);
 check('producer idempotent terminal observation',(await terminal({...lost,producer_id:closed,proof:'not_started'})).value.settled,true);
 check('producer proof cannot be rewritten',(await terminal({...lost,producer_id:closed,proof:'provider_terminal'})).value.settled,false);
 const retry=await invoke(plain,'copy',lost);check('producer explicit retry completes private copy',retry.status,200);check('producer retry remains private',retry.value.plan.project_transferred,false);
 known=await state(lost);check('producer fresh retry has two settled tickets and no open writer',[known.open,known.settled],[0,2]);
 await cancel(lost);await clean();check('producer real maintenance releases charge only after provider work',(await state(lost)).charged,false);check('producer actual maintenance deleted a stored copy',deletes>0,true);

 // Simulate an RPC still travelling after its handler times out. The terminal
 // observation wins first; the real late SQL request cannot grant an upload.
 const late=await prepare();let release,lateProducer;
 const delayed=createProjectFilesHandler({url:origin,serviceKey:runtime.service,enabled:true,timeoutMilliseconds:500},{send:async r=>{
  if(new URL(r.url).pathname.endsWith('taskfold_project_file_preparation')){const b=await r.clone().json();if(b._action==='reserve_producer'){lateProducer=b._body.producer_id;return new Promise(resolve=>{release=async()=>{const result=await fetch(new Request(r,{signal:new AbortController().signal}));const value=await result.clone().json();resolve(result);return value}})}}return fetch(r);
 }});
 check('producer delayed reservation returns bounded retry',(await invoke(delayed,'copy',late)).status,503);assert(release);
 check('producer terminal tombstone exists before late reservation',(await state(late)).producers[0].proof,'not_started');
 check('producer actual late reservation observes closure',(await release()).status,'producer_closed');
 check('producer closed-before-create creates no upload ledger',await runtime.raw(`select count(*) from taskfold_private.task_file_uploads where operation_id=${lit(late.operation_id)}`),'0');await cancel(late);

 // No response to an issued POST is not proof of completion or absence. A
 // different verifying producer must not acquire/settle that writer's ticket.
 const uncertain=await prepare();let releasePost,postCount=0;
 const held=createProjectFilesHandler({url:origin,serviceKey:runtime.service,enabled:true,timeoutMilliseconds:500},{send:async r=>{
  if(r.method==='POST'&&new URL(r.url).pathname.startsWith('/storage/v1/object/')){postCount++;return new Promise(resolve=>{releasePost=async()=>{const result=await fetch(new Request(r,{signal:new AbortController().signal}));const status=result.status;resolve(result);return status}})}return fetch(r);
 }});
 check('producer indeterminate POST returns retry',(await invoke(held,'copy',uncertain)).status,503);check('producer POST was issued exactly once',postCount,1);
 known=await state(uncertain);check('producer uncertain writer remains open',[known.open,known.producers[0].closed],[1,false]);
 const originalProducer=known.producers[0].id,verifier=randomUUID();
 const verify=await rpc('reserve_producer',reservation(uncertain,verifier));check('producer concurrent verifier gets read-only grant',verify.value.status,'verify');
 check('producer verifier can close only its own no-write identity',(await terminal({...uncertain,producer_id:verifier,proof:'not_started'})).value.settled,true);
 check('producer verifier did not settle original writer',(await state(uncertain)).open,1);
 check('producer cannot invent verified proof for open writer',(await terminal({...uncertain,producer_id:originalProducer,proof:'verified'})).value.settled,false);
 await cancel(uncertain);await clean();check('producer missing provider object keeps charge',(await state(uncertain)).charged,true);check('producer missing provider object keeps writer open',(await state(uncertain)).open,1);
 check('producer late admitted POST actually completes',await releasePost(),200);
 await runtime.raw(`update taskfold_private.task_file_write_attempts set next_probe_at=clock_timestamp()-interval '1 second' where operation_id=${lit(uncertain.operation_id)}`);
 await clean();known=await state(uncertain);check('producer positive stored bytes permit settlement and cleanup',[known.open,known.charged],[0,false]);
 check('producer maintenance does not invent a process terminal attestation',known.producers.find(x=>x.id===originalProducer).closed,false);

 // A terminal observation needs the already-bound producer, not a still-live
 // user session. Revoke it for real only after cancellation and admission.
 const logout=await prepare(),producer=randomUUID();const grant=await rpc('reserve_producer',reservation(logout,producer));check('producer logout fixture reserved its own writer',grant.value.status,'upload');await cancel(logout);
 await runtime.raw('update taskfold_private.project_file_preparation_config set enabled=false;update taskfold_private.task_file_upload_config set enabled=false;');
 const loggedOut=await runtime.request('auth','/logout',{method:'POST',authorization:owner.token});check('producer actual Auth logout completed',loggedOut.status,204);
 check('producer logged-out session cannot reserve new work',(await rpc('reserve_producer',reservation(logout,randomUUID()))).value.status,'unavailable');
 check('producer terminal observation survives logout and gate pause',(await terminal({...logout,producer_id:producer,proof:'not_started'})).value.settled,true);
 await clean();check('producer cancelled absent copy can be reclaimed after logout',(await state(logout)).charged,false);
 const privateTables=await runtime.raw(`select count(*) from information_schema.role_table_grants where table_schema='taskfold_private' and table_name='project_file_copy_producers' and grantee in('PUBLIC','anon','authenticated','service_role')`);check('producer table has no direct API grants',privateTables,'0');
 check('producer table has RLS',await runtime.raw(`select relrowsecurity::text from pg_class where oid='taskfold_private.project_file_copy_producers'::regclass`),'true');
 const preserved=await fetch(origin+'/storage/v1/object/authenticated/task-attachments/'+name,{headers:{apikey:runtime.service,Authorization:'Bearer '+runtime.service}});check('producer original provider bytes stay exact',Buffer.from(await preserved.arrayBuffer()),original);
 check('producer original task stays personal and unchanged',JSON.parse(await runtime.raw(`select to_jsonb(t) from public.tasks t where id=${lit(task.id)}`)),task);
}
