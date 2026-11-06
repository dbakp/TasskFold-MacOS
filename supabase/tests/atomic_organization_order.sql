begin;
do $$ begin
 if exists(select 1 from auth.users where id::text like 'f0741100-%') then raise exception 'Order fixture namespace already in use'; end if;
 if has_function_privilege('anon','public.taskfold_order_organization(text,text[],text,uuid)','EXECUTE') then raise exception 'Anonymous ordering RPC grant'; end if;
end $$;
insert into auth.users(id,email) values('f0741100-0000-4000-8000-000000000001','taskfold-order@example.invalid'),('f0741100-0000-4000-8000-000000000002','taskfold-order-other@example.invalid');
set local request.jwt.claim.sub='f0741100-0000-4000-8000-000000000001';
set local role authenticated;
do $$ declare ids text[]:=array['f0741100-0000-4000-8000-000000000011','f0741100-0000-4000-8000-000000000012','f0741100-0000-4000-8000-000000000013']; tbl text; actual text[]; first_action uuid; second_action uuid; result jsonb; begin
 insert into public.projects(id,name,order_index) select id::uuid,'Retained metadata',position::integer-1 from unnest(ids) with ordinality as x(id,position);
 insert into public.sections(id,user_id,project_id,name,order_index) select id::uuid,auth.uid(),ids[1]::uuid,'Retained section',position::integer-1 from unnest(ids) with ordinality as x(id,position);
 insert into public.saved_views(id,name,query_ast,order_index) select id::uuid,'Retained view','{"version":1,"root":{"op":"predicate","field":"planned_on","value":"today"}}',position::integer-1 from unnest(ids) with ordinality as x(id,position);
 insert into public.favorites(id,order_index) select id,position::integer-1 from unnest(ids) with ordinality as x(id,position);
 foreach tbl in array array['projects','sections','saved_views','favorites'] loop
  first_action:=gen_random_uuid(); second_action:=gen_random_uuid();
  result:=public.taskfold_order_organization(tbl,array[ids[2],ids[3],ids[1]],case when tbl='sections' then ids[1] end,first_action);
  result:=public.taskfold_order_organization(tbl,array[ids[1],ids[3],ids[2]],case when tbl='sections' then ids[1] end,second_action);
  -- A late successful-request retry cannot reapply the earlier move.
  result:=public.taskfold_order_organization(tbl,array[ids[2],ids[3],ids[1]],case when tbl='sections' then ids[1] end,first_action);
  execute format('select array_agg(id::text order by order_index,id) from public.%I',tbl) into actual;
  if actual<>array[ids[1],ids[3],ids[2]] then raise exception 'Complete order or late retry failed: %',tbl; end if;
  begin perform public.taskfold_order_organization(tbl,ids,case when tbl='sections' then ids[1] end,first_action); raise exception 'Action identity reuse accepted'; exception when others then if sqlerrm<>'Ordering retry identity was reused for a different move.' then raise; end if; end;
 end loop;
 if (select count(*) from taskfold_private.organization_order_actions)<>8 then raise exception 'Duplicate order receipts'; end if;
 if exists(select 1 from public.projects where name<>'Retained metadata') then raise exception 'Order changed metadata'; end if;
 -- One project's section move returns (and preserves) the other project's sections.
 insert into public.sections(id,user_id,project_id,name,order_index) values('f0741100-0000-4000-8000-000000000014',auth.uid(),ids[2]::uuid,'Other project',9);
 result:=public.taskfold_order_organization('sections',array[ids[3],ids[2]],ids[1],gen_random_uuid());
 if jsonb_array_length(result)<>4 or (select order_index from public.sections where name='Other project')<>9 then raise exception 'Other project section lost'; end if;
 -- A missing/deleted ID is not recreated; a new visible ID is appended.
 delete from public.favorites where id=ids[1]; insert into public.favorites(id) values('new');
 perform public.taskfold_order_organization('favorites',ids,null,gen_random_uuid());
 if (select array_agg(id order by order_index,id) from public.favorites)<>array[ids[2],ids[3],'new'] then raise exception 'Remote additions/removals lost'; end if;
end $$;
set local request.jwt.claim.sub='f0741100-0000-4000-8000-000000000002';
do $$ declare result jsonb; begin
 if exists(select 1 from taskfold_private.organization_order_actions) then raise exception 'Foreign receipts visible'; end if;
 result:=public.taskfold_order_organization('projects',array['f0741100-0000-4000-8000-000000000011'],null,gen_random_uuid());
 if result<>'[]'::jsonb then raise exception 'Foreign project order exposed'; end if;
 begin insert into taskfold_private.organization_order_actions(user_id,action_id,command) values('f0741100-0000-4000-8000-000000000001',gen_random_uuid(),'{}'); raise exception 'Foreign receipt inserted'; exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
 if (select array_agg(id::text order by order_index,id) from public.projects where user_id='f0741100-0000-4000-8000-000000000001')<>array['f0741100-0000-4000-8000-000000000011','f0741100-0000-4000-8000-000000000013','f0741100-0000-4000-8000-000000000012'] then raise exception 'Outsider changed owner ordering'; end if;
end $$;
rollback;
