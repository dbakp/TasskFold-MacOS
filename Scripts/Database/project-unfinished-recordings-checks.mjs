import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {literal as lit} from './postgres-fixture.mjs';
import {migrationSQL} from './audio-project-custody-schema.mjs';
export const unfinishedTransferMigration='20261103050050_reviewed_project_unfinished_recordings.sql';
export async function loadUnfinishedTransfer(pg,report) {
 await pg.raw(await migrationSQL('20261103021255_reviewed_audio_publication_audience.sql'));
 const sql=await migrationSQL(unfinishedTransferMigration);await pg.raw(sql);
 report.unfinishedCandidate=unfinishedTransferMigration;report.unfinishedCandidateSHA256=createHash('sha256').update(sql).digest('hex');
}
export async function checkUnfinishedTransfer({pg,http,oldHTTP,newHTTP,owner,users,team,project,task,scope,rpc,command,identity,media,descriptor,check,expect}) {
 const policy='move_published_stop_unfinished_v1',j=x=>lit(JSON.stringify(x))+'::jsonb';
 const intent=(root,actor=owner)=>({version:1,account:actor.id,operation_id:randomUUID(),comment_id:randomUUID(),asset_id:randomUUID(),target:{task_id:root.id,task_generation:root.task_generation,project_id:root.project_id},caption:'Synthetic unfinished original kept privately',audio:descriptor});
 async function quote(client,value) {const response=await client.call('review',{intent:value});check('fresh synthetic audience quote '+value.operation_id,response.status,200);return (await response.json()).approval}
 async function reserve(client,value,actor=owner) {
  const approval=await quote(client,value);
  await pg.scalar(`begin;set local role service_role;select public.taskfold_audio_comment_command('reserve_approved',${lit(actor.id)},${lit(actor.session)},${j({intent:value,approval})});commit;`);
  check('unfinished reservation exists '+value.operation_id,await pg.scalar(`select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${lit(value.operation_id)}`),'pending');return approval;
 }
 async function prepare(body) {
  const inspect=await rpc('inspect',body),decisions=inspect.collaborators.filter(x=>x.status==='accepted').map(x=>({project_id:x.project_id,user_id:x.user_id,role:null}));
  const counts=inspect.contents.recording_custody;
  const request={...body,inspection_token:inspect.inspection_token,decisions,recording_policy:policy,recording_count:counts.published,unfinished_recording_count:counts.pending};
  const review=await rpc('review',request);
  return {inspect,decisions,request,review,command:{...command(body,review),recording_count:review.recording_count,unfinished_recording_count:review.unfinished_recording_count}};
 }
 check('unfinished project policy defaults off',await pg.scalar('select to_jsonb(project_unfinished_transfer_enabled) from taskfold_private.audio_comment_config'),false);
 await pg.raw('update taskfold_private.audio_comment_config set audience_review_enabled=true,project_transfer_enabled=true');
 const p=await project(),child=await project(p),body=scope(p),publishedRoot=await task(p),waitingRoot=await task(child),uploadingRoot=await task(child);
 await pg.raw(`begin;${identity()}insert into public.project_collaborators(id,project_id,invited_email,invited_by) values(gen_random_uuid(),${lit(child)},${lit(users.old.id+'@example.invalid')},${lit(owner.id)});update public.project_collaborators set status='accepted' where project_id=${lit(child)};commit;`);
 const published=intent(publishedRoot),pending=intent(waitingRoot),uploading=intent(uploadingRoot,users.old),approvedPublished=await quote(http,published);
 const sent=await http.call('publish',{intent:published,approval:approvedPublished,audio_base64:media.toString('base64')});check('mixed source publication succeeds',sent.status,200);const originalReceipt=(await sent.json()).receipt;
 const pendingApproval=await reserve(http,pending);
 const disabled=await rpc('inspect',body),noChoice={...body,inspection_token:disabled.inspection_token,decisions:disabled.collaborators.filter(x=>x.status==='accepted').map(x=>({project_id:x.project_id,user_id:x.user_id,role:null}))};
 check('old published-only capability refuses unfinished sends',disabled.contents.recording_transfer,{protocol:1,supported:false});
 check('separate unfinished capability is explicitly paused',disabled.contents.recording_unfinished_transfer,{protocol:1,supported:false});
 await expect('stopping unfinished sends requires enabled policy',()=>rpc('review',{...noChoice,recording_policy:policy,recording_count:1,unfinished_recording_count:1}),'PT409');
 await pg.raw('update taskfold_private.audio_comment_config set project_unfinished_transfer_enabled=true,audience_review_enabled=false');
 check('unfinished transfer requires audience enforcement',(await rpc('inspect',body)).contents.recording_unfinished_transfer.supported,false);
 await pg.raw('update taskfold_private.audio_comment_config set audience_review_enabled=true');
 const noConsent=await rpc('review',{...noChoice,inspection_token:(await rpc('inspect',body)).inspection_token});
 await expect('unfinished sends cannot move without explicit choice',()=>rpc('adopt',command(body,noConsent)),'PT409');
 const ready=await prepare(body);
 check('unfinished policy is advertised separately',ready.inspect.contents.recording_unfinished_transfer,{protocol:1,supported:true});
 check('legacy published-only capability remains false',ready.inspect.contents.recording_transfer.supported,false);
 await expect('old published-only choice cannot stop a send',()=>rpc('review',{...noChoice,inspection_token:ready.inspect.inspection_token,recording_policy:'published_recordings_v1'}),'PT409');
 await expect('missing stop count is refused',()=>{const b={...ready.request};delete b.unfinished_recording_count;return rpc('review',b)},'22023');
 await expect('different stop count cannot reuse review',()=>rpc('adopt',{...ready.command,unfinished_recording_count:2}),'PT409');
 const unrelatedProject=await project(),unrelatedTask=await task(unrelatedProject),unrelated=intent(unrelatedTask);await reserve(http,unrelated);
 const unrelatedBefore=await pg.scalar(`select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${lit(unrelated.operation_id)}`);
 const approvedUploading=await quote(oldHTTP,uploading),uploadsBefore=http.state.uploads+oldHTTP.state.uploads;
 let accepted,receipt,providerFailure;
 oldHTTP.state.afterPut=async()=>{try {
  oldHTTP.state.afterPut=null;
  accepted=await prepare(body);
  check('review binds one published and two unfinished',accepted.inspect.contents.recording_custody,{protocol:1,published:1,pending:2,retained:0,unavailable:0});
  check('review preserves published move count',accepted.review.recording_count,1);check('review confirms explicit stop count',accepted.review.unfinished_recording_count,2);
  const publishedBefore=await pg.scalar(`select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${lit(published.operation_id)}`);
  const all=()=>pg.scalar(`select jsonb_build_object('projects',(select jsonb_agg(to_jsonb(x) order by id) from public.projects x where id in(${lit(p)},${lit(child)})),'recordings',(select jsonb_agg(to_jsonb(r) order by operation_id) from taskfold_private.audio_comment_publications r where project_id in(${lit(p)},${lit(child)})),'provider',(select jsonb_agg(to_jsonb(o) order by id) from storage.objects o))`);
  const before=await all(),objectName=await pg.scalar(`select to_jsonb(object_name) from taskfold_private.audio_comment_publications where operation_id=${lit(uploading.operation_id)}`);
  await pg.raw(`update storage.objects set version='changed' where name=${lit(objectName)}`);
  await expect('changed pending provider metadata refuses old consent',()=>rpc('adopt',accepted.command),'PT409');
  await pg.raw(`update storage.objects set version=null where name=${lit(objectName)}`);
  await pg.raw("create function taskfold_private.fixture_refuse_unfinished_stop() returns trigger language plpgsql as $$begin if old.state='pending' and new.state='retired' then raise exception 'Synthetic stop failure';end if;return new;end$$;create trigger fixture_refuse_unfinished_stop before update on taskfold_private.audio_comment_publications for each row execute function taskfold_private.fixture_refuse_unfinished_stop()");
  await expect('stop failure rolls back project and published custody',()=>rpc('adopt',accepted.command),'P0001');
  check('rollback preserves exact projects recordings provider metadata',await all(),before);
  check('rollback leaves no custody for new published recording',await pg.scalar(`select count(*)::int from taskfold_private.audio_comment_custody where operation_id=${lit(published.operation_id)}`),0);
  check('rollback removes all private transfer authority',await pg.scalar('select count(*)::int from taskfold_private.team_project_adoption_scope'),0);
  await pg.raw('drop trigger fixture_refuse_unfinished_stop on taskfold_private.audio_comment_publications;drop function taskfold_private.fixture_refuse_unfinished_stop()');
  receipt=await rpc('adopt',accepted.command);
  check('mixed move and stop applies atomically',receipt.applied);check('receipt binds exact published count',receipt.recording_count,1);check('receipt binds exact stopped count',receipt.unfinished_recording_count,2);
  check('published original ledger remains immutable',await pg.scalar(`select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${lit(published.operation_id)}`),publishedBefore);
 } catch(error) { providerFailure=error;throw error; }};
 const crossing=await oldHTTP.call('publish',{intent:uploading,approval:approvedUploading,audio_base64:media.toString('base64')});
 if(providerFailure)throw providerFailure;
 check('upload crossing adoption returns closure not publication',crossing.status,200);check('crossing closure binds original immutable intent',(await crossing.json()).closed,{protocol:1,intent:uploading,state:'closed'});
 assert(accepted&&receipt,'Actual provider callback must execute reviewed adoption');
 check('adoption performs no extra media uploads',http.state.uploads+oldHTTP.state.uploads,uploadsBefore+1);
 for(const value of [pending,uploading]) {
  const row=await pg.scalar(`select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${lit(value.operation_id)}`);
  check('unfinished ledger is retired '+value.operation_id,row.state,'retired');check('unfinished payload is not exposed '+value.operation_id,[row.caption,row.audio_descriptor],[null,null]);
  check('unfinished media gets no new team custody '+value.operation_id,await pg.scalar(`select count(*)::int from taskfold_private.audio_comment_custody where operation_id=${lit(value.operation_id)}`),0);
  const client=value.account===owner.id?http:oldHTTP,resolved=await client.call('resolve',{intent:value,close:false});check('original sender receives exact closed proof '+value.operation_id,(await resolved.json()).closed,{protocol:1,intent:value,state:'closed'});
  const count=client.state.uploads,replay=await client.call('publish',{intent:value,approval:value===uploading?approvedUploading:pendingApproval,audio_base64:media.toString('base64')});
  check('retired original cannot upload '+value.operation_id,replay.status,200);await replay.arrayBuffer();check('retired original never reuploads '+value.operation_id,client.state.uploads,count);
  const blocked=await newHTTP.call('download',{comment_id:value.comment_id});check('team never downloads unfinished bytes '+value.operation_id,blocked.status,404);await blocked.arrayBuffer();
 }
 const wrongSender=await newHTTP.call('publish',{intent:{...pending,account:users.new.id},approval:pendingApproval,audio_base64:media.toString('base64')});check('terminal history cannot be adopted by another sender',wrongSender.status,404);await wrongSender.arrayBuffer();
 const wrongIntent=await http.call('publish',{intent:{...pending,caption:'Changed original caption'},approval:pendingApproval,audio_base64:media.toString('base64')});check('terminal history rejects a different original request',wrongIntent.status,409);await wrongIntent.arrayBuffer();
 check('unselected pending recording remains exact',await pg.scalar(`select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${lit(unrelated.operation_id)}`),unrelatedBefore);
 const teamRead=await newHTTP.call('download',{comment_id:published.comment_id});check('team reads the moved published original',teamRead.status,200);check('moved published bytes stay exact',Buffer.from(await teamRead.arrayBuffer()),media);
 const sender=await http.call('resolve',{intent:published,close:false});check('published sender receipt remains exact',(await sender.json()).receipt,originalReceipt);
 await pg.raw('update taskfold_private.audio_comment_config set project_unfinished_transfer_enabled=false,project_transfer_enabled=false;update taskfold_private.team_project_config set native_project_adoption_enabled=false');
 check('mixed saved request replays while gates are paused',await rpc('adopt',accepted.command),{...receipt,replayed:true});
 await expect('changed stopped count cannot reuse saved request ID',()=>rpc('adopt',{...accepted.command,unfinished_recording_count:1}),'PT409');
 await pg.raw('update taskfold_private.audio_comment_config set project_unfinished_transfer_enabled=true,project_transfer_enabled=true;update taskfold_private.team_project_config set native_project_adoption_enabled=true');
 const only=await project(),onlyRoot=await task(only),onlyIntent=intent(onlyRoot);await reserve(http,onlyIntent);const onlyReview=await prepare(scope(only));
 check('pending-only move explicitly reviews zero published',onlyReview.review.recording_count,0);check('pending-only move reviews one stopped send',onlyReview.review.unfinished_recording_count,1);
 await pg.raw('update taskfold_private.audio_comment_config set project_unfinished_transfer_enabled=false');await expect('pausing unfinished support refuses before stopping',()=>rpc('adopt',onlyReview.command),'PT409');check('paused review keeps unfinished pending',await pg.scalar(`select to_jsonb(state) from taskfold_private.audio_comment_publications where operation_id=${lit(onlyIntent.operation_id)}`),'pending');
 await pg.raw('update taskfold_private.audio_comment_config set project_unfinished_transfer_enabled=true');const onlyReceipt=await rpc('adopt',onlyReview.command);check('pending-only branch adopts successfully',onlyReceipt.applied);check('pending-only branch creates no media custody',await pg.scalar(`select count(*)::int from taskfold_private.audio_comment_custody where project_id=${lit(only)}`),0);
 const stopped=[pending,uploading,onlyIntent],stoppedIDs=stopped.map(v=>lit(v.operation_id)).join(',');
 check('stopped upload byte remains private until fenced cleanup',http.state.objects.has(await pg.scalar(`select to_jsonb(object_name) from taskfold_private.audio_comment_publications where operation_id=${lit(uploading.operation_id)}`)));
 await pg.raw(`update taskfold_private.audio_comment_publications set cleanup_after=clock_timestamp()-interval '1 second' where operation_id in(${stoppedIDs})`);
 const cleaned=await http.maintain();check('stopped media cleanup uses ordinary maintenance',cleaned.status,200);await cleaned.json();
 check('all selected stopped operations reach purged history',await pg.scalar(`select count(*)::int from taskfold_private.audio_comment_publications where operation_id in(${stoppedIDs}) and state='purged'`),3);
 const stoppedName=await pg.scalar(`select to_jsonb(object_name) from taskfold_private.audio_comment_publications where operation_id=${lit(uploading.operation_id)}`);
 check('stopped provider bytes are removed',http.state.objects.has(stoppedName),false);
 const afterCleanup=await oldHTTP.call('resolve',{intent:uploading,close:false});check('original sender still confirms closure after cleanup',(await afterCleanup.json()).closed,{protocol:1,intent:uploading,state:'closed'});
 check('unselected unfinished original is not cleaned',await pg.scalar(`select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${lit(unrelated.operation_id)}`),unrelatedBefore);
 for(const fn of ['project_unfinished_recording_transfer_supported(jsonb)','project_recording_policy_supported(text,jsonb)'])for(const role of ['anon','authenticated','service_role'])check('unfinished helper remains private '+role+' '+fn,await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},${lit('taskfold_private.'+fn)},'execute'))`),false);
 return {syntheticOnly:true,account:owner.id,origin:'https://synthetic.example',body,inspect:accepted.inspect,decisions:accepted.decisions,review:accepted.review,command:accepted.command,receipt,replayed:{...receipt,replayed:true},pendingOnly:{body:scope(only),inspect:onlyReview.inspect,decisions:onlyReview.decisions,review:onlyReview.review,command:onlyReview.command,receipt:onlyReceipt}};
}
