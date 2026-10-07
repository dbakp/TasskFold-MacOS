-- Availability is a bounded owner/session-checked RPC. Private rollout and pilot
-- rows do not need table-level authenticated access or GraphQL discovery.
revoke select on taskfold_private.reminder_authority_rollout from authenticated;
revoke select on taskfold_private.reminder_authority_pilots from authenticated;
create function taskfold_private.reminder_delivery_available()
returns boolean language plpgsql stable security definer set search_path='' as $$
declare owner uuid:=auth.uid(); live_session uuid;
begin
 if owner is null then return false; end if;
 begin live_session:=nullif(auth.jwt()->>'session_id','')::uuid;
 exception when invalid_text_representation then return false;
 end;
 if live_session is null or not exists(select 1 from auth.sessions where id=live_session and user_id=owner) then return false; end if;
 return exists(select 1 from taskfold_private.reminder_authority_rollout where singleton and enabled)
  or exists(select 1 from taskfold_private.reminder_authority_pilots where user_id=owner and expires_at>now());
end $$;
revoke all on function taskfold_private.reminder_delivery_available() from public,anon;
grant execute on function taskfold_private.reminder_delivery_available() to authenticated;
create or replace function public.taskfold_reminder_delivery_available()
returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('version',1,'account',auth.uid(),'available',taskfold_private.reminder_delivery_available())
$$;
revoke all on function public.taskfold_reminder_delivery_available() from public,anon;
grant execute on function public.taskfold_reminder_delivery_available() to authenticated;
