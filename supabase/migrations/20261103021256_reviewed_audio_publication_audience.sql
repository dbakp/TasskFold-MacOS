-- Undeployed candidate. Existing immutable sender intents/receipts remain v1.
-- Publication approval is separate, audience-bound authority, never read access.
alter table taskfold_private.audio_comment_config add column audience_review_enabled boolean not null default false;
create table taskfold_private.audio_publication_audiences (
 operation_id uuid primary key references taskfold_private.audio_comment_publications(operation_id) on delete cascade,
 audience_hash text not null check(audience_hash ~ '^[0-9a-f]{64}$')
);
alter table taskfold_private.audio_publication_audiences enable row level security;
revoke all on taskfold_private.audio_publication_audiences from public,anon,authenticated,service_role;

create function taskfold_private.audio_publication_audience(a uuid,intent jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare t uuid;g uuid;p uuid;team uuid;scope jsonb;snapshot jsonb;visibility text;begin
 perform taskfold_private.audio_intent(intent);
 if intent->'account' is distinct from to_jsonb(a) then return null;end if;
 t:=taskfold_private.audio_uuid(intent->'target','task_id');g:=taskfold_private.audio_uuid(intent->'target','task_generation');p:=taskfold_private.audio_uuid(intent->'target','project_id',true);
 -- Match coordinator ordering. Row locks fence FK inserts as well as updates;
 -- no global table lock or client-provided realm/recipient assertion is trusted.
 perform pg_advisory_xact_lock(hashtextextended('audio-account:'||a::text,20261028));
 perform pg_advisory_xact_lock(hashtextextended('audio-task:'||t::text,20261028));
 perform 1 from public.tasks where id=t and task_generation=g and project_id is not distinct from p for share;
 if not found then return null;end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=p;
 if team is not null then
  perform 1 from taskfold_private.teams where id=team for update;
 end if;
 if p is not null then perform 1 from public.projects where id=p for update;if not found then return null;end if;end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=p;
 if team is not null then perform 1 from taskfold_private.teams where id=team for update;end if;
 if team is null then
  perform 1 from public.project_collaborators c where c.project_id=p order by c.id for share;
 else
  perform 1 from taskfold_private.team_content_projects b where b.project_id=p for update;
  perform 1 from taskfold_private.team_members m where m.team_id=team order by m.user_id for share;
  perform 1 from taskfold_private.team_project_grants r where r.project_id=p order by r.user_id for share;
 end if;
 if not coalesce(taskfold_private.audio_scope(a,t,g,p,true),false) then return null;end if;
 -- Re-read the realm only after source locks; a waiting old personal intent
 -- cannot inherit approval from the post-adoption team context.
 select team_id,b.visibility into team,visibility from taskfold_private.team_content_projects b where project_id=p;
 scope:=jsonb_build_object('kind',case when team is null then 'personal' else 'team' end,'team_id',team,'visibility',coalesce(visibility,'personal'));
 if team is null then
  snapshot:=jsonb_build_array(scope,(select user_id from public.tasks where id=t),(select user_id from public.projects where id=p),
   coalesce((select jsonb_agg(to_jsonb(c) order by c.id) from public.project_collaborators c where project_id=p),'[]'));
 else
  snapshot:=jsonb_build_array(scope,(select to_jsonb(b) from taskfold_private.team_content_projects b where project_id=p),
   (select jsonb_build_array(x.id,x.owner_id,x.state,x.revision) from taskfold_private.teams x where id=team),
   coalesce((select jsonb_agg(to_jsonb(m) order by m.user_id) from taskfold_private.team_members m where team_id=team),'[]'),
   coalesce((select jsonb_agg(to_jsonb(r) order by r.user_id) from taskfold_private.team_project_grants r where project_id=p),'[]'));
 end if;
 if octet_length(snapshot::text)>8388608 then return null;end if;
 return jsonb_build_object('audience',scope,'hash',encode(extensions.digest(convert_to(snapshot::text,'UTF8'),'sha256'),'hex'));
end$$;
revoke all on function taskfold_private.audio_publication_audience(uuid,jsonb) from public,anon,authenticated,service_role;

create function taskfold_private.audio_publication_approval(a uuid,intent jsonb,scope jsonb,expires text) returns text
language sql stable security definer set search_path='' as $$
 select encode(extensions.hmac(convert_to(jsonb_build_array('audio_publication_audience_v1',a,intent,scope,expires)::text,'UTF8'),s.secret,'sha256'),'hex')
 from taskfold_private.automation_revision_secret s where singleton
$$;
revoke all on function taskfold_private.audio_publication_approval(uuid,jsonb,jsonb,text) from public,anon,authenticated,service_role;

alter function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) rename to audio_comment_before_audience_review;
revoke all on function taskfold_private.audio_comment_before_audience_review(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.audio_comment_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare intent jsonb;approval jsonb;scope jsonb;expires text;stamp timestamptz;op uuid;x taskfold_private.audio_comment_publications;result jsonb;bound text;begin
 if action not in('review_publication','reserve_approved','finalize_approved','reserve','finalize','upload_begin') or action is null then
  return taskfold_private.audio_comment_before_audience_review(action,a,s,b);end if;
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
 if action='upload_begin' then
  op:=taskfold_private.audio_uuid(b,'operation_id');select * into x from taskfold_private.audio_comment_publications where operation_id=op;
  if x.author_id is distinct from a then return jsonb_build_object('status','unavailable');end if;
  intent:=jsonb_build_object('version',1,'account',a,'operation_id',x.operation_id,'comment_id',x.comment_id,'asset_id',x.asset_id,'target',jsonb_build_object('task_id',x.task_id,'task_generation',x.task_generation,'project_id',x.project_id),'caption',x.caption,'audio',x.audio_descriptor);
 else
  if action='reserve' then intent:=b;
  elsif action='reserve_approved' then perform taskfold_private.audio_fields(b,array['intent','approval']);intent:=b->'intent';approval:=b->'approval';
  elsif action='finalize_approved' then perform taskfold_private.audio_fields(b,array['intent','approval','stored_sha256','stored_bytes']);intent:=b->'intent';approval:=b->'approval';
  elsif action='review_publication' then perform taskfold_private.audio_fields(b,array['intent']);intent:=b->'intent';
  else perform taskfold_private.audio_fields(b,array['intent','stored_sha256','stored_bytes']);intent:=b->'intent';end if;
  perform taskfold_private.audio_intent(intent);op:=taskfold_private.audio_uuid(intent,'operation_id');
  if intent->'account' is distinct from to_jsonb(a) then return jsonb_build_object('status','unavailable');end if;
  select * into x from taskfold_private.audio_comment_publications where operation_id=op;
 end if;
 -- Original terminal identities recover via the unchanged exact-hash ledger,
 -- even after review expiry/disablement. No new upload can result from this.
 if x.operation_id is not null and x.state in('published','retired','purged') and action<>'review_publication' then
  if action='upload_begin' then return jsonb_build_object('status','conflict');end if;
  return taskfold_private.audio_comment_before_audience_review(case when action='reserve_approved' then 'reserve' when action='finalize_approved' then 'finalize' else action end,a,s,case when action='reserve_approved' then intent when action='finalize_approved' then b-'approval' else b end);
 end if;
 if not coalesce((select enabled and audience_review_enabled from taskfold_private.audio_comment_config where singleton),false) then return jsonb_build_object('status','disabled');end if;
 scope:=taskfold_private.audio_publication_audience(a,intent);
 if scope is null then return jsonb_build_object('status','unavailable');end if;
 if action='review_publication' then
  expires:=to_char(clock_timestamp()+interval '10 minutes','YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
  return jsonb_build_object('protocol',1,'account',a,'target',intent->'target','audience',scope->'audience','expires_at',expires,'token',taskfold_private.audio_publication_approval(a,intent,scope,expires));
 end if;
 select audience_hash into bound from taskfold_private.audio_publication_audiences where operation_id=op;
 if action='upload_begin' then
  if bound is distinct from scope->>'hash' then return jsonb_build_object('status','conflict');end if;
  return taskfold_private.audio_comment_before_audience_review(action,a,s,b);
 end if;
 if action in('reserve','finalize') then return jsonb_build_object('status','conflict');end if;
 perform taskfold_private.audio_fields(approval,array['protocol','account','target','audience','expires_at','token']);
 expires:=approval->>'expires_at';
 if approval->'protocol' is distinct from '1'::jsonb or approval->'account' is distinct from to_jsonb(a) or approval->'target' is distinct from intent->'target' or approval->'audience' is distinct from scope->'audience'
  or jsonb_typeof(approval->'token') is distinct from 'string' or (approval->>'token') !~ '^[0-9a-f]{64}$'
  or jsonb_typeof(approval->'expires_at') is distinct from 'string' or length(expires)>40 or expires !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$' then return jsonb_build_object('status','conflict');end if;
 stamp:=expires::timestamptz;
 if stamp<=clock_timestamp() or stamp>clock_timestamp()+interval '11 minutes' or approval->>'token' is distinct from taskfold_private.audio_publication_approval(a,intent,scope,expires)
  or (x.operation_id is not null and bound is distinct from scope->>'hash') then return jsonb_build_object('status','conflict');end if;
 result:=taskfold_private.audio_comment_before_audience_review(case when action='reserve_approved' then 'reserve' else 'finalize' end,a,s,case when action='reserve_approved' then intent else b-'approval' end);
 if result->>'state' in('pending','published') then
  insert into taskfold_private.audio_publication_audiences(operation_id,audience_hash) values(op,scope->>'hash') on conflict(operation_id) do nothing;
 end if;
 return result;
end$$;
revoke all on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) to service_role;
create or replace function public.taskfold_audio_comment_command(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_comment_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) to service_role;
