-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Recovery never implicitly starts a preparation. Cancelling an unacknowledged
-- request closes its exact identity before a late prepare can create any work.
alter function taskfold_private.project_file_preparation_impl(text,uuid,jsonb) rename to project_file_preparation_transfer_v1;
revoke all on function taskfold_private.project_file_preparation_transfer_v1(text,uuid,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.project_file_preparation_impl(action text,a uuid,b jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare p taskfold_private.project_file_preparations;fingerprint text;scope jsonb;begin
 if action not in('resolve','cancel_request') then return taskfold_private.project_file_preparation_transfer_v1(action,a,b);end if;
 if a is distinct from auth.uid() then return jsonb_build_object('status','unavailable');end if;
 perform taskfold_private.project_adoption_fields(b,array['request_id','scope','inspection_token']);
 perform taskfold_private.team_uuid(b,'request_id');
 if jsonb_typeof(b->'inspection_token') is distinct from 'string' or b->>'inspection_token' !~ '^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Use the saved file preparation request';end if;
 scope:=b->'scope';perform taskfold_private.project_adoption_fields(scope,array['team_id','roots','visibility','folder_id','parent_id']);
 perform taskfold_private.team_uuid(scope,'team_id');
 if jsonb_typeof(scope->'roots') is distinct from 'array' or jsonb_array_length(scope->'roots') not between 1 and 100
  or exists(select 1 from jsonb_array_elements(scope->'roots') v where jsonb_typeof(v)<>'string' or v#>>'{}' !~ '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$')
  or jsonb_typeof(scope->'visibility') is distinct from 'string' or scope->'visibility' not in('"private"'::jsonb,'"team"'::jsonb) then raise exception using errcode='22023',message='Use the saved file preparation scope';end if;
 if scope->'folder_id'<>'null'::jsonb then perform taskfold_private.team_uuid(scope,'folder_id');end if;
 if scope->'parent_id'<>'null'::jsonb then perform taskfold_private.team_uuid(scope,'parent_id');end if;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 -- The service wrapper's shared live-actor admission/budget lock serializes
 -- create/cancel of this actor's request, including an absent initial reply.
 select * into p from taskfold_private.project_file_preparations where actor_id=a and request_id=(b->>'request_id')::uuid for update nowait;
 if found then
  if p.fingerprint<>fingerprint then return jsonb_build_object('status','conflict');end if;
  if action='resolve' then return jsonb_build_object('status','plan','plan',taskfold_private.project_file_preparation_reply(p));end if;
  return taskfold_private.project_file_preparation_transfer_v1('cancel',a,jsonb_build_object('plan_id',p.id));
 end if;
 if action='resolve' then return jsonb_build_object('status','absent');end if;
 insert into taskfold_private.project_file_preparations(actor_id,request_id,team_id,scope,inspection_token,fingerprint,state)
 values(a,(b->>'request_id')::uuid,(scope->>'team_id')::uuid,scope,b->>'inspection_token',fingerprint,'cancelled') returning * into p;
 return jsonb_build_object('status','plan','plan',taskfold_private.project_file_preparation_reply(p));
exception when lock_not_available then return jsonb_build_object('status','busy');
end$$;
revoke all on function taskfold_private.project_file_preparation_impl(text,uuid,jsonb) from public,anon,authenticated,service_role;

-- A file policy must not turn a paused project-adoption gate into an enabled
-- client button. Receipt replay still precedes fresh-review/gate checks.
do $$declare d text;anchor text:=' perform 1 from taskfold_private.project_file_preparation_config';begin
 d:=pg_get_functiondef('taskfold_private.review_project_file_policy(jsonb,jsonb,text)'::regprocedure);
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current project-file policy admission required';end if;
 execute replace(d,anchor,' perform 1 from taskfold_private.team_project_config where singleton and native_project_adoption_enabled for share; if not found then raise exception using errcode=''PT503'',message=''Project transfers are paused'';end if;'||chr(10)||anchor);
end$$;
notify pgrst,'reload schema';

-- Native controls appear only for the implemented, enabled recovery protocol.
do $$declare d text;anchor text:=' if operation=''inspect'' then return result;end if;';begin
 d:=pg_get_functiondef('taskfold_private.project_adoption_review(text,jsonb)'::regprocedure);
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current project inspection result required';end if;
 execute replace(d,anchor,$patch$ result:=result||jsonb_build_object('file_preparation',jsonb_build_object('protocol',1,'enabled',
  coalesce((select enabled and transfer_enabled from taskfold_private.project_file_preparation_config where singleton),false)
  and coalesce((select native_project_adoption_enabled from taskfold_private.team_project_config where singleton),false)
  and (contents->'file_custody'->>'stored')::integer>0 and (contents->'file_custody'->>'legacy')::integer=0 and (contents->'file_custody'->>'unavailable')::integer=0));
 if operation='inspect' then return result;end if;$patch$);
end$$;
notify pgrst,'reload schema';

commit;
