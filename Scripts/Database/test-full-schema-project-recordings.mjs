import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
import {createFullSchemaAudioFixture} from './full-schema-audio-fixture.mjs';
const output=process.argv[2];assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));
const report={checks:{},genuineLocalAuth:true,genuineLocalPostgREST:true,genuineLocalStorage:true,validatedLoopbackTLS:true,productionHandler:true,storageBackend:'Pinned Storage API with disposable tmpfs file backend; not hosted S3',hostedChanges:false,normalUseEnabled:false,nativeAppAccepted:false};
const check=(name,value,expected=true)=>{assert.deepEqual(value,expected,name);report.checks[name]=true;console.log('passed',name)};
const ok=(name,response,status=200)=>{if(response.status!==status)report.lastFailure={name,status:response.status,value:response.value};check(name,response.status,status);return response.value};
const lit=x=>"'"+String(x).replaceAll("'","''")+"'";
const sourcePaths=['Scripts/Database/full-schema-runtime.mjs','Scripts/Database/full-schema-gateway.mjs','Scripts/Database/full-schema-audio-fixture.mjs','Scripts/Database/full-schema-audio-server.ts','Scripts/Database/test-full-schema-project-recordings.mjs','supabase/functions/audio-comments/handler.ts','supabase/functions/audio-comments/wire.ts'];
const sourceHash=async path=>createHash('sha256').update(await readFile(new URL('../../'+path,import.meta.url))).digest('hex');
report.sourceSHA256=Object.fromEntries(await Promise.all(sourcePaths.map(async path=>[path,await sourceHash(path)])));
let runtime,audio;
try{
 runtime=await createFullSchemaRuntime({onMigration:name=>console.log('replayed',name)});report.migrations=runtime.migrations;report.images=runtime.images;
 report.baselineAdvisors=await runtime.advisors();
 const users={};for(const name of ['owner','old','new']){
  const email='audio-'+name+'@example.invalid',password='Disposable-'+randomUUID()+'!';
  const value=ok('genuine signup '+name,await runtime.request('auth','/signup',{method:'POST',body:{email,password}}));
  const claims=JSON.parse(Buffer.from(value.access_token.split('.')[1],'base64url'));
  check('Auth issued a live session '+name,typeof claims.session_id==='string');users[name]={id:value.user.id,email,token:value.access_token,session:claims.session_id};
 }
 const owner=users.owner,team=randomUUID();
 const request=(path,body,user=owner,method='POST')=>runtime.request('rest',path,{authorization:user.token,method,...(body===undefined?{}:{body}),headers:{Prefer:'return=representation'}});
 const rpc=async(operation,body,user=owner,status=200)=>ok(operation,await request('/rpc/taskfold_team_project_adoption',{operation,body},user),status);
 const scalar=async sql=>JSON.parse(await runtime.raw('select to_jsonb(value) from ('+sql+') fixture(value)'));
 await runtime.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'Genuine recording workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin'),(${lit(team)},${lit(users.new.id)},'member');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_project_adoption_enabled=true;update taskfold_private.audio_comment_config set enabled=true,team_publication_enabled=true,audience_review_enabled=true;`);
 check('recording transfer remains disabled initially',await scalar('select project_transfer_enabled from taskfold_private.audio_comment_config'),false);
 const makeProject=async parent=>ok('genuine project insert',await request('/projects',{id:randomUUID(),user_id:owner.id,name:'Genuine recording workshop',...(parent?{parent_id:parent}:{})}),201)[0];
 const parent=await makeProject(),child=await makeProject(parent.id),projects=[parent.id,child.id],roots=[];
 for(const project of projects){roots.push(ok('genuine task insert',await request('/tasks',{id:randomUUID(),user_id:owner.id,project_id:project,title:'Preserve the recording'}),201)[0]);
  // Trusted fixture membership setup uses actual Auth-issued identities/sessions;
  // reads/publication/adoption below use genuine JWT-authenticated HTTP APIs.
  await runtime.raw(`set local request.jwt.claim.sub=${lit(owner.id)};set local request.jwt.claims=${lit(JSON.stringify({sub:owner.id,session_id:owner.session}))};insert into public.project_collaborators(id,project_id,invited_email,invited_by) values(gen_random_uuid(),${lit(project)},${lit(users.old.email)},${lit(owner.id)});update public.project_collaborators set status='accepted' where project_id=${lit(project)};`);
 }
 audio=await createFullSchemaAudioFixture(runtime);check('handler TLS has an explicitly trusted task-owned CA',audio.tlsVerified);check('the same handler rejects an untrusted TLS client',audio.untrustedTLSRejected);
 const media=await readFile(new URL('../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a',import.meta.url));
 const descriptor={version:1,mime_type:'audio/mp4',byte_count:media.length,duration_ms:1000,sha256:createHash('sha256').update(media).digest('hex')};
 const intent=root=>({version:1,account:owner.id,operation_id:randomUUID(),comment_id:randomUUID(),asset_id:randomUUID(),target:{task_id:root.id,task_generation:root.task_generation,project_id:root.project_id},caption:'Keep the original synthetic recording',audio:descriptor});
 const intents=roots.map(intent),receipts=[];
 const call=async(user,action,body,status=200)=>{const response=await audio.call(user.token,action,body);const bytes=Buffer.from(await response.arrayBuffer());let value;try{value=JSON.parse(bytes.toString())}catch{value=null};if(response.status!==status)report.lastFailure={name:action,status:response.status,value};check(action+' HTTP '+status,response.status,status);return {value,bytes}};
 for(const body of intents){const review=await call(owner,'review',{intent:body});const published=await call(owner,'publish',{intent:body,approval:review.value.approval,audio_base64:media.toString('base64')});receipts.push(published.value.receipt)}
 check('actual Storage received two original uploads',audio.state.uploads,2);
 for(const body of intents)check('old personal audience receives exact original bytes '+body.comment_id,(await call(users.old,'download',{comment_id:body.comment_id})).bytes,media);
 const beforeDenied=audio.state.downloads;await call(users.new,'download',{comment_id:intents[0].comment_id},404);check('not-yet-authorized team reader cannot fetch provider bytes',audio.state.downloads,beforeDenied);
 const oldPrivateIntent=intent(roots[0]),oldApproval=(await call(owner,'review',{intent:oldPrivateIntent})).value.approval;
 const scope={team_id:team,roots:[parent.id],visibility:'team',folder_id:null,parent_id:null};
 const inspect=await rpc('inspect',scope),decisions=inspect.collaborators.filter(x=>x.status==='accepted').map(x=>({project_id:x.project_id,user_id:x.user_id,role:null}));
 check('full-schema inventory reports two published recordings',inspect.contents.recording_custody,{protocol:1,published:2,pending:0,retained:0,unavailable:0});
 await rpc('review',{...scope,inspection_token:inspect.inspection_token,decisions,recording_policy:'published_recordings_v1'},owner,409);
 await runtime.raw('update taskfold_private.audio_comment_config set project_transfer_enabled=true');
 const current=await rpc('inspect',scope),review=await rpc('review',{...scope,inspection_token:current.inspection_token,decisions,recording_policy:'published_recordings_v1'});
 check('review binds the actual recording count',review.recording_count,2);
 const command={...scope,inspection_token:review.inspection_token,decisions:review.decisions.map(({project_id,user_id,role})=>({project_id,user_id,role})),review_token:review.review_token,expires_at:review.expires_at,request_id:randomUUID(),recording_policy:'published_recordings_v1'};
 const ledger=()=>scalar('select coalesce(jsonb_agg(to_jsonb(r) order by operation_id),\'[]\'::jsonb) from taskfold_private.audio_comment_publications r');
 const objects=()=>scalar("select coalesce(jsonb_agg(to_jsonb(o) order by id),'[]'::jsonb) from storage.objects o where bucket_id='taskfold-audio-v1'");
 const originalLedger=await ledger(),originalObjects=await objects();let receipt;
 audio.state.afterStorageGet=async()=>{audio.state.afterStorageGet=null;receipt=await rpc('adopt',command)};
 const crossing=await call(users.old,'download',{comment_id:intents[0].comment_id},404);check('real Storage download crossing audience change withholds bytes',crossing.value.code,'unavailable');
 check('genuine adoption commits exact published recording policy',receipt.recording_policy,'published_recordings_v1');check('whole reviewed branch enters team',await scalar(`select count(*)::int from taskfold_private.team_content_projects where team_id=${lit(team)} and project_id in(${projects.map(lit).join(',')})`),2);
 check('publication ledger remains immutable',await ledger(),originalLedger);check('real Storage identities and metadata remain unchanged',await objects(),originalObjects);
 check('exactly two custody records exist',await scalar('select count(*)::int from taskfold_private.audio_comment_custody'),2);
 for(let index=0;index<intents.length;index++){
  check('new team audience receives original bytes '+index,(await call(users.new,'download',{comment_id:intents[index].comment_id})).bytes,media);
  check('owner resolves immutable original receipt '+index,(await call(owner,'resolve',{intent:intents[index],close:false})).value.receipt,receipts[index]);
 }
 const deniedCount=audio.state.downloads;await call(users.old,'download',{comment_id:intents[0].comment_id},404);check('retired audience is denied before another Storage read',audio.state.downloads,deniedCount);
 await call(owner,'publish',{intent:oldPrivateIntent,approval:oldApproval,audio_base64:media.toString('base64')},409);check('old private-audience approval cannot upload to a changed team audience',audio.state.uploads,2);
 for(const user of [owner,users.new]){
  const response=await fetch(runtime.urls.storage+'/object/authenticated/taskfold-audio-v1/'+originalObjects[0].name,{headers:{apikey:runtime.anon,Authorization:'Bearer '+user.token}});await response.arrayBuffer();check('direct authenticated Storage bypass is refused '+(user===owner?'owner':'new'),[400,403,404].includes(response.status));
 }
 await runtime.raw('update taskfold_private.audio_comment_config set project_transfer_enabled=false;update taskfold_private.team_project_config set native_project_adoption_enabled=false');
 check('exact lost-reply replay confirms while fresh transfers are paused',await rpc('adopt',command),{...receipt,replayed:true});
 check('replay cannot duplicate custody',await scalar('select count(*)::int from taskfold_private.audio_comment_custody'),2);check('transfers and replay never replace media',audio.state.uploads,2);
 ok('real team-reader session logout',await runtime.request('auth','/logout?scope=global',{method:'POST',authorization:users.new.token}),204);
 const revokedDownloads=audio.state.downloads;await call(users.new,'download',{comment_id:intents[0].comment_id},401);check('revoked real JWT session cannot reach Storage',audio.state.downloads,revokedDownloads);
 check('no outbound jobs were queued',await runtime.raw('select count(*) from net.http_request_queue'),'0');check('scheduler remains disabled',await runtime.raw('show cron.launch_active_jobs'),'off');
 report.advisors=await runtime.advisors();const prior=new Set(report.baselineAdvisors.result.map(x=>x.cache_key));check('no new advisor findings',report.advisors.result.filter(x=>!prior.has(x.cache_key)),[]);
 report.handlerRequests={auth:audio.state.authRequests,rpc:audio.state.rpcRequests,uploads:audio.state.uploads,downloads:audio.state.downloads};for(const path of sourcePaths)assert.equal(await sourceHash(path),report.sourceSHA256[path],path+' changed during verification');report.currentSourceUnchanged=true;report.checkCount=Object.keys(report.checks).length;report.accepted=true;
}catch(error){report.error={message:error.message,code:error.code,migration:error.migration};process.exitCode=1}
finally{if(audio){await audio.close();report.handlerClosed=true}if(runtime)report.cleanedUp=await runtime.close();await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({accepted:report.accepted,error:report.error,lastFailure:report.lastFailure,checks:report.checkCount,cleanedUp:report.cleanedUp,handlerClosed:report.handlerClosed}))}
