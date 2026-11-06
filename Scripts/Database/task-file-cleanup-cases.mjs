import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
export async function run({pg,lit,json,service,seed,intent,object,path,check,users,report}){
 const raw=async(action,body)=>{const result=await pg.value(`public.taskfold_task_file_maintenance(${lit(action)},${json(body)})`);assert.ok(!result.code,JSON.stringify(result));return result.value;};
 await pg.raw("update taskfold_private.task_file_uploads set created_at=clock_timestamp()-interval '2 minutes'");
 const reserve=async()=>{const i=intent(await seed());assert.equal((await service('reserve',i)).status,'reserved');return i;};
 const stop=i=>service('cancel',{operation_id:i.operation_id});
 const begin=i=>service('upload_begin',{operation_id:i.operation_id});
 const settle=(i,ticket)=>service('upload_settle',{operation_id:i.operation_id,ticket_id:ticket});
 const reconcile=(i,ticket,extra={})=>raw('reconcile',{operation_id:i.operation_id,ticket_id:ticket,stored_sha256:i.sha256,stored_bytes:i.byte_count,...extra});
 const clean=i=>pg.scalar(`select to_jsonb(provider_cleanup_confirmed_at is not null) from taskfold_private.task_file_uploads where operation_id=${lit(i.operation_id)}`);
 const i=await reserve(),ticket=(await begin(i)).ticket_id;
 check('one write ticket per operation',(await begin(i)).ticket_id,ticket);check('retry never admits another POST',(await begin(i)).status,'upload_unresolved');
 await stop(i);check('closed operation admits no new writes',(await begin(i)).status,'cancelled');
 check('absence never settles an open writer',(await reconcile(i,ticket)).settled,false);
 check('open writer cannot be claimed',(await raw('claim',{})).items.some(x=>x.operation_id===i.operation_id),false);
 // A synthetic provider commit occurs after Stop. Only its complete verified
 // descriptor can settle the admitted write; elapsed time/404 cannot.
 const late=await object(i);check('wrong full-byte proof cannot settle',(await reconcile(i,ticket,{stored_sha256:'f'.repeat(64)})).settled,false);
 check('committed bytes reconcile the sole late writer',(await reconcile(i,ticket)).settled,true);
 const claims=(await raw('claim',{})).items,c=claims.find(x=>x.operation_id===i.operation_id);check('settled closed writer receives cleanup claim',!!c);
 const confirm=(claim,extra={})=>raw('confirm',{operation_id:claim.operation_id,object_name:claim.object_name,token:claim.token,...extra});
 check('metadata presence blocks quota release',(await confirm(c)).purged,false);check('failed confirmation retains quota',await clean(i),false);
 await pg.raw(`delete from storage.objects where id=${lit(late)}`);
 check('foreign token cannot release quota',(await confirm(c,{token:randomUUID()})).purged,false);
 await pg.raw(`update taskfold_private.task_file_cleanup_claims set expires_at=now()-interval '1 second' where operation_id=${lit(i.operation_id)}`);
 check('expired claim cannot release quota',(await confirm(c)).purged,false);
 const renewed=(await raw('claim',{})).items.find(x=>x.operation_id===i.operation_id);check('expired claim rotates token',renewed.token!==c.token);
 check('old worker cannot confirm renewed claim',(await confirm(c)).purged,false);
 check('fresh claim and provider absence release quota',(await confirm(renewed)).purged,true);check('confirmed cleanup is durable',await clean(i));
 check('lost confirmation reply replays exact durable receipt',(await confirm(renewed)).purged,true);
 check('purged receipt rejects another token',(await confirm(renewed,{token:randomUUID()})).purged,false);
 check('confirmed cleanup is not claimed twice',(await raw('claim',{})).items.some(x=>x.operation_id===i.operation_id),false);
 const orphan=await reserve();await stop(orphan);const orphanID=await object(orphan);
 check('unexpected zero-ticket object is quarantined',(await raw('claim',{})).items.some(x=>x.operation_id===orphan.operation_id),false);
 const empty=await reserve();await stop(empty);check('never-started closed allocation can be claimed',(await raw('claim',{})).items.some(x=>x.operation_id===empty.operation_id));
 const unacked=await reserve(),unackedTicket=(await begin(unacked)).ticket_id;await stop(unacked);
 check('closed unresolved write is probed',(await raw('probe',{})).items.some(x=>x.operation_id===unacked.operation_id));
 check('probe backoff bounds repeated work',(await raw('probe',{})).items.some(x=>x.operation_id===unacked.operation_id),false);
 check('foreign ticket cannot settle writer',(await settle(unacked,randomUUID())).settled,false);
 check('late explicit transport acknowledgement can settle after Stop',(await settle(unacked,unackedTicket)).settled,true);
 check('late acknowledgement is idempotent',(await settle(unacked,unackedTicket)).settled,true);
 const stored=await reserve();await object(stored);check('existing committed object permits verify only',(await begin(stored)).status,'verify');
 await stop(stored);
 const legacy=await reserve();await pg.raw(`update taskfold_private.task_file_uploads set writer_protocol=0,object_nonce=null,object_name='team-task-files/v1/'||operation_id::text where operation_id=${lit(legacy.operation_id)}`);
 check('legacy row cannot silently adopt new writer proof',(await service('reserve',legacy)).status,'legacy_unverified');await stop(legacy);
 check('legacy allocation is not automatically reclaimed',(await raw('claim',{})).items.some(x=>x.operation_id===legacy.operation_id),false);
 const u=users.owner;check('old gateway cannot admit unleased upload',(await pg.scalar(`select public.taskfold_task_file_command('reserve',${lit(u.id)},${lit(u.session)},${json(intent(await seed()))})`)).status,'writer_update_required');
 for(const role of ['anon','authenticated']){
  check(role+' cannot call cleanup service',await pg.scalar(`select to_jsonb(not has_function_privilege('${role}','public.taskfold_task_file_maintenance(text,jsonb)','EXECUTE'))`));
  check(role+' cannot write upload tickets',await pg.scalar(`select to_jsonb(not has_table_privilege('${role}','taskfold_private.task_file_write_attempts','INSERT'))`));
 }
 check('service cannot bypass writer wrapper',await pg.scalar("select to_jsonb(not has_function_privilege('service_role','taskfold_private.task_file_sender_command_v2(text,uuid,uuid,jsonb)','EXECUTE'))"));
 report.cleanupScope={providerBytesTested:false,claim:c,confirmation:renewed};
 // Restore fixture accounting for the inherited exact-allocation quota case.
 await pg.raw('update taskfold_private.task_file_uploads set provider_cleanup_confirmed_at=null');
 void orphanID;
}
