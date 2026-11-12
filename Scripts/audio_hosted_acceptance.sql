-- Taskfold hosted acceptance: PERSONAL audio comments, database and Storage layer.
--
--   supabase db query --remote --yes -f Scripts/audio_hosted_acceptance.sql
--
-- Everything happens inside ONE transaction that ends in ROLLBACK, so the fixture
-- users, sessions, tasks, publications, Storage rows, Vault secret and scheduler
-- changes are all discarded; an assertion failure aborts the script, which also
-- rolls everything back. The feature switches are turned on INSIDE the transaction
-- only (audio_comment_config.enabled and audience_review_enabled); the persisted
-- values are never touched. No password, JWT or real token is used, and nothing
-- is deployed. The RPCs are the exact ones the audio-comments and
-- audio-comment-maintenance functions call, run as `service_role`; clients are
-- simulated with `request.jwt.claim.sub` under the `authenticated` role.
--
-- Covered: owner reserve/upload/publish/list/read/remove of an own audio record,
-- another account cannot read/list/remove/reserve against it, Storage object
-- policy denies every client role, size/duration/MIME/caption/quota limits,
-- orphan cleanup (retire, claim, confirm/purge, stale upload fence when the
-- cadence migration is applied), scheduler configure/activate/disable, privilege
-- boundaries. Output: a final single row "AUDIO ACCEPTANCE PASSED".
begin;
set local timezone = 'UTC';
set local lock_timeout = '5s';
set local statement_timeout = '120s';
create function pg_temp.require(ok boolean, label text) returns void language plpgsql as $$begin
 if ok is distinct from true then raise exception 'AUDIO ACCEPTANCE FAILED: %', label; end if;
end$$;
-- Runs a statement, true when it is refused by a privilege or row-level policy check.
create function pg_temp.refused(statement text) returns boolean language plpgsql as $$begin
 execute statement;
 return false;
exception when insufficient_privilege then return true;
end$$;
-- True when a statement changes no row or is refused outright (Storage also blocks direct
-- deletes with a trigger, so a client delete is refused before row-level security applies).
create function pg_temp.unchanged(statement text) returns boolean language plpgsql as $$declare n bigint;begin
 execute statement;
 get diagnostics n = row_count;
 return n = 0;
exception when insufficient_privilege then return true;
end$$;
-- True when a count query returns 0 or the role is refused (anon cannot evaluate every policy).
create function pg_temp.none(query text) returns boolean language plpgsql as $$declare n bigint;begin
 execute query into n;
 return n = 0;
exception when insufficient_privilege then return true;
end$$;
create function pg_temp.id(seed text) returns uuid language sql immutable as $$select md5('taskfold-audio-acceptance:' || seed)::uuid$$;
create function pg_temp.intent(acct uuid, op uuid, task uuid, gen uuid, proj uuid, caption text, bytes integer,
  ms integer, sha text, mime text default 'audio/mp4') returns jsonb language sql as $$
 select jsonb_build_object('version', 1, 'account', acct, 'operation_id', op,
  'comment_id', pg_temp.id(op::text || 'comment'), 'asset_id', pg_temp.id(op::text || 'asset'),
  'target', jsonb_build_object('task_id', task, 'task_generation', gen, 'project_id', proj),
  'caption', caption,
  'audio', jsonb_build_object('version', 1, 'mime_type', mime, 'byte_count', bytes, 'duration_ms', ms, 'sha256', sha))
$$;

-- ---------------------------------------------------------------- fixtures
-- A owns the recording; B is another account. example.invalid can never receive mail.
insert into auth.users(id, email) values
 ('f0a0d10a-0000-4000-8000-0000000000a1', 'taskfold-audio-acceptance-a@example.invalid'),
 ('f0a0d10a-0000-4000-8000-0000000000b1', 'taskfold-audio-acceptance-b@example.invalid');
insert into public.profiles(id, user_id) select id, id from auth.users where email like 'taskfold-audio-acceptance-%@example.invalid' on conflict do nothing;
insert into auth.sessions(id, user_id) values
 ('f0a0d10a-0000-4000-8000-0000000000a2', 'f0a0d10a-0000-4000-8000-0000000000a1'),
 ('f0a0d10a-0000-4000-8000-0000000000b2', 'f0a0d10a-0000-4000-8000-0000000000b1');
insert into public.tasks(id, user_id, title) values
 ('f0a0d10a-0000-4000-8000-00000000e001', 'f0a0d10a-0000-4000-8000-0000000000a1', 'Audio acceptance task'),
 ('f0a0d10a-0000-4000-8000-00000000e002', 'f0a0d10a-0000-4000-8000-0000000000a1', 'Audio acceptance quota task'),
 ('f0a0d10a-0000-4000-8000-00000000e003', 'f0a0d10a-0000-4000-8000-0000000000b1', 'Audio acceptance task of another account');
