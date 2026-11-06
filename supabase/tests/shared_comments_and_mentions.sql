-- Actual-role, synthetic-only, rollback fixture. No emails or notifications are sent.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
 ('f1771000-0000-4000-8000-000000000001','shared-comment-owner@example.invalid','{}'),
 ('f1771000-0000-4000-8000-000000000002','shared-comment-member-a@example.invalid','{}'),
 ('f1771000-0000-4000-8000-000000000003','shared-comment-member-b@example.invalid','{}'),
 ('f1771000-0000-4000-8000-000000000004','shared-comment-outsider@example.invalid','{"user_id":"f1771000-0000-4000-8000-000000000001","role":"owner"}');
set local role authenticated;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000001';
insert into public.projects(id,user_id,name) values
 ('f1772000-0000-4000-8000-000000000001',auth.uid(),'Shared comment fixture'),
 ('f1772000-0000-4000-8000-000000000002',auth.uid(),'Private destination fixture'),
 ('f1772000-0000-4000-8000-000000000003',auth.uid(),'Archived parent fixture');
update public.projects set is_archived=true where id='f1772000-0000-4000-8000-000000000003';
insert into public.projects(id,user_id,name,parent_id) values
 ('f1772000-0000-4000-8000-000000000004',auth.uid(),'Inherited archive fixture','f1772000-0000-4000-8000-000000000003');
insert into public.tasks(id,user_id,title,project_id,comments) values
 ('f1773000-0000-4000-8000-000000000001',auth.uid(),'Shared comment task','f1772000-0000-4000-8000-000000000001','[{"id":"legacy","authorId":"legacy-imported","authorName":"Historical person","text":"Imported @name","attachment":{"opaque":"retained"}}]'),
 ('f1773000-0000-4000-8000-000000000002',auth.uid(),'Archived task','f1772000-0000-4000-8000-000000000004','[]');
select set_config('test.shared_generation',(select task_generation::text from public.tasks where id='f1773000-0000-4000-8000-000000000001'),true);
reset role;
insert into public.project_collaborators(project_id,user_id,invited_email,role,status,invited_by) values
 ('f1772000-0000-4000-8000-000000000001','f1771000-0000-4000-8000-000000000002','shared-comment-member-a@example.invalid','collaborator','pending','f1771000-0000-4000-8000-000000000001'),
 ('f1772000-0000-4000-8000-000000000001','f1771000-0000-4000-8000-000000000003','shared-comment-member-b@example.invalid','collaborator','pending','f1771000-0000-4000-8000-000000000001');
