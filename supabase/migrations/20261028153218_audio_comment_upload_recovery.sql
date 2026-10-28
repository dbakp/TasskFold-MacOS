-- Recover a retired upload only after complete stored-byte evidence. Absence is
-- never terminal evidence; unresolved attempts remain fenced and quota-counted.
alter table taskfold_private.audio_upload_attempts add column next_probe_at timestamptz not null default clock_timestamp();
create index audio_upload_probe on taskfold_private.audio_upload_attempts(next_probe_at,started_at,ticket_id) where state='open';
alter function taskfold_private.audio_maintenance(text,jsonb) rename to audio_maintenance_fenced_v3;
revoke all on function taskfold_private.audio_maintenance_fenced_v3(text,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.audio_maintenance(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare r taskfold_private.audio_comment_publications;u taskfold_private.audio_upload_attempts;asset storage.objects;op uuid;ticket uuid;items jsonb:='[]';begin
 if action='probe' then
  perform taskfold_private.audio_fields(b,array[]::text[]);
  for u in select a.* from taskfold_private.audio_upload_attempts a join taskfold_private.audio_comment_publications p using(operation_id)
   where a.state='open' and p.state='retired' and a.next_probe_at<=clock_timestamp()
   order by a.next_probe_at,a.started_at,a.ticket_id limit 25 for update of a skip locked loop
   select * into r from taskfold_private.audio_comment_publications where operation_id=u.operation_id;
   update taskfold_private.audio_upload_attempts set next_probe_at=clock_timestamp()+interval '2 minutes' where ticket_id=u.ticket_id;
   items=items||jsonb_build_array(jsonb_build_object('operation_id',r.operation_id,'asset_id',r.asset_id,'bucket','taskfold-audio-v1','object_name',r.object_name,'ticket_id',u.ticket_id,'sha256',r.sha256,'byte_count',r.byte_count));
  end loop;
  return jsonb_build_object('protocol',1,'items',items);
 elsif action='reconcile' then
  perform taskfold_private.audio_fields(b,array['operation_id','asset_id','object_name','ticket_id','stored_sha256','stored_bytes']);
  op=taskfold_private.audio_uuid(b,'operation_id');ticket=taskfold_private.audio_uuid(b,'ticket_id');
  select * into r from taskfold_private.audio_comment_publications where operation_id=op for update;
  if not found or r.state<>'retired' or r.asset_id is distinct from taskfold_private.audio_uuid(b,'asset_id') or r.object_name is distinct from b->>'object_name'
   or b->'stored_sha256' is distinct from to_jsonb(r.sha256) or b->'stored_bytes' is distinct from to_jsonb(r.byte_count)
   or not taskfold_private.audio_bucket_ready() then return jsonb_build_object('protocol',1,'settled',false);end if;
  select * into u from taskfold_private.audio_upload_attempts where ticket_id=ticket and operation_id=op for update;
  if not found or u.state<>'open' then return jsonb_build_object('protocol',1,'settled',false);end if;
  select * into asset from storage.objects where bucket_id='taskfold-audio-v1' and name=r.object_name for share;
  if not found or coalesce(to_jsonb(asset)->>'owner_id',to_jsonb(asset)->>'owner') is not null
   or asset.metadata->'size' is distinct from to_jsonb(r.byte_count) or asset.metadata->'mimetype' is distinct from '"audio/mp4"'::jsonb then return jsonb_build_object('protocol',1,'settled',false);end if;
  -- Exactly one open upload exists and no retired operation can start another.
  -- Its correctly hashed committed object proves that upload reached Storage.
  update taskfold_private.audio_upload_attempts set state='settled',settled_at=clock_timestamp() where ticket_id=ticket;
  return jsonb_build_object('protocol',1,'settled',true);
 end if;
 return taskfold_private.audio_maintenance_fenced_v3(action,b);
end$$;
revoke all on function taskfold_private.audio_maintenance(text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_maintenance(text,jsonb) to service_role;
create or replace function public.taskfold_audio_comment_maintenance(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_maintenance(_action,_body)$$;
revoke all on function public.taskfold_audio_comment_maintenance(text,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_maintenance(text,jsonb) to service_role;
