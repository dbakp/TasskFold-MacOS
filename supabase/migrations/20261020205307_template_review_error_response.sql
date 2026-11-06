-- Use application errors for review responses, matching guarded task edits.
-- Definitions are atomic documents: merge independent names, review overlapping definitions.
create or replace function public.taskfold_edit_template(_id uuid,_base jsonb,_changes jsonb,_delete boolean default false)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare item public.project_templates; current_doc jsonb; field text;
begin
 if auth.uid() is null then raise exception 'Not authorized' using errcode='42501'; end if;
 select * into item from public.project_templates where id=_id and user_id=auth.uid() for update;
 if not found then
  if _delete then return null; end if;
  raise exception 'TASKFOLD_CONFLICT: This template was removed or is unavailable.' using errcode='P0001';
 end if;
 current_doc=to_jsonb(item);
 if jsonb_typeof(_base) is distinct from 'object' or jsonb_typeof(_changes) is distinct from 'object' then raise exception 'Invalid template edit'; end if;
 if _delete then
  if not (_base ? 'name' and _base ? 'document') or _base->'name' is distinct from current_doc->'name' or _base->'document' is distinct from current_doc->'document' then
   raise exception 'TASKFOLD_CONFLICT: Review this template before deleting it.' using errcode='P0001';
  end if;
  delete from public.project_templates where id=_id and user_id=auth.uid();return null;
 end if;
 for field in select jsonb_object_keys(_changes) loop
  if field not in ('name','document') then raise exception 'Unsupported template field'; end if;
  if not (_base ? field) or (current_doc->field is distinct from _base->field and current_doc->field is distinct from _changes->field) then
   raise exception 'TASKFOLD_CONFLICT: Review the overlapping template edit.' using errcode='P0001';
  end if;
 end loop;
 if _changes ? 'name' and (jsonb_typeof(_changes->'name') is distinct from 'string' or length(btrim(_changes->>'name')) not between 1 and 160) then raise exception 'Invalid template name'; end if;
 if _changes ? 'document' and jsonb_typeof(_changes->'document') is distinct from 'object' then raise exception 'Invalid template definition'; end if;
 update public.project_templates set name=case when _changes ? 'name' then btrim(_changes->>'name') else name end,
 document=case when _changes ? 'document' then _changes->'document' else document end where id=_id and user_id=auth.uid() returning * into item;
 return to_jsonb(item);
end $$;
revoke all on function public.taskfold_edit_template(uuid,jsonb,jsonb,boolean) from public,anon;
grant execute on function public.taskfold_edit_template(uuid,jsonb,jsonb,boolean) to authenticated;