set local role authenticated;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000002';
update public.project_collaborators set status='accepted' where user_id=auth.uid();
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000003';
update public.project_collaborators set status='accepted' where user_id=auth.uid();
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000001';
do $$ declare r jsonb; begin
 r:=public.taskfold_write_comment('f1774000-0000-4000-8000-000000000001','f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Please review. Literal @outsider stays literal.',array['f1771000-0000-4000-8000-000000000003','f1771000-0000-4000-8000-000000000002']::uuid[]);
 if r->>'status' is distinct from 'saved' or r->'current'->>'author_id' is distinct from auth.uid()::text or (r->>'acknowledged_revision')::bigint is distinct from 1 then raise exception 'Authenticated creation failed';end if;
 r:=public.taskfold_write_comment('f1774000-0000-4000-8000-000000000001','f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Please review. Literal @outsider stays literal.',array['f1771000-0000-4000-8000-000000000002','f1771000-0000-4000-8000-000000000003']::uuid[]);
 if r->>'status' is distinct from 'saved' or (select count(*) from public.task_comments) is distinct from 1 then raise exception 'Canonical recipient retry duplicated comment';end if;
 if exists(select 1 from public.task_mentions) then raise exception 'Sender read another account inbox';end if;
 begin
  insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body) values(gen_random_uuid(),'f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001','f1771000-0000-4000-8000-000000000004','Forged');
  raise exception 'Direct author forgery allowed';
 exception when insufficient_privilege then null;end;
 begin update public.task_comments set body='Forged';raise exception 'Direct update allowed';exception when insufficient_privilege then null;end;
 begin delete from public.task_comments;raise exception 'Direct deletion allowed';exception when insufficient_privilege then null;end;
 begin perform 1 from taskfold_private.comment_operations;raise exception 'Private receipt read allowed';exception when insufficient_privilege then null;end;
 begin
  perform public.taskfold_write_comment('f1774000-0000-4000-8000-000000000001','f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Changed payload','{}');
  raise exception 'Operation ID reuse accepted';
 exception when invalid_parameter_value then null;end;
 r:=public.taskfold_write_comment(gen_random_uuid(),gen_random_uuid(),'f1773000-0000-4000-8000-000000000001',gen_random_uuid(),'f1772000-0000-4000-8000-000000000001',0,'Wrong generation','{}');
 if r->>'status' is distinct from 'unavailable' then raise exception 'Wrong generation accepted';end if;
 r:=public.taskfold_write_comment(gen_random_uuid(),gen_random_uuid(),'f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Outsider recipient',array['f1771000-0000-4000-8000-000000000004']::uuid[]);
 if r->>'status' is distinct from 'recipients_changed' or (select count(*) from public.task_comments) is distinct from 1 then raise exception 'Invalid recipient partially wrote comment';end if;
 begin
  perform public.taskfold_write_comment(gen_random_uuid(),gen_random_uuid(),'f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,repeat('😀',4001),'{}');raise exception 'Byte bound bypassed';
 exception when invalid_parameter_value then null;end;
 begin
  perform public.taskfold_write_comment(gen_random_uuid(),gen_random_uuid(),'f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,E' \t\n','{}');raise exception 'Blank comment accepted';
 exception when invalid_parameter_value then null;end;
 r:=public.taskfold_write_comment(gen_random_uuid(),gen_random_uuid(),'f1773000-0000-4000-8000-000000000002',(select task_generation from public.tasks where id='f1773000-0000-4000-8000-000000000002'),'f1772000-0000-4000-8000-000000000004',0,'Inherited archive','{}');
 if r->>'status' is distinct from 'archived' then raise exception 'Inherited archive accepted writes';end if;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000002';
do $$ declare m public.task_mentions;r jsonb;begin
 select * into strict m from public.task_mentions;
 if m.recipient_id is distinct from auth.uid() or m.read_at is not null then raise exception 'Recipient isolation failed';end if;
 perform set_config('test.shared_mention_a',m.id::text,true);
 r:=public.taskfold_mark_mention('f1774000-0000-4000-8000-000000000020',m.id,1,true);
 if r->>'status' is distinct from 'saved' or r->'current'->>'read_at' is null or (r->'current'->>'revision')::bigint is distinct from 2 then raise exception 'Read state failed';end if;
 perform set_config('test.shared_read_at',r->'current'->>'read_at',true);
 r:=public.taskfold_mark_mention('f1774000-0000-4000-8000-000000000021',m.id,2,false);
 if r->'current'->>'read_at' is not null or (r->'current'->>'revision')::bigint is distinct from 3 then raise exception 'Unread state failed';end if;
 r:=public.taskfold_mark_mention('f1774000-0000-4000-8000-000000000020',m.id,1,true);
 if (r->>'acknowledged_revision')::bigint is distinct from 2 or r->'current'->>'read_at' is not null or (r->'current'->>'revision')::bigint is distinct from 3 then raise exception 'Delayed read retry overwrote newer unread';end if;
 r:=public.taskfold_mark_mention(gen_random_uuid(),m.id,1,true);
 if r->>'status' is distinct from 'conflict' then raise exception 'Stale read bypassed revision';end if;
 begin update public.task_mentions set read_at=clock_timestamp();raise exception 'Direct read edit allowed';exception when insufficient_privilege then null;end;
 r:=public.taskfold_write_comment(gen_random_uuid(),'f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',1,'Not my comment','{}');
 if r->>'status' is distinct from 'forbidden' then raise exception 'Member edited another author';end if;
 r:=public.taskfold_write_comment('f1774000-0000-4000-8000-000000000022','f1775000-0000-4000-8000-000000000002','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Member authored reply',array['f1771000-0000-4000-8000-000000000001']::uuid[]);
 if r->'current'->>'author_id' is distinct from auth.uid()::text then raise exception 'Member attribution forged';end if;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000003';
select set_config('test.shared_mention_b',(select id::text from public.task_mentions),true);
do $$ begin
 if (select count(*) from public.task_comments) is distinct from 2 or (select count(*) from public.task_mentions) is distinct from 1 then raise exception 'Second member read wrong scope';end if;
 if public.taskfold_mark_mention(gen_random_uuid(),current_setting('test.shared_mention_a')::uuid,3,true)->>'status' is distinct from 'unavailable' then raise exception 'Cross-recipient callback accepted';end if;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000004';
do $$ begin
 if exists(select 1 from public.task_comments) or exists(select 1 from public.task_mentions) then raise exception 'Outsider read shared content';end if;
 if public.taskfold_write_comment(gen_random_uuid(),gen_random_uuid(),'f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Outsider','{}')->>'status' is distinct from 'unavailable' then raise exception 'Outsider wrote';end if;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000001';
do $$ declare r jsonb;begin
 r:=public.taskfold_write_comment('f1774000-0000-4000-8000-000000000030','f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',1,'Reviewed update',array['f1771000-0000-4000-8000-000000000002','f1771000-0000-4000-8000-000000000003']::uuid[]);
 if r->>'status' is distinct from 'saved' or (r->'current'->>'revision')::bigint is distinct from 2 then raise exception 'Author edit failed';end if;
 r:=public.taskfold_write_comment(gen_random_uuid(),'f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',1,'Stale update','{}');
 if r->>'status' is distinct from 'conflict' or r->'current'->>'body' is distinct from 'Reviewed update' then raise exception 'Stale edit overwrote newer body';end if;
 r:=public.taskfold_write_comment('f1774000-0000-4000-8000-000000000001','f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Please review. Literal @outsider stays literal.',array['f1771000-0000-4000-8000-000000000002','f1771000-0000-4000-8000-000000000003']::uuid[]);
 if (r->>'acknowledged_revision')::bigint is distinct from 1 or r->'current'->>'body' is distinct from 'Reviewed update' then raise exception 'Late add retry reverted edit';end if;
 update public.tasks set project_id='f1772000-0000-4000-8000-000000000002' where id='f1773000-0000-4000-8000-000000000001';
 if exists(select 1 from public.task_comments) then raise exception 'Old conversation followed project move';end if;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000002';
do $$ begin
 if exists(select 1 from public.task_comments) or exists(select 1 from public.task_mentions) then raise exception 'Private move leaked body/inbox';end if;
 if public.taskfold_mark_mention(gen_random_uuid(),current_setting('test.shared_mention_a')::uuid,3,true)->>'status' is distinct from 'unavailable' then raise exception 'Private move callback accepted';end if;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000001';
update public.tasks set project_id='f1772000-0000-4000-8000-000000000001' where id='f1773000-0000-4000-8000-000000000001';
update public.projects set is_archived=true where id='f1772000-0000-4000-8000-000000000001';
do $$ begin
 if (select count(*) from public.task_comments) is distinct from 2 then raise exception 'Archive hid readable conversation';end if;
 if public.taskfold_write_comment(gen_random_uuid(),'f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',2,'Archived edit','{}')->>'status' is distinct from 'archived' then raise exception 'Archived comment edited';end if;
end $$;
update public.projects set is_archived=false where id='f1772000-0000-4000-8000-000000000001';
delete from public.project_collaborators where project_id='f1772000-0000-4000-8000-000000000001' and user_id='f1771000-0000-4000-8000-000000000003';
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000003';
do $$ begin
 if exists(select 1 from public.task_comments) or exists(select 1 from public.task_mentions) then raise exception 'Departed member kept conversation/inbox';end if;
 if public.taskfold_mark_mention(gen_random_uuid(),current_setting('test.shared_mention_b')::uuid,1,true)->>'status' is distinct from 'unavailable' then raise exception 'Departed callback accepted';end if;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000001';
do $$ declare r jsonb;begin
 r:=public.taskfold_write_comment(gen_random_uuid(),'f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',2,'Stale picker','{f1771000-0000-4000-8000-000000000003}');
 if r->>'status' is distinct from 'recipients_changed' or (select revision from public.task_comments where id='f1775000-0000-4000-8000-000000000001') is distinct from 2 then raise exception 'Stale picker partially edited';end if;
 r:=public.taskfold_write_comment(gen_random_uuid(),'f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',2,'Reviewed people','{f1771000-0000-4000-8000-000000000002}');
 if r->>'status' is distinct from 'saved' or (r->'current'->>'revision')::bigint is distinct from 3 then raise exception 'Reviewed people retry failed';end if;
 -- The owner can moderate a reply, but cannot impersonate its author by editing.
 if public.taskfold_write_comment(gen_random_uuid(),'f1775000-0000-4000-8000-000000000002','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',1,'Owner impersonation','{}')->>'status' is distinct from 'forbidden' then raise exception 'Owner edited someone else body';end if;
 r:=public.taskfold_write_comment(gen_random_uuid(),'f1775000-0000-4000-8000-000000000002','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',1,'','{}',true);
 if r->>'status' is distinct from 'saved' or r->'current'->>'body' is distinct from '' or r->'current'->>'deleted_at' is null then raise exception 'Moderation did not clear body';end if;
 if (select count(*) from public.task_mentions) is distinct from 0 then raise exception 'Moderated mention retained in owner inbox';end if;
end $$;
-- Explicit re-mention creates a new unread identity after removal; an old ID cannot act on it.
reset role;
insert into public.project_collaborators(project_id,user_id,invited_email,role,status,invited_by)
 values('f1772000-0000-4000-8000-000000000001','f1771000-0000-4000-8000-000000000003','shared-comment-member-b@example.invalid','collaborator','pending','f1771000-0000-4000-8000-000000000001');
set local role authenticated;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000003';
update public.project_collaborators set status='accepted' where user_id=auth.uid();
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000001';
do $$ declare r jsonb;begin
 r:=public.taskfold_write_comment(gen_random_uuid(),'f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',3,'Mention added again','{f1771000-0000-4000-8000-000000000002,f1771000-0000-4000-8000-000000000003}');
 if r->>'status' is distinct from 'saved' then raise exception 'Re-mention failed';end if;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000003';
do $$ declare m public.task_mentions; r jsonb;begin
 select * into strict m from public.task_mentions;
 if m.id=current_setting('test.shared_mention_b')::uuid or m.read_at is not null or m.revision is distinct from 1 then raise exception 'Re-mention retained obsolete identity/state';end if;
 if public.taskfold_mark_mention(gen_random_uuid(),current_setting('test.shared_mention_b')::uuid,1,true)->>'status' is distinct from 'unavailable' then raise exception 'Old mention callback reached re-mention';end if;
 r:=public.taskfold_write_comment(gen_random_uuid(),'f1775000-0000-4000-8000-000000000003','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Retained history after author deletion','{f1771000-0000-4000-8000-000000000001}');
 if r->'current'->>'author_id' is distinct from auth.uid()::text then raise exception 'Rejoined authorship incorrect';end if;
end $$;
reset role;
delete from auth.users where id='f1771000-0000-4000-8000-000000000003';
set local role authenticated;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000001';
do $$ begin
 if not exists(select 1 from public.task_comments where id='f1775000-0000-4000-8000-000000000003' and author_id is null and body='Retained history after author deletion') then raise exception 'Author deletion erased or forged retained attribution';end if;
 -- Exact UTF-8 boundary is accepted; no @name parsing is performed.
 if public.taskfold_write_comment(gen_random_uuid(),gen_random_uuid(),'f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,repeat('😀',4000),'{}')->>'status' is distinct from 'saved' then raise exception 'Valid byte boundary refused';end if;
 begin
  perform public.taskfold_write_comment(gen_random_uuid(),gen_random_uuid(),'f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Too many recipients',array_fill(auth.uid(),array[26]));raise exception 'Recipient bound bypassed';
 exception when invalid_parameter_value then null;end;
 begin
  perform public.taskfold_write_comment(gen_random_uuid(),gen_random_uuid(),'f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Null recipient',array[null]::uuid[]);raise exception 'Null recipient bypassed';
 exception when invalid_parameter_value then null;end;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000003';
do $$ begin
 if public.taskfold_write_comment(gen_random_uuid(),gen_random_uuid(),'f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Deleted account callback','{}')->>'status' is distinct from 'unavailable' then raise exception 'Deleted account callback accepted';end if;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000002';
do $$ declare r jsonb;begin
 if (select revision from public.task_mentions) is distinct from 3 or (select read_at from public.task_mentions) is not null then raise exception 'Body edit reset recipient state';end if;
 r:=public.taskfold_write_comment('f1774000-0000-4000-8000-000000000022','f1775000-0000-4000-8000-000000000002','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Member authored reply',array['f1771000-0000-4000-8000-000000000001']::uuid[]);
 if r->>'status' is distinct from 'saved' or r->'current'->>'deleted_at' is null then raise exception 'Late add resurrected moderated reply';end if;
 r:=public.taskfold_write_comment(gen_random_uuid(),'f1775000-0000-4000-8000-000000000002','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',2,'Resurrect','{}');
 if r->>'status' is distinct from 'unavailable' then raise exception 'Tombstone edited back to life';end if;
end $$;
set local request.jwt.claim.sub='f1771000-0000-4000-8000-000000000001';
do $$ declare r jsonb;begin
 if (select comments from public.tasks where id='f1773000-0000-4000-8000-000000000001') is distinct from '[{"id":"legacy","authorId":"legacy-imported","authorName":"Historical person","text":"Imported @name","attachment":{"opaque":"retained"}}]'::jsonb then raise exception 'Legacy comment/attachment altered';end if;
 r:=public.taskfold_write_comment('f1774000-0000-4000-8000-000000000040','f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',4,'','{}',true);
 if r->>'status' is distinct from 'saved' or (r->'current'->>'revision')::bigint is distinct from 5 then raise exception 'Author deletion failed';end if;
 perform public.taskfold_write_comment('f1774000-0000-4000-8000-000000000040','f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',4,'','{}',true);
 if (select revision from public.task_comments where id='f1775000-0000-4000-8000-000000000001') is distinct from 5 then raise exception 'Delete retry changed revision';end if;
 delete from public.tasks where id='f1773000-0000-4000-8000-000000000001';
 insert into public.tasks(id,user_id,title,project_id) values('f1773000-0000-4000-8000-000000000001',auth.uid(),'Recreated task','f1772000-0000-4000-8000-000000000001');
 if (select task_generation::text from public.tasks where id='f1773000-0000-4000-8000-000000000001')=current_setting('test.shared_generation') then raise exception 'Task generation reused';end if;
 r:=public.taskfold_write_comment('f1774000-0000-4000-8000-000000000001','f1775000-0000-4000-8000-000000000001','f1773000-0000-4000-8000-000000000001',current_setting('test.shared_generation')::uuid,'f1772000-0000-4000-8000-000000000001',0,'Please review. Literal @outsider stays literal.',array['f1771000-0000-4000-8000-000000000002','f1771000-0000-4000-8000-000000000003']::uuid[]);
 if r->>'status' is distinct from 'unavailable' or exists(select 1 from public.task_comments) then raise exception 'Stale callback reached recreated task';end if;
end $$;
reset role;
do $$ begin
 if exists(select 1 from taskfold_private.comment_operations where actor_id::text like 'f1771000-%') then raise exception 'Task deletion left receipts';end if;
 if exists(select 1 from public.task_mentions where recipient_id::text like 'f1771000-%') then raise exception 'Task deletion left mentions';end if;
 if has_function_privilege('anon','public.taskfold_write_comment(uuid,uuid,uuid,uuid,uuid,bigint,text,uuid[],boolean)','execute') or has_function_privilege('anon','public.taskfold_mark_mention(uuid,uuid,bigint,boolean)','execute') then raise exception 'Anonymous RPC grant';end if;
 if (select prosecdef from pg_proc where oid='public.taskfold_write_comment(uuid,uuid,uuid,uuid,uuid,bigint,text,uuid[],boolean)'::regprocedure) then raise exception 'Exposed definer';end if;
end $$;
set local role anon;
set local request.jwt.claim.sub='';
do $$ begin
 begin perform public.taskfold_mark_mention(gen_random_uuid(),gen_random_uuid(),1,true);raise exception 'Anonymous invocation allowed';exception when insufficient_privilege then null;end;
end $$;
set local role authenticated;
do $$ begin
 begin perform public.taskfold_mark_mention(gen_random_uuid(),gen_random_uuid(),1,true);raise exception 'Missing identity accepted';exception when insufficient_privilege then null;end;
end $$;
reset role;
select 'shared-comment actual-role fixture passed' as result;
rollback;