-- The switches exist only in this transaction. First with audience review off: the shipped
-- client publishes only through a reviewed audience, so enabled alone refuses every send.
update taskfold_private.audio_comment_config set enabled = true, audience_review_enabled = false where singleton;
set local role service_role;
do $$
declare
 a uuid := 'f0a0d10a-0000-4000-8000-0000000000a1'; sa uuid := 'f0a0d10a-0000-4000-8000-0000000000a2'; t uuid := 'f0a0d10a-0000-4000-8000-00000000e001'; i jsonb;
begin
 i := pg_temp.intent(a, pg_temp.id('flag-check'), t, (select task_generation from public.tasks where id = t), null, 'x', 3000, 1500, repeat('ab', 32));
 perform pg_temp.require(public.taskfold_audio_comment_command('review_publication', a, sa, jsonb_build_object('intent', i))->>'status' = 'disabled', 'audience review off: review refused');
 perform pg_temp.require(public.taskfold_audio_comment_command('reserve', a, sa, i)->>'status' = 'disabled', 'audience review off: publish refused');
end $$;
reset role;
update taskfold_private.audio_comment_config set audience_review_enabled = true where singleton;
select set_config('acc.ready', taskfold_private.audio_bucket_ready()::text, true);
do $$ begin
 perform pg_temp.require(current_setting('acc.ready') = 'true', 'bucket taskfold-audio-v1 is private, 8 MB, audio/mp4 only');
 perform pg_temp.require((select task_generation is not null from public.tasks where id = 'f0a0d10a-0000-4000-8000-00000000e001'), 'task has a generation');
end $$;

-- ------------------------------------------- privilege boundaries (no client access)
do $$
declare r text; t text;
begin
 foreach r in array array['anon', 'authenticated', 'service_role'] loop
  foreach t in array array['audio_comment_publications', 'audio_upload_attempts', 'audio_cleanup_claims', 'audio_comment_config',
    'audio_maintenance_scheduler', 'audio_request_budgets', 'audio_publication_audiences'] loop
   perform pg_temp.require(not has_table_privilege(r, 'taskfold_private.' || t, 'select'), r || ' cannot read ' || t);
   perform pg_temp.require(not has_table_privilege(r, 'taskfold_private.' || t, 'insert'), r || ' cannot write ' || t);
  end loop;
  perform pg_temp.require(not has_function_privilege(r, 'taskfold_private.configure_audio_maintenance_scheduler(text,boolean)', 'execute'), r || ' cannot configure the scheduler');
  perform pg_temp.require(not has_function_privilege(r, 'taskfold_private.invoke_audio_maintenance_worker()', 'execute'), r || ' cannot invoke the worker');
  perform pg_temp.require(not has_function_privilege(r, 'taskfold_private.audio_scope(uuid,uuid,uuid,uuid,boolean)', 'execute'), r || ' cannot call the scope helper');
 end loop;
 foreach r in array array['anon', 'authenticated'] loop
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_audio_comment_command(text,uuid,uuid,jsonb)', 'execute'), r || ' cannot call the command RPC');
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_audio_comment_maintenance(text,jsonb)', 'execute'), r || ' cannot call maintenance');
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_audio_comment_admit(uuid,uuid,text)', 'execute'), r || ' cannot call admission');
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_audio_comment_page(uuid,uuid,jsonb)', 'execute'), r || ' cannot page');
  perform pg_temp.require(not has_function_privilege(r, 'public.taskfold_audio_owner_publication(uuid,uuid,jsonb)', 'execute'), r || ' cannot resolve owner publications');
 end loop;
 perform pg_temp.require(has_function_privilege('service_role', 'public.taskfold_audio_comment_command(text,uuid,uuid,jsonb)', 'execute'), 'service role runs the command RPC');
 perform pg_temp.require(has_function_privilege('service_role', 'public.taskfold_audio_comment_maintenance(text,jsonb)', 'execute'), 'service role runs maintenance');
 perform pg_temp.require((select not public and file_size_limit = 8000000 and allowed_mime_types = array['audio/mp4']::text[] from storage.buckets where id = 'taskfold-audio-v1'), 'bucket limits');
 perform pg_temp.require((select permissive = 'RESTRICTIVE' and roles @> array['anon', 'authenticated']::name[] and cmd = 'ALL' from pg_policies
   where schemaname = 'storage' and tablename = 'objects' and policyname = 'taskfold_audio_objects_service_only'), 'restrictive client policy on the audio bucket');
end $$;

-- ------------------------------------------------------- owner journey (service role)
set local role service_role;
do $$
declare
 a uuid := 'f0a0d10a-0000-4000-8000-0000000000a1'; sa uuid := 'f0a0d10a-0000-4000-8000-0000000000a2';
 b uuid := 'f0a0d10a-0000-4000-8000-0000000000b1'; sb uuid := 'f0a0d10a-0000-4000-8000-0000000000b2';
 t1 uuid := 'f0a0d10a-0000-4000-8000-00000000e001'; t3 uuid := 'f0a0d10a-0000-4000-8000-00000000e003';
 g1 uuid; g3 uuid; op uuid := pg_temp.id('op1'); sha text := repeat('ab', 32);
 intent jsonb; approval jsonb; r jsonb; ticket uuid; comment uuid; i integer; bad jsonb; obj text;
