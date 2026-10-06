-- Qualify JSON elements independently of the signature framing variable.
create or replace function taskfold_private.reminder_events_window(t jsonb,device_zone text,_from timestamptz,_until timestamptz)
returns table(spec_id uuid,fire_at timestamptz,signature text) language plpgsql stable security invoker set search_path='' as $$
declare specs jsonb:=coalesce(t->'reminder_specs','[]'); s jsonb; legacy jsonb:='[]'; seen uuid[]:='{}'; sid uuid; r jsonb; days text; numeric_fields text; fields text[]; preimage text; v text; instant timestamptz; cycle numeric; generation text;
begin
 if not isfinite(_from) or not isfinite(_until) or _until<_from or _until-_from>interval '8 days' or t->>'completed'='true' or jsonb_typeof(specs) is distinct from 'array' then return; end if;
 if nullif(t->'task_generation','null'::jsonb) is not null and (jsonb_typeof(t->'task_generation')<>'string' or coalesce(t->>'task_generation','') !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') then return; end if;
 generation:=lower(coalesce(t->>'task_generation','')); if generation<>'' and generation !~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then return; end if;
 begin cycle:=coalesce((t->>'completion_version')::numeric,0); exception when others then return; end;
 if cycle<>trunc(cycle) or cycle not between 0 and 9007199254740991 then return; end if;
 if specs='[]'::jsonb then return query select e.* from taskfold_private.reminder_events(t,device_zone) e where e.fire_at between _from and _until; return; end if;
 for s in select value from jsonb_array_elements(specs) with ordinality where ordinality<=20 loop
  if not taskfold_private.reminder_spec_valid(s) then continue; end if;
  sid:=(s->>'id')::uuid; if sid=any(seen) then continue; end if; seen:=array_append(seen,sid);
  if s->'version'='1'::jsonb then legacy:=legacy||jsonb_build_array(s); continue; end if;
  if s->>'enabled'='false' then continue; end if;
  r:=s->'recurrence';
  select coalesce(string_agg(d::text,',' order by d),'') into days from (select distinct element.value::text::numeric::int d from jsonb_array_elements(coalesce(nullif(r->'daysOfWeek','null'::jsonb),'[]')) as element(value)) f;
  select string_agg(coalesce(nullif(r->name,'null'::jsonb)::text::numeric::int::text,''),',' order by position) into numeric_fields
   from unnest(array['dayOfMonth','monthOfYear','weekday','weekdayOrdinal','count']) with ordinality f(name,position);
  fields:=array['taskfold.reminder.v5',lower(t->>'id'),sid::text,s->>'start_day',s->>'time',s->>'time_zone',r->>'type',coalesce(nullif(r->'interval','null'::jsonb)::text::numeric::int,1)::text,days,numeric_fields,coalesce(r->>'endDate',''),'local','1'];
  preimage:=''; foreach v in array fields loop preimage:=preimage||octet_length(v)::text||':'||v; end loop;
  for instant in select * from taskfold_private.reminder_calendar_dates(s,_from-interval '1 microsecond',_until) loop
   fields:=array[round(extract(epoch from instant)*1000)::bigint::text,cycle::bigint::text,generation]; v:='';
   foreach days in array fields loop v:=v||octet_length(days)::text||':'||days; end loop;
   spec_id:=sid; fire_at:=instant; signature:='r5:'||encode(extensions.digest(preimage||v,'sha256'),'hex'); return next;
  end loop;
 end loop;
 if legacy<>'[]'::jsonb then return query select e.* from taskfold_private.reminder_events(t||jsonb_build_object('reminder_specs',legacy),device_zone) e where e.fire_at between _from and _until; end if;
end $$;

