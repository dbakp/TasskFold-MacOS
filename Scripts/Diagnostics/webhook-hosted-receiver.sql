-- Disposable preview fixture only. Never deploy on main.
create schema taskfold_webhook_acceptance;
revoke all on schema taskfold_webhook_acceptance from public,anon,authenticated,service_role;
create table taskfold_webhook_acceptance.messages(subscription uuid not null,message uuid not null,body text not null check(octet_length(body)<=262144),attempts integer not null default 1,route text not null,headers_safe boolean not null,received_at timestamptz not null default clock_timestamp(),primary key(subscription,message));
alter table taskfold_webhook_acceptance.messages enable row level security;
revoke all on taskfold_webhook_acceptance.messages from public,anon,authenticated,service_role;
create function taskfold_webhook_acceptance.record(_subscription uuid,_message uuid,_body text,_route text,_safe boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare old taskfold_webhook_acceptance.messages;n int;inserted int;
begin
 if _route not in('receive','retry','refuse','gone') or not _safe then raise exception 'Invalid synthetic delivery';end if;
 insert into taskfold_webhook_acceptance.messages(subscription,message,body,route,headers_safe) values(_subscription,_message,_body,_route,_safe) on conflict do nothing;get diagnostics inserted=row_count;
 select * into old from taskfold_webhook_acceptance.messages where subscription=_subscription and message=_message for update;
 if old.body<>_body or old.route<>_route then raise exception 'Immutable delivery changed';end if;
 -- The first insert already records its first attempt.
 if inserted=0 then update taskfold_webhook_acceptance.messages set attempts=attempts+1 where subscription=_subscription and message=_message returning attempts into n;else n=old.attempts;end if;
 return jsonb_build_object('attempts',n);
end$$;

revoke all on function taskfold_webhook_acceptance.record(uuid,uuid,text,text,boolean) from public,anon,authenticated,service_role;
create function public.taskfold_webhook_acceptance_record(_subscription uuid,_message uuid,_body text,_route text,_safe boolean) returns jsonb language sql security invoker set search_path='' as $$select taskfold_webhook_acceptance.record(_subscription,_message,_body,_route,_safe)$$;
grant usage on schema taskfold_webhook_acceptance to service_role;
grant execute on function taskfold_webhook_acceptance.record(uuid,uuid,text,text,boolean) to service_role;
revoke all on function public.taskfold_webhook_acceptance_record(uuid,uuid,text,text,boolean) from public,anon,authenticated;
grant execute on function public.taskfold_webhook_acceptance_record(uuid,uuid,text,text,boolean) to service_role;
create function taskfold_webhook_acceptance.inspect(_subscription uuid) returns jsonb language sql security definer set search_path='' as $$select coalesce(jsonb_agg(to_jsonb(x) order by x.received_at,x.message),'[]') from (select * from taskfold_webhook_acceptance.messages where subscription=_subscription order by received_at,message limit 100)x$$;
revoke all on function taskfold_webhook_acceptance.inspect(uuid) from public,anon,authenticated;
grant execute on function taskfold_webhook_acceptance.inspect(uuid) to service_role;
create function public.taskfold_webhook_acceptance_inspect(_subscription uuid) returns jsonb language sql security invoker set search_path='' as $$select taskfold_webhook_acceptance.inspect(_subscription)$$;
revoke all on function public.taskfold_webhook_acceptance_inspect(uuid) from public,anon,authenticated;
grant execute on function public.taskfold_webhook_acceptance_inspect(uuid) to service_role;
