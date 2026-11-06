-- Synthetic actual-role checks. Every account/project/template is rolled back.
begin;
insert into auth.users(id,email) values
 ('f0742000-0000-4000-8000-000000000001','taskfold-workflow-owner@example.invalid'),
 ('f0742000-0000-4000-8000-000000000002','taskfold-workflow-member@example.invalid'),
 ('f0742000-0000-4000-8000-000000000003','taskfold-workflow-outsider@example.invalid');
set local request.jwt.claim.sub='f0742000-0000-4000-8000-000000000001';
set local role authenticated;
insert into public.projects(id,name) values('f0742000-0000-4000-8000-000000000011','Parent');
insert into public.projects(id,name,parent_id) values
 ('f0742000-0000-4000-8000-000000000012','Child','f0742000-0000-4000-8000-000000000011'),
 ('f0742000-0000-4000-8000-000000000013','Separate',null);
insert into public.projects(id,name,parent_id,is_archived) values('f0742000-0000-4000-8000-000000000014','Explicit archive','f0742000-0000-4000-8000-000000000011',true);
do $$ begin
 begin update public.projects set parent_id='f0742000-0000-4000-8000-000000000012' where id='f0742000-0000-4000-8000-000000000011'; raise exception 'Cycle was accepted';
 exception when others then if sqlerrm<>'A project cannot be placed inside itself or one of its subprojects.' then raise; end if; end;
 update public.projects set is_archived=true where id='f0742000-0000-4000-8000-000000000011';
 if not (select ancestor_archived from public.projects where id='f0742000-0000-4000-8000-000000000012') then raise exception 'Archive did not reach child'; end if;
 update public.projects set is_archived=false where id='f0742000-0000-4000-8000-000000000011';
 if (select ancestor_archived from public.projects where id='f0742000-0000-4000-8000-000000000012') or not (select is_archived from public.projects where id='f0742000-0000-4000-8000-000000000014') then raise exception 'Restore erased explicit archive'; end if;
 insert into public.project_templates(id,name,document) values('f0742000-0000-4000-8000-000000000021','Reusable workflow','{"version":1,"kind":"project","projects":[],"sections":[],"tasks":[]}');
end $$;
insert into public.project_collaborators(project_id,invited_email,invited_by) values
 ('f0742000-0000-4000-8000-000000000012','taskfold-workflow-member@example.invalid','f0742000-0000-4000-8000-000000000001');
set local request.jwt.claim.sub='f0742000-0000-4000-8000-000000000002';
update public.project_collaborators set status='accepted' where project_id='f0742000-0000-4000-8000-000000000012' and user_id=auth.uid();
set local request.jwt.claim.sub='f0742000-0000-4000-8000-000000000001';
update public.projects set is_archived=true where id='f0742000-0000-4000-8000-000000000011';
set local request.jwt.claim.sub='f0742000-0000-4000-8000-000000000002';
do $$ begin
 if exists(select 1 from public.projects where id='f0742000-0000-4000-8000-000000000011') then raise exception 'Parent permissions leaked'; end if;
 if not (select ancestor_archived from public.projects where id='f0742000-0000-4000-8000-000000000012') then raise exception 'Hidden ancestor archive not projected'; end if;
 update public.projects set name='Member rename' where id='f0742000-0000-4000-8000-000000000012';
 begin update public.projects set is_archived=true where id='f0742000-0000-4000-8000-000000000012'; raise exception 'Member archive accepted'; exception when insufficient_privilege then null; end;
 if exists(select 1 from public.project_templates) then raise exception 'Private template leaked to member'; end if;
 begin insert into public.project_templates(user_id,name,document) values('f0742000-0000-4000-8000-000000000001','Foreign','{"version":1}'); raise exception 'Foreign template inserted'; exception when insufficient_privilege then null; end;
 insert into public.projects(id,name) values('f0742000-0000-4000-8000-000000000015','Member own');
 begin update public.projects set parent_id='f0742000-0000-4000-8000-000000000012' where id='f0742000-0000-4000-8000-000000000015'; raise exception 'Cross-owner parent accepted'; exception when others then if sqlerrm<>'Choose an available parent project that you own.' then raise; end if; end;
end $$;
set local request.jwt.claim.sub='f0742000-0000-4000-8000-000000000003';
do $$ begin
 if exists(select 1 from public.project_templates) then raise exception 'Template leaked to outsider'; end if;
 if exists(select 1 from public.projects where id='f0742000-0000-4000-8000-000000000011') then raise exception 'Project leaked to outsider'; end if;
end $$;
set local request.jwt.claim.sub='f0742000-0000-4000-8000-000000000001';
delete from public.projects where id='f0742000-0000-4000-8000-000000000011';
do $$ begin
 if (select parent_id is not null or ancestor_archived from public.projects where id='f0742000-0000-4000-8000-000000000012') then raise exception 'Deleting parent did not promote child'; end if;
 if not (select is_archived from public.projects where id='f0742000-0000-4000-8000-000000000014') then raise exception 'Parent deletion reset explicit archive'; end if;
end $$;
-- Twenty levels are allowed; a twenty-first level and subtree overflow fail.
do $$ declare parent uuid; next_id uuid; i integer; begin
 for i in 1..20 loop
  next_id := ('f0742000-2222-4222-8222-'||lpad(i::text,12,'0'))::uuid;
  insert into public.projects(id,name,parent_id) values(next_id,'Depth '||i,parent);
  parent := next_id;
 end loop;
 begin
  insert into public.projects(id,name,parent_id) values('f0742000-2222-4222-8222-000000000021','Too deep',parent);
  raise exception 'Depth overflow accepted';
 exception when others then if sqlerrm<>'Projects can be nested up to 20 levels.' then raise; end if; end;
 begin
  update public.projects set parent_id=parent where id='f0742000-0000-4000-8000-000000000012';
  raise exception 'Subtree overflow accepted';
 exception when others then if sqlerrm<>'Projects can be nested up to 20 levels.' then raise; end if; end;
 -- Opaque future definitions are retained, but malformed versions are rejected.
 update public.project_templates set document='{"version":2,"future":"retained"}',name='Updated workflow' where id='f0742000-0000-4000-8000-000000000021';
 if not exists(select 1 from public.project_templates where name='Updated workflow' and document->>'future'='retained') then raise exception 'Owner template update lost'; end if;
 begin insert into public.project_templates(name,document) values('Invalid','{"version":-1}'); raise exception 'Invalid version accepted'; exception when check_violation then null; end;
 delete from public.project_templates where id='f0742000-0000-4000-8000-000000000021';
 if exists(select 1 from public.project_templates) then raise exception 'Owner template delete failed'; end if;
end $$;
reset role;
rollback;
