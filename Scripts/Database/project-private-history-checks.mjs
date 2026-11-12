import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {literal as lit} from './postgres-fixture.mjs';
import {migrationSQL} from './audio-project-custody-schema.mjs';
export const privateHistoryMigration='20261103072323_reviewed_project_private_recording_history.sql';
export async function loadPrivateHistory(pg,report) {
 const sql=await migrationSQL(privateHistoryMigration);await pg.raw(sql);
 report.privateHistoryCandidate=privateHistoryMigration;report.privateHistoryCandidateSHA256=createHash('sha256').update(sql).digest('hex');
}
export async function checkPrivateHistory({pg,http,newHTTP,owner,team,project,task,scope,rpc,command,media,descriptor,check,expect}) {
 const history='move_recordings_keep_removed_private_v1',stop='move_published_stop_unfinished_v1',j=x=>lit(JSON.stringify(x))+'::jsonb';
 const intent=t=>({version:1,account:owner.id,operation_id:randomUUID(),comment_id:randomUUID(),asset_id:randomUUID(),target:{task_id:t.id,task_generation:t.task_generation,project_id:t.project_id},caption:'Synthetic private removed history',audio:descriptor});
 const row=i=>pg.scalar(`select to_jsonb(r) from taskfold_private.audio_comment_publications r where operation_id=${lit(i.operation_id)}`);
 async function approve(i) {const r=await http.call('review',{intent:i});check('history source gets explicit audience approval '+i.operation_id,r.status,200);return (await r.json()).approval}
 async function publish(i) {const approval=await approve(i),r=await http.call('publish',{intent:i,approval,audio_base64:media.toString('base64')});check('history source publishes '+i.operation_id,r.status,200);return (await r.json()).receipt}
 async function reserve(i) {const approval=await approve(i);await pg.scalar(`begin;set local role service_role;select public.taskfold_audio_comment_command('reserve_approved',${lit(owner.id)},${lit(owner.session)},${j({intent:i,approval})});commit;`)}
 async function remove(i) {const r=await http.call('remove',{comment_id:i.comment_id});check('history source removal uses real handler '+i.operation_id,r.status,200);await r.json()}
 async function closed(i) {const r=await http.call('resolve',{intent:i,close:false});check('private sender resolves removed original '+i.operation_id,r.status,200);check('private sender keeps exact closure '+i.operation_id,(await r.json()).closed,{protocol:1,intent:i,state:'closed'})}
 async function route(p) {const id=randomUUID();await pg.raw(`insert into taskfold_private.email_routes(id,user_id,name,alias_hash,alias_domain,project_id,sender_email,requested_at,state) values(${lit(id)},${lit(owner.id)},'Private history route',${lit(createHash('sha256').update(id).digest('hex'))},'capture.example.invalid',${lit(p)},'synthetic@example.invalid',now(),'active')`);return id}
 async function prepare(body,policy=history,pause=false) {
  const inspect=await rpc('inspect',body),v=inspect.contents.recording_custody,decisions=inspect.collaborators.filter(x=>x.status==='accepted').map(x=>({project_id:x.project_id,user_id:x.user_id,role:null}));
  const request={...body,inspection_token:inspect.inspection_token,decisions,recording_policy:policy,recording_count:v.published,unfinished_recording_count:v.pending,...(policy===history?{retained_recording_count:v.retained}:{}),...(pause?{connection_policy:'pause'}:{})};
  const review=await rpc('review',request),c={...command(body,review),recording_count:review.recording_count,unfinished_recording_count:review.unfinished_recording_count,...(policy===history?{retained_recording_count:review.retained_recording_count}:{}),...(pause?{connection_policy:'pause'}:{})};
  return {body,inspect,decisions,request,review,command:c};
 }
 check('private history adoption defaults off',await pg.scalar('select to_jsonb(project_private_history_enabled) from taskfold_private.audio_comment_config'),false);
 const p=await project(),body=scope(p),liveTask=await task(p),waitingTask=await task(p),removedTask=await task(p),orphanTask=await task(p);
 const live=intent(liveTask),waiting=intent(waitingTask),removed=intent(removedTask),orphan=intent(orphanTask);
 const originalLiveReceipt=await publish(live);await reserve(waiting);await publish(removed);await remove(removed);await publish(orphan);await remove(orphan);
 const orphanName=(await row(orphan)).object_name;
 // Model already-cleaned provider data with an outstanding removed ledger,
 // and a task deleted independently of the project. Neither is live media.
 await pg.raw(`delete from storage.objects where bucket_id='taskfold-audio-v1' and name=${lit(orphanName)};delete from public.tasks where id=${lit(orphanTask.id)}`);http.state.objects.delete(orphanName);
 const inspection=await rpc('inspect',body);
 check('removed history counts do not need live task or bytes',inspection.contents.recording_custody,{protocol:1,published:1,pending:1,retained:2,unavailable:0});
 check('removed capability remains paused independently',inspection.contents.recording_private_history_transfer,{protocol:1,supported:false});
 await expect('new private history choice requires enabled gate',()=>prepare(body),'PT409');
 await pg.raw('update taskfold_private.audio_comment_config set project_private_history_enabled=true');
 const alias=await route(p),prepared=await prepare(body,history,true);
 check('new history capability explicitly supports reviewed private retention',prepared.inspect.contents.recording_private_history_transfer,{protocol:1,supported:true});
 check('legacy capabilities still refuse removed records',[prepared.inspect.contents.recording_transfer.supported,prepared.inspect.contents.recording_unfinished_transfer.supported],[false,false]);
 check('mixed review binds every recording effect',[prepared.review.recording_count,prepared.review.unfinished_recording_count,prepared.review.retained_recording_count],[1,1,2]);
 check('mixed private-history review also binds connection pause',prepared.review.connection_effects.email_routes_paused,1);
 await expect('missing removed-history count is rejected',()=>{const b={...prepared.request};delete b.retained_recording_count;return rpc('review',b)},'22023');
 await expect('changed removed-history count is rejected',()=>rpc('adopt',{...prepared.command,retained_recording_count:1}),'PT409');
 await expect('changed stop count cannot share history proof',()=>rpc('adopt',{...prepared.command,unfinished_recording_count:0}),'PT409');
 await expect('old stop policy cannot move removed history',()=>rpc('review',{...prepared.request,recording_policy:stop,retained_recording_count:undefined}),'PT409');
 const withoutPause=await prepare(body);await expect('private history cannot bypass connection consent',()=>rpc('adopt',withoutPause.command),'PT409');
 await pg.raw('update taskfold_private.audio_comment_config set project_unfinished_transfer_enabled=false');
 check('history policy honors separate stop pause',(await rpc('inspect',body)).contents.recording_private_history_transfer.supported,false);
 await expect('paused stopping keeps mixed adoption refused',()=>rpc('adopt',prepared.command),'PT409');
 await pg.raw('update taskfold_private.audio_comment_config set project_unfinished_transfer_enabled=true');
 const storedName=(await row(removed)).object_name;await pg.raw(`update storage.objects set version='changed-history' where name=${lit(storedName)}`);
 await expect('changed removed provider metadata invalidates signed review',()=>rpc('adopt',prepared.command),'PT409');await pg.raw(`update storage.objects set version=null where name=${lit(storedName)}`);
 const removedBefore=[await row(removed),await row(orphan)],liveBefore=await row(live),waitingBefore=await row(waiting),uploads=http.state.uploads;
 await pg.raw("create function taskfold_private.fixture_refuse_private_history() returns trigger language plpgsql as $$begin raise exception 'Synthetic history fence failure';end$$;create trigger fixture_refuse_private_history before insert on taskfold_private.audio_project_private_history for each row execute function taskfold_private.fixture_refuse_private_history()");
 await expect('history fence failure rolls back whole adoption',()=>rpc('adopt',prepared.command),'P0001');
 check('failed history adoption leaves no project realm',await pg.scalar(`select count(*)::int from taskfold_private.team_content_projects where project_id=${lit(p)}`),0);
 check('failed history adoption leaves no live custody',await pg.scalar(`select count(*)::int from taskfold_private.audio_comment_custody where operation_id=${lit(live.operation_id)}`),0);
 check('failed history adoption preserves unfinished intent',await row(waiting),waitingBefore);
 check('failed history adoption leaves connection active',await pg.scalar(`select to_jsonb(state) from taskfold_private.email_routes where id=${lit(alias)}`),'active');
 check('failed history adoption leaves no private authority',await pg.scalar('select count(*)::int from taskfold_private.team_project_adoption_scope'),0);
 await pg.raw('drop trigger fixture_refuse_private_history on taskfold_private.audio_project_private_history;drop function taskfold_private.fixture_refuse_private_history()');
 const receipt=await rpc('adopt',prepared.command);
 check('live move stop and private history commit together',[receipt.applied,receipt.recording_count,receipt.unfinished_recording_count,receipt.retained_recording_count],[true,1,1,2]);
 check('combined history commit pauses reviewed route',await pg.scalar(`select to_jsonb(state) from taskfold_private.email_routes where id=${lit(alias)}`),'paused');
 check('published original remains immutable with private history',await row(live),liveBefore);
 check('removed ledgers remain byte-for-byte unchanged',[await row(removed),await row(orphan)],removedBefore);
 const closedIDs=[waiting,removed,orphan].map(i=>lit(i.operation_id)).join(',');
 check('all closed originals are fenced privately',await pg.scalar(`select count(*)::int from taskfold_private.audio_project_private_history where operation_id in(${closedIDs})`),3);
 check('closed history never acquires team custody',await pg.scalar(`select count(*)::int from taskfold_private.audio_comment_custody where operation_id in(${closedIDs})`),0);
 check('private history transfer never reuploads media',http.state.uploads,uploads);
 for(const i of [removed,orphan,waiting]) {await closed(i);const before=newHTTP.state.storageRequests,r=await newHTTP.call('download',{comment_id:i.comment_id});check('team cannot read private removed history '+i.operation_id,r.status,404);await r.arrayBuffer();check('private refusal precedes storage read '+i.operation_id,newHTTP.state.storageRequests,before)}
 await expect('private removed original cannot be resurrected into team',()=>pg.raw(`update taskfold_private.audio_comment_publications set state='published',caption=${lit(removed.caption)},audio_descriptor=${j(removed.audio)},cleanup_after=null where operation_id=${lit(removed.operation_id)}`),'PT409');
 const fresh=intent(liveTask);await publish(fresh);const freshRead=await newHTTP.call('download',{comment_id:fresh.comment_id});check('fresh separately approved publication can reach team',freshRead.status,200);check('fresh publication bytes are exact',Buffer.from(await freshRead.arrayBuffer()),media);
 const sender=await http.call('resolve',{intent:live,close:false});check('published immutable sender receipt survives private history',(await sender.json()).receipt,originalLiveReceipt);
 await pg.raw('update taskfold_private.audio_comment_config set project_private_history_enabled=false,project_unfinished_transfer_enabled=false,project_transfer_enabled=false;update taskfold_private.team_project_config set native_project_adoption_enabled=false');
 check('exact private history receipt replays after all pauses',await rpc('adopt',prepared.command),{...receipt,replayed:true});
 await expect('changed private count cannot reuse recorded identity',()=>rpc('adopt',{...prepared.command,retained_recording_count:1}),'PT409');
 await pg.raw('update taskfold_private.audio_comment_config set project_private_history_enabled=true,project_transfer_enabled=true;update taskfold_private.team_project_config set native_project_adoption_enabled=true');
 const only=await project(),onlyTask=await task(only),onlyIntent=intent(onlyTask);await reserve(onlyIntent);const close=await http.call('resolve',{intent:onlyIntent,close:true});check('removed-only preparation closes original send',close.status,200);await close.json();
 const onlyPrepared=await prepare(scope(only));check('removed-only review binds zero live and zero unfinished',[onlyPrepared.review.recording_count,onlyPrepared.review.unfinished_recording_count,onlyPrepared.review.retained_recording_count],[0,0,1]);
 const onlyReceipt=await rpc('adopt',onlyPrepared.command);check('removed-only project adopts without moving bytes',onlyReceipt.applied);check('removed-only adoption creates no team media',await pg.scalar(`select count(*)::int from taskfold_private.audio_comment_custody where project_id=${lit(only)}`),0);
 const cleanupIDs=closedIDs+','+lit(onlyIntent.operation_id);await pg.raw(`update taskfold_private.audio_comment_publications set cleanup_after=clock_timestamp()-interval '1 second' where operation_id in(${cleanupIDs})`);
 const cleanup=await http.maintain();check('ordinary cleanup still handles private history',cleanup.status,200);await cleanup.json();
 check('private removed operations reach purged history',await pg.scalar(`select count(*)::int from taskfold_private.audio_comment_publications where operation_id in(${cleanupIDs}) and state='purged'`),4);
 check('privacy fences survive physical cleanup',await pg.scalar(`select count(*)::int from taskfold_private.audio_project_private_history where operation_id in(${cleanupIDs})`),4);
 await expect('purged original cannot reopen after cleanup',()=>pg.raw(`update taskfold_private.audio_comment_publications set state='pending' where operation_id=${lit(onlyIntent.operation_id)}`),'PT409');await closed(orphan);
 // Cover HMAC v4 for the existing stop-only wire without enabling history.
 await pg.raw('update taskfold_private.audio_comment_config set project_private_history_enabled=false,project_unfinished_transfer_enabled=true');
 const combined=await project(),combinedTask=await task(combined),combinedIntent=intent(combinedTask);await reserve(combinedIntent);const combinedRoute=await route(combined),combinedPrepared=await prepare(scope(combined),stop,true);
 const combinedReceipt=await rpc('adopt',combinedPrepared.command);check('connection pause and pending-only stop commit together',[combinedReceipt.applied,combinedReceipt.recording_count,combinedReceipt.unfinished_recording_count],[true,0,1]);
 check('old stop wire does not grow a private history count','retained_recording_count' in combinedReceipt,false);
 check('combined stop route pauses',await pg.scalar(`select to_jsonb(state) from taskfold_private.email_routes where id=${lit(combinedRoute)}`),'paused');
 check('combined stop exact receipt replays',await rpc('adopt',combinedPrepared.command),{...combinedReceipt,replayed:true});
 check('combined stopped send is also permanently private',await pg.scalar(`select to_jsonb(exists(select 1 from taskfold_private.audio_project_private_history where operation_id=${lit(combinedIntent.operation_id)}))`),true);
 for(const role of ['anon','authenticated','service_role']) {check('history table stays private '+role,await pg.scalar(`select to_jsonb(has_table_privilege(${lit(role)},'taskfold_private.audio_project_private_history','select'))`),false);for(const fn of ['guard_private_audio_history()','project_private_history_transfer_supported(jsonb)'])check('history helper stays private '+role+' '+fn,await pg.scalar(`select to_jsonb(has_function_privilege(${lit(role)},${lit('taskfold_private.'+fn)},'execute'))`),false)}
 return {syntheticOnly:true,account:owner.id,origin:'https://synthetic.example',...prepared,receipt,replayed:{...receipt,replayed:true},removedOnly:{...onlyPrepared,receipt:onlyReceipt},combinedUnfinished:{...combinedPrepared,receipt:combinedReceipt}};
}
