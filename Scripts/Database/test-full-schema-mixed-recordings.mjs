import assert from 'node:assert/strict';
import {randomUUID,randomBytes,createHash} from 'node:crypto';
import {readFile,writeFile,stat} from 'node:fs/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
import {createFullSchemaAudioFixture} from './full-schema-audio-fixture.mjs';
const output=process.argv[2];assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));assert(!(await stat(output).catch(()=>null)));
const report={checks:{},genuineLocalAuthRESTStorage:true,validatedLoopbackTLS:true,productionPublicationAndMaintenanceHandlers:true,hostedChanges:false,ordinaryGatesChanged:false,nativeAppAccepted:false,storageBackend:'Disposable tmpfs file backend; not hosted S3'};
const check=(name,value,expected=true)=>{assert.deepEqual(value,expected,name);report.checks[name]=true;console.log('passed',name)};
const lit=value=>"'"+String(value).replaceAll("'","''")+"'";
const sourcePaths=['Scripts/Database/test-full-schema-mixed-recordings.mjs','Scripts/Database/full-schema-runtime.mjs','Scripts/Database/full-schema-gateway.mjs','Scripts/Database/full-schema-audio-fixture.mjs','Scripts/Database/full-schema-audio-server.ts','supabase/functions/audio-comments/handler.ts','supabase/functions/audio-comments/wire.ts','supabase/functions/audio-comment-maintenance/handler.ts'];
const hash=async path=>createHash('sha256').update(await readFile(new URL('../../'+path,import.meta.url))).digest('hex');
report.sourceSHA256=Object.fromEntries(await Promise.all(sourcePaths.map(async path=>[path,await hash(path)])));
let runtime,audio;
try {
 runtime=await createFullSchemaRuntime();report.migrations=runtime.migrations;report.images=runtime.images;report.baselineAdvisors=await runtime.advisors();
 const users={};for(const name of ['owner','old','new']){
  const response=await runtime.request('auth','/signup',{method:'POST',body:{email:'mixed-'+name+'@example.invalid',password:randomBytes(24).toString('base64url')}});
  check('real signup '+name,response.status,200);const value=response.value,claims=JSON.parse(Buffer.from(value.access_token.split('.')[1],'base64url'));
  check('real session '+name,typeof claims.session_id==='string');users[name]={id:value.user.id,email:value.user.email,token:value.access_token,session:claims.session_id};
 }
 const owner=users.owner,team=randomUUID(),policy='move_recordings_keep_removed_private_v1';
 const request=(path,body,user=owner)=>runtime.request('rest',path,{method:'POST',authorization:user.token,body,headers:{Prefer:'return=representation'}});
 const rpc=async(operation,body,status=200)=>{const response=await request('/rpc/taskfold_team_project_adoption',{operation,body});if(response.status!==status)report.lastFailure={operation,status:response.status,value:response.value};check('adoption '+operation+' HTTP '+status,response.status,status);return response.value};
 const scalar=async sql=>JSON.parse(await runtime.raw('select to_jsonb(value) from ('+sql+') fixture(value)'));
 await runtime.raw('insert into taskfold_private.teams(id,owner_id,name) values('+lit(team)+','+lit(owner.id)+",'Mixed recording workshop');insert into taskfold_private.team_members(team_id,user_id,role) values("+lit(team)+','+lit(owner.id)+",'admin'),("+lit(team)+','+lit(users.new.id)+",'member');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_project_adoption_enabled=true;update taskfold_private.audio_comment_config set enabled=true,team_publication_enabled=true,audience_review_enabled=true,project_transfer_enabled=true");
 const project=async parent=>{const response=await request('/projects',{id:randomUUID(),user_id:owner.id,name:'Mixed recording workshop',...(parent?{parent_id:parent}:{})});check('real project created',response.status,201);return response.value[0]};
 const task=async p=>{const response=await request('/tasks',{id:randomUUID(),user_id:owner.id,project_id:p.id,title:'Keep original task notes',description:'Canonical notes remain unchanged'});check('real task created',response.status,201);return response.value[0]};
 const parent=await project(),child=await project(parent.id),other=await project(),liveTask=await task(parent),removedTask=await task(child),pendingTask=await task(child),otherTask=await task(other);
 // Only invitation setup is trusted fixture SQL; every recording operation and
 // transfer below uses real Auth-issued sessions through production HTTP paths.
 await runtime.raw('set local request.jwt.claim.sub='+lit(owner.id)+';set local request.jwt.claims='+lit(JSON.stringify({sub:owner.id,session_id:owner.session}))+';insert into public.project_collaborators(id,project_id,invited_email,invited_by) values(gen_random_uuid(),'+lit(child.id)+','+lit(users.old.email)+','+lit(owner.id)+");update public.project_collaborators set status='accepted' where project_id="+lit(child.id));
 audio=await createFullSchemaAudioFixture(runtime);check('positive scoped TLS trust',audio.tlsVerified);check('negative TLS trust refusal',audio.untrustedTLSRejected);
 const media=await readFile(new URL('../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a',import.meta.url));
 const descriptor={version:1,mime_type:'audio/mp4',byte_count:media.length,duration_ms:1000,sha256:createHash('sha256').update(media).digest('hex')};
 const intent=(root,user=owner)=>({version:1,account:user.id,operation_id:randomUUID(),comment_id:randomUUID(),asset_id:randomUUID(),target:{task_id:root.id,task_generation:root.task_generation,project_id:root.project_id},caption:'Original private recording',audio:descriptor});
 const call=async(user,action,body,status=200)=>{const response=await audio.call(user.token,action,body);const bytes=Buffer.from(await response.arrayBuffer());let value;try{value=JSON.parse(bytes)}catch{value=null};if(response.status!==status)report.lastFailure={action,status:response.status,value};check(action+' HTTP '+status,response.status,status);return {value,bytes}};
 const live=intent(liveTask),removed=intent(removedTask),pending=intent(pendingTask,users.old),unrelated=intent(otherTask);
 const send=async value=>{const quote=(await call(owner,'review',{intent:value})).value;return (await call(owner,'publish',{intent:value,approval:quote.approval,audio_base64:media.toString('base64')})).value.receipt};
 const liveReceipt=await send(live);await send(removed);const unrelatedReceipt=await send(unrelated);await call(owner,'remove',{comment_id:removed.comment_id});
 const row=value=>scalar('select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id='+lit(value.operation_id));
 const objects=()=>scalar("select coalesce(jsonb_agg(to_jsonb(o) order by id),'[]'::jsonb) from storage.objects o where bucket_id='taskfold-audio-v1'");
 const snapshot=()=>scalar("select jsonb_build_object('projects',(select jsonb_agg(to_jsonb(x) order by id) from public.projects x),'tasks',(select jsonb_agg(to_jsonb(x) order by id) from public.tasks x),'ledger',(select jsonb_agg(to_jsonb(x) order by operation_id) from taskfold_private.audio_comment_publications x),'custody',(select jsonb_agg(to_jsonb(x) order by operation_id) from taskfold_private.audio_comment_custody x),'history',(select jsonb_agg(to_jsonb(x) order by operation_id) from taskfold_private.audio_project_private_history x),'objects',(select jsonb_agg(to_jsonb(x) order by id) from storage.objects x))");
 const liveBefore=await row(live),removedBefore=await row(removed),unrelatedBefore=await row(unrelated),taskBefore=await scalar('select jsonb_agg(to_jsonb(t) order by id) from public.tasks t');
 const scope={team_id:team,roots:[parent.id],visibility:'team',folder_id:null,parent_id:null};let command,receipt,providerBefore,callbackError;
 const pendingApproval=(await call(users.old,'review',{intent:pending})).value.approval;
 audio.state.afterStoragePut=async()=>{audio.state.afterStoragePut=null;try {
  const inspection=await rpc('inspect',scope),counts=inspection.contents.recording_custody,decisions=inspection.collaborators.filter(x=>x.status==='accepted').map(x=>({project_id:x.project_id,user_id:x.user_id,role:null}));
  check('real mixed inventory',counts,{protocol:1,published:1,pending:1,retained:1,unavailable:0});
  const reviewBody={...scope,inspection_token:inspection.inspection_token,decisions,recording_policy:policy,recording_count:1,unfinished_recording_count:1,retained_recording_count:1};
  await rpc('review',reviewBody,409);await runtime.raw('update taskfold_private.audio_comment_config set project_unfinished_transfer_enabled=true');await rpc('review',reviewBody,409);
  await runtime.raw('update taskfold_private.audio_comment_config set project_private_history_enabled=true');
  const current=await rpc('inspect',scope);check('explicit mixed capability',current.contents.recording_private_history_transfer,{protocol:1,supported:true});
  const fresh={...reviewBody,inspection_token:current.inspection_token};const review=await rpc('review',fresh);
  check('signed review binds every effect',[review.recording_count,review.unfinished_recording_count,review.retained_recording_count],[1,1,1]);
  command={...scope,inspection_token:review.inspection_token,decisions:review.decisions.map(({project_id,user_id,role})=>({project_id,user_id,role})),review_token:review.review_token,expires_at:review.expires_at,request_id:randomUUID(),recording_policy:policy,recording_count:1,unfinished_recording_count:1,retained_recording_count:1};
  await rpc('adopt',{...command,retained_recording_count:0},409);await rpc('adopt',{...command,unfinished_recording_count:0},409);
  for(const old of ['published_recordings_v1','move_published_stop_unfinished_v1']){const body={...fresh,recording_policy:old};delete body.retained_recording_count;if(old==='published_recordings_v1'){delete body.recording_count;delete body.unfinished_recording_count}await rpc('review',body,409)}
  providerBefore=await objects();const original=await snapshot();
  await runtime.raw("create function taskfold_private.fixture_refuse_mixed_history() returns trigger language plpgsql as $$begin raise exception 'Owned mixed-history failure';end$$;create trigger fixture_refuse_mixed_history before insert on taskfold_private.audio_project_private_history for each row execute function taskfold_private.fixture_refuse_mixed_history()");
  const failure=await rpc('adopt',command,400);check('real rollback error code',failure.code,'P0001');check('atomic rollback preserves all source state',await snapshot(),original);check('failed transfer leaves no private authority',await runtime.raw('select count(*) from taskfold_private.team_project_adoption_scope'),'0');
  await runtime.raw('drop trigger fixture_refuse_mixed_history on taskfold_private.audio_project_private_history;drop function taskfold_private.fixture_refuse_mixed_history()');
  receipt=await rpc('adopt',command);check('mixed receipt binds all effects',[receipt.applied,receipt.recording_count,receipt.unfinished_recording_count,receipt.retained_recording_count],[true,1,1,1]);
 }catch(error){callbackError=error;report.callbackFailure={message:error.message,code:error.code};throw error}};
 const crossing=await call(users.old,'publish',{intent:pending,approval:pendingApproval,audio_base64:media.toString('base64')});if(callbackError)throw callbackError;
 assert(command&&receipt,'Actual Storage POST must cross the reviewed adoption');check('crossing send closes the original request',crossing.value.closed,{protocol:1,intent:pending,state:'closed'});
 check('published original ledger remains immutable',await row(live),liveBefore);check('removed ledger remains private and exact',await row(removed),removedBefore);check('unselected publication remains exact',await row(unrelated),unrelatedBefore);
 check('adoption leaves real provider objects exact',await objects(),providerBefore);check('canonical tasks remain exact',await scalar('select jsonb_agg(to_jsonb(t) order by id) from public.tasks t'),taskBefore);
 check('published clip alone gets new custody',await runtime.raw('select count(*) from taskfold_private.audio_comment_custody'),'1');check('stopped and removed originals both get private fences',await scalar('select jsonb_agg(operation_id order by operation_id) from taskfold_private.audio_project_private_history'),[removed.operation_id,pending.operation_id].sort());
 check('new team receives exact published bytes',(await call(users.new,'download',{comment_id:live.comment_id})).bytes,media);
 for(const value of [removed,pending]){const downloads=audio.state.downloads;await call(users.new,'download',{comment_id:value.comment_id},404);check('private refusal precedes provider read '+value.operation_id,audio.state.downloads,downloads)}
 check('published receipt remains exact',(await call(owner,'resolve',{intent:live,close:false})).value.receipt,liveReceipt);check('unselected receipt remains exact',(await call(owner,'resolve',{intent:unrelated,close:false})).value.receipt,unrelatedReceipt);
 const uploads=audio.state.uploads;check('only original recordings uploaded',uploads,4);
 await runtime.raw('update taskfold_private.audio_comment_config set project_transfer_enabled=false,project_unfinished_transfer_enabled=false,project_private_history_enabled=false;update taskfold_private.team_project_config set native_project_adoption_enabled=false');
 check('exact mixed lost-reply confirmation works while paused',await rpc('adopt',command),{...receipt,replayed:true});await rpc('adopt',{...command,retained_recording_count:0},409);
 const retry=await call(users.old,'publish',{intent:pending,approval:pendingApproval,audio_base64:media.toString('base64')});check('closed original replay stays closed',retry.value.closed,crossing.value.closed);check('replay never uploads again',audio.state.uploads,uploads);
 await runtime.raw("update taskfold_private.audio_comment_publications set cleanup_after=clock_timestamp()-interval '1 second' where operation_id in("+[removed,pending].map(x=>lit(x.operation_id)).join(',')+')');
 const maintenance=await audio.maintain();report.maintenance=await maintenance.json();check('production maintenance succeeds',maintenance.status,200);
 check('actual Storage received cleanup deletes',audio.state.deletes>0);for(const value of [removed,pending])check('closed history reaches purged '+value.operation_id,(await row(value)).state,'purged');
 check('only live and unrelated provider objects remain',(await objects()).length,2);check('exact private fences survive actual deletion',await scalar('select jsonb_agg(operation_id order by operation_id) from taskfold_private.audio_project_private_history'),[removed.operation_id,pending.operation_id].sort());
 check('original sender confirms closure after real cleanup',(await call(users.old,'resolve',{intent:pending,close:false})).value.closed,crossing.value.closed);
 check('unselected ledger survives maintenance',await row(unrelated),unrelatedBefore);check('selected published bytes survive maintenance',(await call(users.new,'download',{comment_id:live.comment_id})).bytes,media);
 check('no outbound jobs queued',await runtime.raw('select count(*) from net.http_request_queue'),'0');check('scheduler remains off',await runtime.raw('show cron.launch_active_jobs'),'off');
 report.advisors=await runtime.advisors();const prior=new Set(report.baselineAdvisors.result.map(x=>x.cache_key));check('no new advisor findings',report.advisors.result.filter(x=>!prior.has(x.cache_key)),[]);
 for(const path of sourcePaths)assert.equal(await hash(path),report.sourceSHA256[path],path+' changed');report.sourceUnchanged=true;report.handlerCounters={auth:audio.state.authRequests,rpc:audio.state.rpcRequests,uploads:audio.state.uploads,downloads:audio.state.downloads,deletes:audio.state.deletes};report.checkCount=Object.keys(report.checks).length;report.accepted=true;
}catch(error){report.error={message:error.message,code:error.code,migration:error.migration};process.exitCode=1}
finally{if(audio){await audio.close();report.handlerClosed=true}if(runtime)report.servicesRemoved=await runtime.close();await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({accepted:report.accepted,error:report.error,lastFailure:report.lastFailure,checks:report.checkCount,handlerClosed:report.handlerClosed,servicesRemoved:report.servicesRemoved}))}