begin
 select task_generation into g1 from public.tasks where id = t1;
 select task_generation into g3 from public.tasks where id = t3;
 intent := pg_temp.intent(a, op, t1, g1, null, 'Voice note', 3000, 1500, sha);
 comment := (intent->>'comment_id')::uuid;

 -- Request admission (rate limiter) accepts a live session and refuses a foreign one.
 r := public.taskfold_audio_comment_admit(a, sa, 'publish');
 perform pg_temp.require((r->>'allowed')::boolean and r->>'account' = a::text, 'owner admitted');
 r := public.taskfold_audio_comment_admit(a, sb, 'publish');
 perform pg_temp.require((r->>'allowed')::boolean is not true, 'foreign session refused at admission');

 -- Audience review is personal for a personal root task, and is bound to the account.
 r := public.taskfold_audio_comment_command('review_publication', a, sa, jsonb_build_object('intent', intent));
 perform pg_temp.require(r->'audience'->>'kind' = 'personal' and r->'audience'->>'visibility' = 'personal' and r->>'account' = a::text, 'personal audience review');
 approval := r;
 -- Publishing without that approval is not possible (only the reviewed path exists).
 r := public.taskfold_audio_comment_command('reserve', a, sa, intent);
 perform pg_temp.require(r->>'status' = 'conflict', 'unreviewed publish refused');

 r := public.taskfold_audio_comment_command('reserve_approved', a, sa, jsonb_build_object('intent', intent, 'approval', approval));
 perform pg_temp.require(r->>'state' = 'pending' and r->>'object_name' = 'audio-comments/v1/' || t1 || '/' || g1 || '/' || (intent->>'asset_id') || '.m4a', 'reserved with a task-scoped object path');
 obj := r->>'object_name';
 -- Identical retry is idempotent; a changed caption under the same operation is a conflict.
 r := public.taskfold_audio_comment_command('reserve_approved', a, sa, jsonb_build_object('intent', intent, 'approval', approval));
 perform pg_temp.require(r->>'state' = 'pending', 'identical retry returns the reservation');
 bad := jsonb_set(intent, '{caption}', '"Changed"');
 r := public.taskfold_audio_comment_command('reserve_approved', a, sa, jsonb_build_object('intent', bad, 'approval', approval));
 perform pg_temp.require(r->>'status' = 'conflict', 'changed intent under the same operation refused');
 -- Not readable or listed before it is published.
 r := public.taskfold_audio_comment_command('read', a, sa, jsonb_build_object('comment_id', comment));
 perform pg_temp.require(r->>'status' = 'unavailable', 'pending recording is not readable');
 -- Upload fence: one open attempt, settled by the gateway after Storage accepts the bytes.
 r := public.taskfold_audio_comment_command('upload_begin', a, sa, jsonb_build_object('operation_id', op));
 perform pg_temp.require(r->>'state' = 'open', 'upload attempt opened');
 ticket := (r->>'ticket_id')::uuid;
 r := public.taskfold_audio_comment_command('upload_begin', a, sa, jsonb_build_object('operation_id', op));
 perform pg_temp.require(r->>'status' = 'upload_unresolved', 'a second concurrent upload is refused');
 -- Finalize needs the exact attested bytes and hash from a Storage readback, and the object
 -- committed by Storage with the right size and MIME type (the gateway's PUT is simulated).
 r := public.taskfold_audio_comment_command('finalize_approved', a, sa, jsonb_build_object('intent', intent, 'approval', approval, 'stored_sha256', sha, 'stored_bytes', 3000));
 perform pg_temp.require(r->>'status' = 'verification_failed', 'publication refused while the Storage object is missing');
 insert into storage.objects(bucket_id, name, owner_id, metadata) values ('taskfold-audio-v1', obj, null, jsonb_build_object('size', 3000, 'mimetype', 'audio/mp4'));
 r := public.taskfold_audio_comment_command('finalize_approved', a, sa, jsonb_build_object('intent', intent, 'approval', approval, 'stored_sha256', repeat('cd', 32), 'stored_bytes', 3000));
 perform pg_temp.require(r->>'status' = 'verification_failed', 'wrong stored hash refused');
 r := public.taskfold_audio_comment_command('finalize_approved', a, sa, jsonb_build_object('intent', intent, 'approval', approval, 'stored_sha256', sha, 'stored_bytes', 2999));
 perform pg_temp.require(r->>'status' = 'verification_failed', 'wrong stored size refused');
 r := public.taskfold_audio_comment_command('finalize_approved', a, sa, jsonb_build_object('intent', intent, 'approval', approval, 'stored_sha256', sha, 'stored_bytes', 3000));
 perform pg_temp.require(r->>'state' = 'published' and r->>'published_at' is not null and r->>'author_id' = a::text, 'published after verified readback');
 -- Another account cannot publish into A's approval or task.
 perform pg_temp.require(public.taskfold_audio_comment_command('finalize_approved', b, sb, jsonb_build_object('intent', intent, 'approval', approval, 'stored_sha256', sha, 'stored_bytes', 3000))->>'status' = 'unavailable', 'foreign finalize refused');

 -- Owner reads, lists and pages it.
 r := public.taskfold_audio_comment_command('read', a, sa, jsonb_build_object('comment_id', comment));
 perform pg_temp.require(r->>'state' = 'published' and r->'audio'->>'sha256' = sha and r->>'caption' = 'Voice note', 'owner reads own recording');
 r := public.taskfold_audio_comment_command('list', a, sa, jsonb_build_object('task_id', t1, 'task_generation', g1, 'project_id', null));
 perform pg_temp.require(jsonb_array_length(r->'items') = 1, 'owner lists own recording');
 r := public.taskfold_audio_comment_page(a, sa, jsonb_build_object('target', jsonb_build_object('task_id', t1, 'task_generation', g1, 'project_id', null), 'after', null));
 perform pg_temp.require(jsonb_array_length(r->'items') = 1 and r->'next' = 'null'::jsonb, 'owner pages own recording');

 -- Another account: no read, list, page, remove, publish or review against it.
 perform pg_temp.require(public.taskfold_audio_comment_command('read', b, sb, jsonb_build_object('comment_id', comment))->>'status' = 'unavailable', 'other account cannot read');
 perform pg_temp.require(public.taskfold_audio_comment_command('list', b, sb, jsonb_build_object('task_id', t1, 'task_generation', g1, 'project_id', null))->>'status' = 'unavailable', 'other account cannot list');
 perform pg_temp.require(public.taskfold_audio_comment_page(b, sb, jsonb_build_object('target', jsonb_build_object('task_id', t1, 'task_generation', g1, 'project_id', null), 'after', null))->>'status' = 'unavailable', 'other account cannot page');
 perform pg_temp.require(public.taskfold_audio_comment_command('remove', b, sb, jsonb_build_object('comment_id', comment))->>'status' = 'unavailable', 'other account cannot remove');
 perform pg_temp.require(public.taskfold_audio_comment_command('read', a, sb, jsonb_build_object('comment_id', comment))->>'status' = 'unavailable', 'a foreign session cannot read as the owner');
 bad := pg_temp.intent(b, pg_temp.id('op-b-on-a'), t1, g1, null, 'Not mine', 3000, 1500, sha);
 perform pg_temp.require(public.taskfold_audio_comment_command('review_publication', b, sb, jsonb_build_object('intent', bad))->>'status' = 'unavailable', 'other account cannot review a publication on a foreign task');
 perform pg_temp.require(public.taskfold_audio_comment_command('reserve', b, sb, bad)->>'status' = 'unavailable', 'other account cannot reserve on a foreign task');
 bad := pg_temp.intent(a, pg_temp.id('op-a-as-b'), t1, g1, null, 'Forged owner', 3000, 1500, sha);
 perform pg_temp.require(public.taskfold_audio_comment_command('review_publication', b, sb, jsonb_build_object('intent', bad))->>'status' = 'unavailable', 'an intent naming another owner is refused');
 -- The other account's own task is theirs only.
 bad := pg_temp.intent(a, pg_temp.id('op-a-on-b'), t3, g3, null, 'Not mine', 3000, 1500, sha);
 perform pg_temp.require(public.taskfold_audio_comment_command('review_publication', a, sa, jsonb_build_object('intent', bad))->>'status' = 'unavailable', 'owner cannot publish on another account''s task');

 -- Wire limits: size, duration, MIME, hash, caption, unknown fields, wrong generation.
 for i in 1..8 loop
  bad := case i
   when 1 then pg_temp.intent(a, pg_temp.id('lim1'), t1, g1, null, 'x', 8000001, 1500, sha)
   when 2 then pg_temp.intent(a, pg_temp.id('lim2'), t1, g1, null, 'x', 0, 1500, sha)
   when 3 then pg_temp.intent(a, pg_temp.id('lim3'), t1, g1, null, 'x', 3000, 120001, sha)
   when 4 then pg_temp.intent(a, pg_temp.id('lim4'), t1, g1, null, 'x', 3000, 1500, sha, 'audio/mpeg')
   when 5 then pg_temp.intent(a, pg_temp.id('lim5'), t1, g1, null, 'x', 3000, 1500, 'ABC')
   when 6 then pg_temp.intent(a, pg_temp.id('lim6'), t1, g1, null, repeat('a', 4001), 3000, 1500, sha)
   when 7 then pg_temp.intent(a, pg_temp.id('lim7'), t1, g1, null, 'x', 3000, 1500, sha) || '{"extra":1}'::jsonb
   else pg_temp.intent(a, pg_temp.id('lim8'), t1, pg_temp.id('stale-generation'), null, 'x', 3000, 1500, sha) end;
  begin
   r := public.taskfold_audio_comment_command('review_publication', a, sa, jsonb_build_object('intent', bad));
   perform pg_temp.require(i = 8 and r->>'status' = 'unavailable', 'limit case ' || i || ' accepted');
  exception when sqlstate '22023' then null; end;
 end loop;
 -- The largest allowed values pass review.
 bad := pg_temp.intent(a, pg_temp.id('limit-max'), t1, g1, null, repeat('a', 4000), 8000000, 120000, sha);
 perform pg_temp.require(public.taskfold_audio_comment_command('review_publication', a, sa, jsonb_build_object('intent', bad))->'audience'->>'kind' = 'personal', 'maximum size, duration and caption accepted');
end $$;

-- Quotas: 100 recordings / 50 MB per task and 100 recordings / 250 MB per author (count
-- limits are covered by the PostgreSQL suite). Filler rows are written directly, as the
-- table owner, so that the real reserve path meets each limit in isolation.
reset role;
insert into taskfold_private.audio_comment_publications(operation_id, comment_id, asset_id, author_id, task_id, task_generation, project_id, request_hash,
  sha256, byte_count, caption, audio_descriptor, state, published_at)
select pg_temp.id('fill' || n), pg_temp.id('fill' || n || 'c'), pg_temp.id('fill' || n || 'a'), 'f0a0d10a-0000-4000-8000-0000000000a1',
  t.id, t.task_generation, null, decode(repeat('00', 32), 'hex'), repeat('ab', 32), 8000000, 'filler',
  jsonb_build_object('version', 1, 'mime_type', 'audio/mp4', 'byte_count', 8000000, 'duration_ms', 1000, 'sha256', repeat('ab', 32)), 'published', clock_timestamp()
from generate_series(1, 6) n, public.tasks t where t.id = 'f0a0d10a-0000-4000-8000-00000000e002';
set local role service_role;
do $$
declare
 a uuid := 'f0a0d10a-0000-4000-8000-0000000000a1'; sa uuid := 'f0a0d10a-0000-4000-8000-0000000000a2';
 t2 uuid := 'f0a0d10a-0000-4000-8000-00000000e002'; g2 uuid; intent jsonb; approval jsonb;
begin
 select task_generation into g2 from public.tasks where id = t2;
 -- 48 MB are held on the task: 3 MB more passes 50 MB and is refused, 1 MB fits.
 intent := pg_temp.intent(a, pg_temp.id('task-over'), t2, g2, null, 'over', 3000000, 1000, repeat('ab', 32));
 approval := public.taskfold_audio_comment_command('review_publication', a, sa, jsonb_build_object('intent', intent));
 perform pg_temp.require(public.taskfold_audio_comment_command('reserve_approved', a, sa, jsonb_build_object('intent', intent, 'approval', approval))->>'status' = 'quota', 'task byte quota is enforced');
 intent := pg_temp.intent(a, pg_temp.id('task-fit'), t2, g2, null, 'fits', 1000000, 1000, repeat('ab', 32));
 approval := public.taskfold_audio_comment_command('review_publication', a, sa, jsonb_build_object('intent', intent));
 perform pg_temp.require(public.taskfold_audio_comment_command('reserve_approved', a, sa, jsonb_build_object('intent', intent, 'approval', approval))->>'state' = 'pending', 'a recording within the task quota is accepted');
end $$;
set local role service_role;
do $$
declare
 a uuid := 'f0a0d10a-0000-4000-8000-0000000000a1'; sa uuid := 'f0a0d10a-0000-4000-8000-0000000000a2';
 t1 uuid := 'f0a0d10a-0000-4000-8000-00000000e001'; g1 uuid; intent jsonb; approval jsonb;
begin
 select task_generation into g1 from public.tasks where id = t1;
 -- The largest allowed clip (8 MB) fits while the author is far below 250 MB.
 intent := pg_temp.intent(a, pg_temp.id('bytes-ok'), t1, g1, null, 'big', 8000000, 100000, repeat('ab', 32));
 approval := public.taskfold_audio_comment_command('review_publication', a, sa, jsonb_build_object('intent', intent));
 perform pg_temp.require(public.taskfold_audio_comment_command('reserve_approved', a, sa, jsonb_build_object('intent', intent, 'approval', approval))->>'state' = 'pending', 'largest recording within quota is accepted');
end $$;
reset role;
reset role;
-- Push the author to the edge of 250 MB on a different task (so only the author limit can
-- refuse): 30 rows of 8 MB. Rows are capped at 8 MB each by the table.
insert into taskfold_private.audio_comment_publications(operation_id, comment_id, asset_id, author_id, task_id, task_generation, project_id, request_hash,
  sha256, byte_count, caption, audio_descriptor, state, published_at)
select pg_temp.id('edge' || n), pg_temp.id('edge' || n || 'c'), pg_temp.id('edge' || n || 'a'), 'f0a0d10a-0000-4000-8000-0000000000a1', t.id, t.task_generation, null,
  decode(repeat('00', 32), 'hex'), repeat('ab', 32), 8000000, 'edge',
  jsonb_build_object('version', 1, 'mime_type', 'audio/mp4', 'byte_count', 8000000, 'duration_ms', 1000, 'sha256', repeat('ab', 32)), 'published', clock_timestamp()
from generate_series(1, 30) n, public.tasks t where t.id = 'f0a0d10a-0000-4000-8000-00000000e003';
set local role service_role;
do $$
declare
 a uuid := 'f0a0d10a-0000-4000-8000-0000000000a1'; sa uuid := 'f0a0d10a-0000-4000-8000-0000000000a2';
 t1 uuid := 'f0a0d10a-0000-4000-8000-00000000e001'; g1 uuid; intent jsonb; approval jsonb;
begin
 select task_generation into g1 from public.tasks where id = t1;
 intent := pg_temp.intent(a, pg_temp.id('over-author'), t1, g1, null, 'over', 7000000, 100000, repeat('ab', 32));
 approval := public.taskfold_audio_comment_command('review_publication', a, sa, jsonb_build_object('intent', intent));
 perform pg_temp.require(public.taskfold_audio_comment_command('reserve_approved', a, sa, jsonb_build_object('intent', intent, 'approval', approval))->>'status' = 'quota', 'author byte quota is enforced');
end $$;

-- --------------------------------------------- Storage policy (client JWT simulation)
reset role;
select set_config('acc.object', (select object_name from taskfold_private.audio_comment_publications where operation_id = pg_temp.id('op1')), true);
do $$ begin
 perform pg_temp.require((select count(*) from storage.objects where bucket_id = 'taskfold-audio-v1' and name = current_setting('acc.object')) = 1, 'fixture object exists for the policy test');
end $$;
select set_config('request.jwt.claim.sub', 'f0a0d10a-0000-4000-8000-0000000000a1', true),
       set_config('request.jwt.claims', '{"sub":"f0a0d10a-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
 -- Even the owner of the recording (an authenticated client) reaches nothing directly.
 perform pg_temp.require((select count(*) from storage.objects where bucket_id = 'taskfold-audio-v1') = 0, 'owner client cannot list audio objects');
 perform pg_temp.require((select count(*) from storage.objects where name = current_setting('acc.object')) = 0, 'owner client cannot read the audio object by name');
 perform pg_temp.require(pg_temp.refused(format('insert into storage.objects(bucket_id,name,owner_id) values(%L,%L,%L)',
   'taskfold-audio-v1', 'audio-comments/v1/forged/' || md5('x') || '.m4a', 'f0a0d10a-0000-4000-8000-0000000000a1')), 'owner client cannot upload into the audio bucket');
 perform pg_temp.require(pg_temp.unchanged(format('update storage.objects set name = name || %L where name = %L', 'x', current_setting('acc.object'))), 'owner client cannot update the audio object');
 perform pg_temp.require(pg_temp.unchanged(format('delete from storage.objects where name = %L', current_setting('acc.object'))), 'owner client cannot delete the audio object');
end $$;
reset role;
select set_config('request.jwt.claim.sub', 'f0a0d10a-0000-4000-8000-0000000000b1', true),
       set_config('request.jwt.claims', '{"sub":"f0a0d10a-0000-4000-8000-0000000000b1","role":"authenticated"}', true);
set local role authenticated;
do $$
begin
 perform pg_temp.require((select count(*) from storage.objects where bucket_id = 'taskfold-audio-v1') = 0, 'other client cannot list audio objects');
 perform pg_temp.require(pg_temp.refused(format('insert into storage.objects(bucket_id,name,owner_id) values(%L,%L,%L)',
   'taskfold-audio-v1', 'audio-comments/v1/forged/' || md5('y') || '.m4a', 'f0a0d10a-0000-4000-8000-0000000000b1')), 'other client cannot upload into the audio bucket');
 perform pg_temp.require(pg_temp.unchanged('delete from storage.objects where bucket_id = ''taskfold-audio-v1'''), 'other client cannot delete audio objects');
end $$;
reset role;
set local role anon;
do $$ begin
 perform pg_temp.require(pg_temp.none('select count(*) from storage.objects where bucket_id = ''taskfold-audio-v1'''), 'anonymous cannot list audio objects');
 perform pg_temp.require(pg_temp.refused(format('insert into storage.objects(bucket_id,name) values(%L,%L)', 'taskfold-audio-v1', 'audio-comments/v1/forged/anon.m4a')), 'anonymous cannot upload into the audio bucket');
end $$;
reset role;
select set_config('request.jwt.claim.sub', '', true), set_config('request.jwt.claims', '', true);

-- --------------------- removal, orphan cleanup and the stale upload fence (service role)
set local role service_role;
do $$
declare
 a uuid := 'f0a0d10a-0000-4000-8000-0000000000a1'; sa uuid := 'f0a0d10a-0000-4000-8000-0000000000a2';
 b uuid := 'f0a0d10a-0000-4000-8000-0000000000b1'; sb uuid := 'f0a0d10a-0000-4000-8000-0000000000b2';
 t1 uuid := 'f0a0d10a-0000-4000-8000-00000000e001'; g1 uuid; comment uuid := pg_temp.id(pg_temp.id('op1')::text || 'comment');
 r jsonb; items jsonb; found boolean;
begin
 select task_generation into g1 from public.tasks where id = t1;
 -- Owner removal retires the record: unreadable at once, quota held until Storage cleanup.
 r := public.taskfold_audio_comment_command('remove', a, sa, jsonb_build_object('comment_id', comment));
 perform pg_temp.require(r->>'state' = 'retired' and r->>'comment_id' = comment::text, 'owner removes own recording');
 r := public.taskfold_audio_comment_command('remove', a, sa, jsonb_build_object('comment_id', comment));
 perform pg_temp.require(r->>'state' = 'retired', 'removal is idempotent');
 perform pg_temp.require(public.taskfold_audio_comment_command('read', a, sa, jsonb_build_object('comment_id', comment))->>'status' = 'unavailable', 'removed recording is unreadable');
 perform pg_temp.require(not exists(select 1 from jsonb_array_elements(public.taskfold_audio_comment_command('list', a, sa, jsonb_build_object('task_id', t1, 'task_generation', g1, 'project_id', null))->'items') i where i->>'comment_id' = comment::text), 'removed recording is not listed');
 perform pg_temp.require(public.taskfold_audio_comment_command('remove', b, sb, jsonb_build_object('comment_id', comment))->>'status' = 'unavailable', 'other account cannot remove it again');
 -- Retired media waits for its grace period: nothing to claim yet.
 items := public.taskfold_audio_comment_maintenance('claim', '{}')->'items';
 perform pg_temp.require(not exists(select 1 from jsonb_array_elements(items) i where i->>'asset_id' = pg_temp.id(pg_temp.id('op1')::text || 'asset')::text), 'retired media is not claimed before its grace period');
end $$;
reset role;
update taskfold_private.audio_comment_publications set cleanup_after = clock_timestamp() - interval '1 second' where operation_id = pg_temp.id('op1');
set local role service_role;
do $$
declare
 asset uuid := pg_temp.id(pg_temp.id('op1')::text || 'asset'); op uuid := pg_temp.id('op1');
 claimed jsonb; item jsonb; r jsonb;
begin
 -- The upload attempt of op1 was settled by the verified finalize, so cleanup may claim it.
 claimed := public.taskfold_audio_comment_maintenance('claim', '{}');
 select i into item from jsonb_array_elements(claimed->'items') i where i->>'asset_id' = asset::text;
 perform pg_temp.require(item is not null and item->>'bucket' = 'taskfold-audio-v1' and item->>'object_name' like 'audio-comments/v1/%.m4a', 'retired media is claimed for Storage removal');
 -- Purging needs the Storage object to be gone first.
 r := public.taskfold_audio_comment_maintenance('confirm', jsonb_build_object('operation_id', op, 'asset_id', asset, 'object_name', item->>'object_name', 'token', item->>'token'));
 perform pg_temp.require((r->>'purged')::boolean is false, 'purge refused while the object still exists');
 perform set_config('acc.token', item->>'token', true);
end $$;
reset role;
-- What the Storage API does after it removed the object (it sets the same switch).
select set_config('storage.allow_delete_query', 'true', true);
delete from storage.objects where bucket_id = 'taskfold-audio-v1' and name = current_setting('acc.object');
select set_config('storage.allow_delete_query', 'false', true);
set local role service_role;
do $$
declare
 asset uuid := pg_temp.id(pg_temp.id('op1')::text || 'asset'); op uuid := pg_temp.id('op1'); r jsonb; name text := current_setting('acc.object');
begin
 -- The first claim is still live (two minutes), so reuse its token after the object is gone.
 r := public.taskfold_audio_comment_maintenance('confirm', jsonb_build_object('operation_id', op, 'asset_id', asset, 'object_name', name, 'token', current_setting('acc.token')));
 perform pg_temp.require((r->>'purged')::boolean, 'purged after the object is gone');
 -- A wrong token never purges.
 perform pg_temp.require((public.taskfold_audio_comment_maintenance('confirm', jsonb_build_object('operation_id', op, 'asset_id', asset, 'object_name', name, 'token', pg_temp.id('wrong')))->>'purged')::boolean is not true, 'wrong cleanup token refused');
end $$;
reset role;
-- Abandoned upload: a reservation that expired with an upload that never reached Storage.
-- Younger than the fence it stays blocked; older than the fence (when the cadence
-- migration is applied) cleanup claims it so the quota is released.
insert into taskfold_private.audio_comment_publications(operation_id, comment_id, asset_id, author_id, task_id, task_generation, project_id, request_hash,
  sha256, byte_count, caption, audio_descriptor, state, cleanup_after)
select pg_temp.id('ab' || n), pg_temp.id('ab' || n || 'c'), pg_temp.id('ab' || n || 'a'), 'f0a0d10a-0000-4000-8000-0000000000a1', t.id, t.task_generation, null,
  decode(repeat('00', 32), 'hex'), repeat('ab', 32), 1000, null, null, 'retired', clock_timestamp() - interval '1 minute'
from generate_series(1, 2) n, public.tasks t where t.id = 'f0a0d10a-0000-4000-8000-00000000e001';
insert into taskfold_private.audio_upload_attempts(operation_id, state, started_at, next_probe_at) values
 (pg_temp.id('ab1'), 'open', clock_timestamp() - interval '3 hours', clock_timestamp() + interval '1 day'),
 (pg_temp.id('ab2'), 'open', clock_timestamp() - interval '5 minutes', clock_timestamp() + interval '1 day');
select set_config('acc.fence', (to_regprocedure('taskfold_private.audio_upload_fence()') is not null)::text, true);
set local role service_role;
do $$
declare claimed jsonb; fenced boolean := current_setting('acc.fence') = 'true';
begin
 claimed := public.taskfold_audio_comment_maintenance('claim', '{}');
 perform pg_temp.require(not exists(select 1 from jsonb_array_elements(claimed->'items') i where i->>'operation_id' = pg_temp.id('ab2')::text), 'a recent unresolved upload stays fenced');
 perform pg_temp.require((claimed->>'blocked_uploads')::integer >= 1, 'blocked uploads are reported');
 if fenced then
  perform pg_temp.require(exists(select 1 from jsonb_array_elements(claimed->'items') i where i->>'operation_id' = pg_temp.id('ab1')::text), 'a stale unresolved upload is claimed for cleanup');
 else
  perform pg_temp.require(not exists(select 1 from jsonb_array_elements(claimed->'items') i where i->>'operation_id' = pg_temp.id('ab1')::text), 'without the cadence migration a stale upload stays blocked');
 end if;
end $$;
reset role;

-- ------------------------------------------------------------------- scheduler
-- Configure, activate and disable the maintenance cron job with a synthetic Vault key.
do $$
declare jid bigint; s text;
begin
 select jobid, schedule into jid, s from cron.job where jobname = 'taskfold-audio-maintenance';
 perform pg_temp.require(jid is not null, 'maintenance cron job exists');
 perform pg_temp.require(s in ('* * * * *', '*/15 * * * *'), 'cron schedule is known: ' || s);
 -- The live key stays untouched when setup already stored it; otherwise a synthetic one is rolled back.
 if not exists(select 1 from vault.secrets where name = 'taskfold_audio_maintenance_key') then
  perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'taskfold_audio_maintenance_key', 'acceptance, rolled back');
 end if;
 perform taskfold_private.configure_audio_maintenance_scheduler('abcdefghijklmnopqrst', true);
 perform pg_temp.require((select active from cron.job where jobid = jid), 'cron job active after configure');
 perform pg_temp.require((select enabled and project_ref = 'abcdefghijklmnopqrst' and last_state = 'unconfigured' from taskfold_private.audio_maintenance_scheduler where singleton), 'scheduler row enabled');
 begin perform taskfold_private.configure_audio_maintenance_scheduler(null, true); raise exception 'AUDIO ACCEPTANCE FAILED: scheduler enabled without a project';
 exception when others then if sqlerrm like 'AUDIO ACCEPTANCE FAILED%' then raise; end if; end;
 perform taskfold_private.configure_audio_maintenance_scheduler(null, false);
 perform pg_temp.require(not (select active from cron.job where jobid = jid), 'cron job inactive after disable');
 perform pg_temp.require(not (select enabled from taskfold_private.audio_maintenance_scheduler where singleton), 'scheduler row disabled');
end $$;

-- Delete every fixture: users, tasks, publications, Storage rows, Vault secret, scheduler
-- and cron state and the temporary switches all go with the transaction.
rollback;
-- Reaching this point means every assertion above held and nothing was persisted.
select 'AUDIO ACCEPTANCE PASSED' as result,
 not exists(select 1 from auth.users where email like 'taskfold-audio-acceptance-%@example.invalid') as fixtures_removed,
 not exists(select 1 from taskfold_private.audio_comment_publications) as no_audio_rows,
 not exists(select 1 from storage.objects where bucket_id = 'taskfold-audio-v1') as no_audio_objects,
 (select not team_publication_enabled and not restoration_enabled from taskfold_private.audio_comment_config where singleton) as team_and_restore_off,
 (select enabled and audience_review_enabled from taskfold_private.audio_comment_config where singleton) as personal_audio_live,
 (select active from cron.job where jobname = 'taskfold-audio-maintenance') as cron_active;
