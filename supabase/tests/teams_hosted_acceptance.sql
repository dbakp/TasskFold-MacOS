begin;
-- Hosted acceptance for team workspaces. Run with: supabase db query --remote --yes -f this-file.
-- Everything happens inside one transaction that ends in ROLLBACK; fixtures use @example.invalid accounts.
-- Result: one JSON row with verdict CHECK_OK or CHECK_FAILED and any failing checks.
create temp table acc(n serial, label text, ok boolean, detail text);
create temp table lastv(v jsonb);
create temp table ppl(k text primary key, id uuid, sid uuid, email text);
insert into ppl select k, format('f01dcafe-7e00-4000-8000-%s',lpad(i::text,12,'0'))::uuid, format('f01dcafe-7e00-4000-9000-%s',lpad(i::text,12,'0'))::uuid, 'teams-qa-'||k||'@example.invalid'
 from unnest(array['owner','admin','member','peer','guest','outsider']) with ordinality u(k,i);
create function pg_temp.exec(who text, sql text, out code text, out msg text, out v jsonb) language plpgsql as $f$
declare p record;
begin
 select * into p from ppl where ppl.k=who;
 perform set_config('request.jwt.claims', jsonb_build_object('sub',p.id,'role','authenticated','session_id',p.sid)::text, true);
 perform set_config('request.jwt.claim.sub', p.id::text, true);
 code:='ok';
 begin
  set local role authenticated;
  execute sql into v;
 exception when others then code:=sqlstate; msg:=left(sqlerrm,110); v:=null; end;
 reset role;
 perform set_config('request.jwt.claims','',true); perform set_config('request.jwt.claim.sub','',true);
end$f$;
create function pg_temp.call(lbl text, who text, sql text, expect text default 'ok') returns void language plpgsql as $f$
declare r record;
begin
 select * into r from pg_temp.exec(who,sql);
 delete from lastv; insert into lastv values(r.v);
 insert into acc(label,ok,detail) values(lbl, case expect when 'err' then r.code<>'ok' when 'any' then true else r.code=expect end, 'want '||expect||' got '||r.code||coalesce(' '||r.msg,'')||coalesce(' '||left(r.v::text,90),''));
end$f$;
create function pg_temp.eq(lbl text, who text, sql text, want jsonb) returns void language plpgsql as $f$
declare r record;
begin
 select * into r from pg_temp.exec(who,sql);
 delete from lastv; insert into lastv values(r.v);
 insert into acc(label,ok,detail) values(lbl, r.code='ok' and r.v is not distinct from want, 'want '||want::text||' got '||r.code||coalesce(' '||r.msg,'')||' '||coalesce(left(r.v::text,90),''));
end$f$;
create function pg_temp.note(lbl text, ok boolean, detail text default '') returns void language sql as $f$ insert into acc(label,ok,detail) values(lbl,ok,detail) $f$;
create function pg_temp.lv() returns jsonb language sql as $f$ select v from lastv $f$;
create function pg_temp.pid(who text) returns uuid language sql as $f$ select id from ppl where k=who $f$;
create function pg_temp.tb(team uuid, extra jsonb default '{}', rev boolean default true) returns jsonb language sql as $f$
 select jsonb_build_object('team_id',team,'request_id',gen_random_uuid(),'issued_at',to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'))
  || case when rev then jsonb_build_object('revision',(select revision from taskfold_private.teams where id=team)) else '{}'::jsonb end || extra $f$;
create function pg_temp.org(lbl text, who text, action text, team uuid, extra jsonb default '{}', expect text default 'ok', rev boolean default true) returns void language plpgsql as $f$
begin perform pg_temp.call(lbl, who, format('select public.taskfold_teams(%L,%L::jsonb)', action, pg_temp.tb(team,extra,rev)::text), expect); end$f$;
create function pg_temp.vis(lbl text, who text, tbl text, id uuid, want int) returns void language plpgsql as $f$
begin perform pg_temp.eq(lbl, who, format('select to_jsonb(count(*)) from public.%I where id=%L',tbl,id), to_jsonb(want)); end$f$;
create function pg_temp.inv(team uuid, who text) returns uuid language sql as $f$ select id from taskfold_private.team_invitations where team_id=team and email=(select email from ppl where k=who) $f$;
-- fixture identities
insert into auth.users(id,email,email_confirmed_at,raw_user_meta_data) select id,email,now(),'{}' from ppl;
insert into auth.sessions(id,user_id) select sid,id from ppl;
insert into public.profiles(user_id,display_name) select p.id,'Teams QA '||p.k from ppl p where not exists(select 1 from public.profiles x where x.user_id=p.id);

create function pg_temp.raw(lbl text, rl text, claims jsonb, sql text, expect text) returns void language plpgsql as $f$
declare code text:='ok'; msg text; v jsonb;
begin
 perform set_config('request.jwt.claims', coalesce(claims::text,''), true);
 perform set_config('request.jwt.claim.sub', coalesce(claims->>'sub',''), true);
 begin
  execute 'set local role '||quote_ident(rl);
  execute sql into v;
 exception when others then code:=sqlstate; msg:=left(sqlerrm,110); end;
 reset role;
 perform set_config('request.jwt.claims','',true); perform set_config('request.jwt.claim.sub','',true);
 insert into acc(label,ok,detail) values(lbl, case expect when 'err' then code<>'ok' else code=expect end, 'want '||expect||' got '||code||coalesce(' '||msg,''));
end$f$;
insert into auth.users(id,email,email_confirmed_at) values ('f01dcafe-7e00-4000-8000-0000000000e1','teams-qa-unconfirmed@example.invalid',null),('f01dcafe-7e00-4000-8000-0000000000e2','teams-qa-expired@example.invalid',now());
insert into auth.sessions(id,user_id,not_after) values ('f01dcafe-7e00-4000-9000-0000000000e1','f01dcafe-7e00-4000-8000-0000000000e1',null),('f01dcafe-7e00-4000-9000-0000000000e2','f01dcafe-7e00-4000-8000-0000000000e2',now()-interval '1 hour');
create function pg_temp.getteam(lbl text, who text, team uuid, expect text) returns void language plpgsql as $f$ begin perform pg_temp.call(lbl,who,format('select public.taskfold_teams(''get'',%L::jsonb)',jsonb_build_object('team_id',team)::text),expect); end$f$;
create function pg_temp.invx(team uuid, mail text) returns uuid language sql as $f$ select id from taskfold_private.team_invitations where team_id=team and email=lower(mail) $f$;
create function pg_temp.iso() returns text language sql as $f$ select to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"') $f$;
do $do$
declare
 c_team boolean; c_tpl boolean; c_reads boolean; c_edits boolean; c_adopt boolean; c_types boolean;
 T uuid:=gen_random_uuid(); T2 uuid:=gen_random_uuid();
 Pteam uuid:=gen_random_uuid(); Ppriv uuid:=gen_random_uuid(); Pdest uuid:=gen_random_uuid(); P2 uuid:=gen_random_uuid(); Prpc uuid:=gen_random_uuid(); PP uuid:=gen_random_uuid();
 tteam uuid:=gen_random_uuid(); tpriv uuid:=gen_random_uuid(); tdest uuid:=gen_random_uuid(); tk2 uuid:=gen_random_uuid(); tpp uuid:=gen_random_uuid();
 tmpl uuid:=gen_random_uuid();
 b jsonb; who text; rv jsonb; ids jsonb; reviewed jsonb; insp jsonb; tran uuid; g uuid;
begin
 select enabled into c_team from taskfold_private.team_config where singleton;
 select enabled into c_tpl from taskfold_private.team_template_config where singleton;
 select native_reads_enabled,native_task_edits_enabled,native_project_adoption_enabled,native_task_types_enabled into c_reads,c_edits,c_adopt,c_types from taskfold_private.team_project_config where singleton;
 perform pg_temp.note('config', true, format('team=%s tpl=%s reads=%s edits=%s adopt=%s types=%s',c_team,c_tpl,c_reads,c_edits,c_adopt,c_types));

 ---------------- S1a organization ----------------
 if not c_team then
  perform pg_temp.org('closed: create refused','owner','create',T,jsonb_build_object('name','QA team'),'PT503',false);
  perform pg_temp.getteam('closed: unknown team get refused','owner',T,'PT404');
  perform pg_temp.note('stage ends (team switch off)',true);
  return;
 end if;

 -- authentication-boundary checks (read path, so independent of the switch)
 perform pg_temp.raw('anon cannot call taskfold_teams','anon',null,'select public.taskfold_teams(''list'',''{}''::jsonb)','42501');
 perform pg_temp.raw('anon cannot call project catalog','anon',null,format('select public.taskfold_team_projects(''list'',%L::jsonb)',jsonb_build_object('team_id',T)::text),'42501');
 perform pg_temp.raw('authenticated cannot read private team tables','authenticated',jsonb_build_object('sub',pg_temp.pid('owner'),'role','authenticated'),'select to_jsonb(count(*)) from taskfold_private.teams','42501');
 perform pg_temp.raw('private team_manage (grant by design) still enforces membership','authenticated',jsonb_build_object('sub',pg_temp.pid('outsider'),'role','authenticated','session_id',(select sid from ppl where k='outsider')),format('select taskfold_private.team_manage(''get'',%L::jsonb)',jsonb_build_object('team_id',T)::text),'PT404');
 perform pg_temp.raw('missing session_id claim refused','authenticated',jsonb_build_object('sub',pg_temp.pid('owner'),'role','authenticated'),'select public.taskfold_teams(''list'',''{}''::jsonb)','28000');
 perform pg_temp.raw('foreign account session id refused','authenticated',jsonb_build_object('sub',pg_temp.pid('outsider'),'role','authenticated','session_id',(select sid from ppl where k='owner')),'select public.taskfold_teams(''list'',''{}''::jsonb)','28000');
 perform pg_temp.raw('unconfirmed email refused','authenticated',jsonb_build_object('sub','f01dcafe-7e00-4000-8000-0000000000e1','role','authenticated','session_id','f01dcafe-7e00-4000-9000-0000000000e1'),'select public.taskfold_teams(''list'',''{}''::jsonb)','28000');
 perform pg_temp.raw('expired session refused','authenticated',jsonb_build_object('sub','f01dcafe-7e00-4000-8000-0000000000e2','role','authenticated','session_id','f01dcafe-7e00-4000-9000-0000000000e2'),'select public.taskfold_teams(''list'',''{}''::jsonb)','28000');
 perform pg_temp.raw('service_role cannot call team RPC','service_role',jsonb_build_object('role','service_role'),'select public.taskfold_teams(''list'',''{}''::jsonb)','42501');
 b:=pg_temp.tb(T,jsonb_build_object('name','QA Alpha'),false);
 perform pg_temp.call('owner creates team','owner',format('select public.taskfold_teams(%L,%L::jsonb)','create',b::text));
 perform pg_temp.call('create replay returns result','owner',format('select public.taskfold_teams(%L,%L::jsonb)','create',b::text));
 perform pg_temp.call('create replay with changed body refused','owner',format('select public.taskfold_teams(%L,%L::jsonb)','create',(b||'{"name":"Changed"}')::text),'PT409');
 perform pg_temp.getteam('outsider cannot get team','outsider',T,'PT404');
 perform pg_temp.eq('outsider list empty','outsider','select (public.taskfold_teams(''list'',''{}''::jsonb))->''teams''','[]'::jsonb);
 perform pg_temp.eq('outsider invitations empty','outsider','select (public.taskfold_teams(''invitations'',''{}''::jsonb))->''invitations''','[]'::jsonb);
 perform pg_temp.org('outsider cannot invite','outsider','invite',T,jsonb_build_object('email','teams-qa-x0@example.invalid','role','member'),'PT404');
 perform pg_temp.org('outsider cannot rename','outsider','rename',T,jsonb_build_object('name','Hack'),'PT404');
 perform pg_temp.org('owner invites admin','owner','invite',T,jsonb_build_object('email',(select email from ppl where k='admin'),'role','admin'));
 perform pg_temp.org('owner invites member (mixed-case email)','owner','invite',T,jsonb_build_object('email',upper((select email from ppl where k='member')),'role','member'));
 perform pg_temp.org('owner invites peer','owner','invite',T,jsonb_build_object('email',(select email from ppl where k='peer'),'role','member'));
 perform pg_temp.org('owner invites guest','owner','invite',T,jsonb_build_object('email',(select email from ppl where k='guest'),'role','guest'));
 perform pg_temp.org('duplicate invitation refused','owner','invite',T,jsonb_build_object('email',(select email from ppl where k='guest'),'role','guest'),'PT409');
 perform pg_temp.org('outsider cannot accept someone elses invitation','outsider','accept_invitation',T,jsonb_build_object('invitation_id',pg_temp.inv(T,'member')),'PT404');
 perform pg_temp.eq('member sees exactly its invitation','member','select to_jsonb(jsonb_array_length(public.taskfold_teams(''invitations'',''{}''::jsonb)->''invitations''))','1'::jsonb);
 foreach who in array array['admin','member','peer','guest'] loop
  perform pg_temp.org(who||' accepts invitation',who,'accept_invitation',T,jsonb_build_object('invitation_id',pg_temp.inv(T,who)));
 end loop;
 perform pg_temp.eq('member view: role member, no directory, has folders','member',format('select jsonb_build_object(''role'',x->''role'',''dir'',x ? ''members'',''folders'',x ? ''folders'') from (select public.taskfold_teams(''get'',jsonb_build_object(''team_id'',%L)) x) q',T),'{"role":"member","dir":false,"folders":true}'::jsonb);
 perform pg_temp.eq('guest view: role guest, no directory, no folders','guest',format('select jsonb_build_object(''role'',x->''role'',''dir'',x ? ''members'',''folders'',x ? ''folders'') from (select public.taskfold_teams(''get'',jsonb_build_object(''team_id'',%L)) x) q',T),'{"role":"guest","dir":false,"folders":false}'::jsonb);
 perform pg_temp.eq('admin sees directory of 5','admin',format('select to_jsonb(jsonb_array_length(public.taskfold_teams(''get'',jsonb_build_object(''team_id'',%L))->''members''))',T),'5'::jsonb);
 perform pg_temp.org('member cannot invite','member','invite',T,jsonb_build_object('email','teams-qa-x1@example.invalid','role','guest'),'42501');
 perform pg_temp.org('guest cannot rename','guest','rename',T,jsonb_build_object('name','Hacked'),'42501');
 perform pg_temp.org('member cannot create folder','member','folder_create',T,jsonb_build_object('name','F'),'42501');
 perform pg_temp.org('admin cannot invite admin','admin','invite',T,jsonb_build_object('email','teams-qa-x2@example.invalid','role','admin'),'42501');
 perform pg_temp.org('admin invites guest','admin','invite',T,jsonb_build_object('email','teams-qa-x3@example.invalid','role','guest'));
 perform pg_temp.org('admin revokes that invitation','admin','revoke_invitation',T,jsonb_build_object('invitation_id',pg_temp.invx(T,'teams-qa-x3@example.invalid')));
 perform pg_temp.org('admin creates folder','admin','folder_create',T,jsonb_build_object('name','Design'));
 perform pg_temp.org('admin cannot change owner role','admin','change_role',T,jsonb_build_object('user_id',pg_temp.pid('owner'),'role','guest'),'PT409');
 perform pg_temp.org('admin cannot appoint admin','admin','change_role',T,jsonb_build_object('user_id',pg_temp.pid('member'),'role','admin'),'42501');
 perform pg_temp.org('admin changes guest to member','admin','change_role',T,jsonb_build_object('user_id',pg_temp.pid('guest'),'role','member'));
 perform pg_temp.org('admin sets it back to guest','admin','change_role',T,jsonb_build_object('user_id',pg_temp.pid('guest'),'role','guest'));
 perform pg_temp.org('owner promotes member to admin','owner','change_role',T,jsonb_build_object('user_id',pg_temp.pid('member'),'role','admin'));
 perform pg_temp.org('promoted member can now invite','member','invite',T,jsonb_build_object('email','teams-qa-x4@example.invalid','role','guest'));
 perform pg_temp.note('x4 invitation exists before demotion',pg_temp.invx(T,'teams-qa-x4@example.invalid') is not null);
 perform pg_temp.org('owner demotes it back','owner','change_role',T,jsonb_build_object('user_id',pg_temp.pid('member'),'role','member'));
 perform pg_temp.note('demotion cancels the demoted account''s issued invitations',pg_temp.invx(T,'teams-qa-x4@example.invalid') is null);
 perform pg_temp.org('member cannot archive','member','archive',T,'{}','42501');
 perform pg_temp.org('admin cannot archive','admin','archive',T,'{}','42501');
 perform pg_temp.org('member cannot delete','member','delete',T,'{}','42501');
 perform pg_temp.org('admin cannot offer ownership','admin','transfer_offer',T,jsonb_build_object('user_id',pg_temp.pid('member')),'42501');
 perform pg_temp.org('owner cannot leave','owner','leave',T,'{}','PT409');
 perform pg_temp.org('ownership offer to a guest refused','owner','transfer_offer',T,jsonb_build_object('user_id',pg_temp.pid('guest')),'22023');
 perform pg_temp.org('owner archives','owner','archive',T,'{}');
 perform pg_temp.org('archived: invite refused','owner','invite',T,jsonb_build_object('email','teams-qa-x5@example.invalid','role','guest'),'PT409');
 perform pg_temp.org('owner unarchives','owner','unarchive',T,'{}');
 perform pg_temp.org('owner offers ownership to admin','owner','transfer_offer',T,jsonb_build_object('user_id',pg_temp.pid('admin')));
 tran:=(select id from taskfold_private.team_transfers where team_id=T);
 perform pg_temp.org('wrong account cannot accept transfer','member','transfer_accept',T,jsonb_build_object('transfer_id',tran),'PT404');
 perform pg_temp.org('admin accepts ownership','admin','transfer_accept',T,jsonb_build_object('transfer_id',tran));
 perform pg_temp.note('ownership moved, former owner is admin',(select owner_id from taskfold_private.teams where id=T)=pg_temp.pid('admin') and (select role from taskfold_private.team_members where team_id=T and user_id=pg_temp.pid('owner'))='admin');
 perform pg_temp.org('new owner offers it back','admin','transfer_offer',T,jsonb_build_object('user_id',pg_temp.pid('owner')));
 tran:=(select id from taskfold_private.team_transfers where team_id=T);
 perform pg_temp.org('original owner re-accepts','owner','transfer_accept',T,jsonb_build_object('transfer_id',tran));
 perform pg_temp.note('ownership restored',(select owner_id from taskfold_private.teams where id=T)=pg_temp.pid('owner'));
 perform pg_temp.org('outsider creates its own team','outsider','create',T2,jsonb_build_object('name','QA Other'),'ok',false);

 ---------------- S2 project reads ----------------
 if not c_reads then update taskfold_private.team_project_config set native_reads_enabled=true; end if;
 insert into public.projects(id,user_id,name) values (Pteam,pg_temp.pid('peer'),'QA team project'),(Ppriv,pg_temp.pid('peer'),'QA private project'),(Pdest,pg_temp.pid('peer'),'QA destination'),(P2,pg_temp.pid('outsider'),'QA foreign team project');
 insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values (Pteam,T,'team'),(Ppriv,T,'private'),(Pdest,T,'team'),(P2,T2,'team');
 insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values (Pteam,T,pg_temp.pid('peer'),'manager'),(Ppriv,T,pg_temp.pid('peer'),'manager'),(Pdest,T,pg_temp.pid('peer'),'manager'),(P2,T2,pg_temp.pid('outsider'),'manager'),(Ppriv,T,pg_temp.pid('guest'),'viewer');
 insert into public.tasks(id,user_id,project_id,title) values (tteam,pg_temp.pid('peer'),Pteam,'QA team task'),(tpriv,pg_temp.pid('peer'),Ppriv,'QA private task'),(tdest,pg_temp.pid('peer'),Pdest,'QA dest task'),(tk2,pg_temp.pid('outsider'),P2,'QA foreign task');
 if not c_reads then update taskfold_private.team_project_config set native_reads_enabled=false; end if;
 foreach who in array array['owner','admin','member','peer','guest','outsider'] loop
  perform pg_temp.vis('reads='||c_reads||': team project row, '||who,who,'projects',Pteam, case when c_reads and who in('owner','admin','member','peer') then 1 else 0 end);
  perform pg_temp.vis('reads='||c_reads||': team task row, '||who,who,'tasks',tteam, case when c_reads and who in('owner','admin','member','peer') then 1 else 0 end);
  perform pg_temp.vis('reads='||c_reads||': private project, '||who,who,'projects',Ppriv, case when c_reads and who in('owner','admin','peer','guest') then 1 else 0 end);
  perform pg_temp.vis('reads='||c_reads||': private task, '||who,who,'tasks',tpriv, case when c_reads and who in('owner','admin','peer','guest') then 1 else 0 end);
  perform pg_temp.vis('reads='||c_reads||': foreign-team task, '||who,who,'tasks',tk2, case when c_reads and who='outsider' then 1 else 0 end);
 end loop;
 perform pg_temp.call('member direct INSERT into team project refused','member',format('insert into public.tasks(id,user_id,project_id,title) values (gen_random_uuid(),auth.uid(),%L,''sneak'') returning to_jsonb(1)',Pteam),'err');
 perform pg_temp.call('member direct UPDATE of team task','member',format('with u as (update public.tasks set title=''sneak'' where id=%L returning 1) select to_jsonb(count(*)) from u',tteam),'any');
 perform pg_temp.call('member direct DELETE of team task','member',format('with u as (delete from public.tasks where id=%L returning 1) select to_jsonb(count(*)) from u',tteam),'any');
 perform pg_temp.note('direct UPDATE/DELETE left the task intact',(select title from public.tasks where id=tteam)='QA team task');
 perform pg_temp.call('member direct UPDATE of team project','member',format('with u as (update public.projects set name=''sneak'' where id=%L returning 1) select to_jsonb(count(*)) from u',Pteam),'any');
 perform pg_temp.note('direct project UPDATE left name intact',(select name from public.projects where id=Pteam)='QA team project');
 if not c_reads then
  perform pg_temp.call('closed: project catalog refused','member',format('select public.taskfold_team_projects(''list'',%L::jsonb)',jsonb_build_object('team_id',T)::text),'PT503');
  perform pg_temp.note('stage ends (reads switch off)',true);
  perform pg_temp.org('cleanup: owner deletes team','owner','delete',T,'{}');
  return;
 end if;
 perform pg_temp.eq('member catalog = team projects only','member',format('select coalesce(jsonb_agg(x->>''id'' order by x->>''id''),''[]'') from jsonb_array_elements(public.taskfold_team_projects(''list'',jsonb_build_object(''team_id'',%L))->''projects'') x',T),(select jsonb_agg(i order by i) from unnest(array[Pteam::text,Pdest::text]) i));
 perform pg_temp.eq('guest catalog = granted private project only','guest',format('select coalesce(jsonb_agg(x->>''id'' order by x->>''id''),''[]'') from jsonb_array_elements(public.taskfold_team_projects(''list'',jsonb_build_object(''team_id'',%L))->''projects'') x',T),jsonb_build_array(Ppriv::text));
 perform pg_temp.call('outsider catalog refused','outsider',format('select public.taskfold_team_projects(''list'',%L::jsonb)',jsonb_build_object('team_id',T)::text),'PT404');
 perform pg_temp.call('outsider cannot read team project detail','outsider',format('select public.taskfold_team_projects(''get'',%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Pteam)::text),'PT404');
 perform pg_temp.call('member cannot read private project detail','member',format('select public.taskfold_team_projects(''get'',%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Ppriv)::text),'PT404');
 perform pg_temp.call('team/project mismatch (own team T2, T project) refused','outsider',format('select public.taskfold_team_projects(''get'',%L::jsonb)',jsonb_build_object('team_id',T2,'project_id',Pteam)::text),'PT404');
 perform pg_temp.call('member creates team project via RPC','member',format('select public.taskfold_team_projects(''create'',%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Prpc,'request_id',gen_random_uuid(),'issued_at',pg_temp.iso(),'team_revision',(select revision from taskfold_private.teams where id=T),'name','QA RPC project','visibility','team','folder_id',null)::text));
 perform pg_temp.vis('RPC project visible to owner','owner','projects',Prpc,1);
 perform pg_temp.vis('RPC project visible to peer (team visibility)','peer','projects',Prpc,1);
 perform pg_temp.vis('RPC project hidden from outsider','outsider','projects',Prpc,0);
 perform pg_temp.call('guest cannot create team project','guest',format('select public.taskfold_team_projects(''create'',%L::jsonb)',jsonb_build_object('team_id',T,'project_id',gen_random_uuid(),'request_id',gen_random_uuid(),'issued_at',pg_temp.iso(),'team_revision',(select revision from taskfold_private.teams where id=T),'name','Nope','visibility','team','folder_id',null)::text),'42501');
 perform pg_temp.call('outsider cannot create project in team','outsider',format('select public.taskfold_team_projects(''create'',%L::jsonb)',jsonb_build_object('team_id',T,'project_id',gen_random_uuid(),'request_id',gen_random_uuid(),'issued_at',pg_temp.iso(),'team_revision',(select revision from taskfold_private.teams where id=T),'name','Nope','visibility','team','folder_id',null)::text),'PT404');
 perform pg_temp.call('member cannot set project access','member',format('select public.taskfold_team_projects(''set_access'',%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Pteam,'request_id',gen_random_uuid(),'issued_at',pg_temp.iso(),'team_revision',(select revision from taskfold_private.teams where id=T),'revision',1,'user_id',pg_temp.pid('guest'),'role','editor')::text),'42501');
 perform pg_temp.call('workspace boundary readable by member','member','select public.taskfold_workspace_boundary()');
 perform pg_temp.note('boundary keys (info)',true,(select string_agg(key||'='||left(value::text,24),', ') from jsonb_each(pg_temp.lv()) where key ~ 'protocol|team'));

 ---------------- S3 task edits and moves ----------------
 if not c_edits then
  perform pg_temp.call('closed: member edit refused','member',format('select public.taskfold_edit_team_task(%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Pteam,'task_id',tteam,'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=tteam),'base',jsonb_build_object('title','QA team task','task_generation',(select task_generation from public.tasks where id=tteam),'project_id',Pteam),'changes',jsonb_build_object('title','Edited'))::text),'PT503');
  perform pg_temp.call('closed: member move review refused','member',format('select public.taskfold_team_task_move(''review'',%L::jsonb)',jsonb_build_object('team_id',T,'task_id',tteam,'task_generation',(select task_generation from public.tasks where id=tteam),'source_project_id',Pteam,'destination_project_id',Pdest)::text),'err');
 else
  perform pg_temp.call('member edits team task title','member',format('select public.taskfold_edit_team_task(%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Pteam,'task_id',tteam,'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=tteam),'base',jsonb_build_object('title','QA team task','task_generation',(select task_generation from public.tasks where id=tteam),'project_id',Pteam),'changes',jsonb_build_object('title','Edited by member'))::text));
  perform pg_temp.note('edit applied',(select title from public.tasks where id=tteam)='Edited by member',(select title from public.tasks where id=tteam));
  perform pg_temp.vis('peer sees the edited task','peer','tasks',tteam,1);
  foreach who in array array['outsider','guest'] loop
   perform pg_temp.call(who||' edit of team task refused',who,format('select public.taskfold_edit_team_task(%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Pteam,'task_id',tteam,'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=tteam),'base',jsonb_build_object('title','Edited by member','task_generation',(select task_generation from public.tasks where id=tteam),'project_id',Pteam),'changes',jsonb_build_object('title','Hijack'))::text),'err');
  end loop;
  perform pg_temp.call('guest with viewer grant cannot edit granted private task','guest',format('select public.taskfold_edit_team_task(%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Ppriv,'task_id',tpriv,'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=tpriv),'base',jsonb_build_object('title','QA private task','task_generation',(select task_generation from public.tasks where id=tpriv),'project_id',Ppriv),'changes',jsonb_build_object('title','Hijack'))::text),'err');
  perform pg_temp.call('member cannot edit private task without grant','member',format('select public.taskfold_edit_team_task(%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Ppriv,'task_id',tpriv,'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=tpriv),'base',jsonb_build_object('title','QA private task','task_generation',(select task_generation from public.tasks where id=tpriv),'project_id',Ppriv),'changes',jsonb_build_object('title','Hijack'))::text),'err');
  perform pg_temp.call('cross-team: T member cannot edit T2 task','member',format('select public.taskfold_edit_team_task(%L::jsonb)',jsonb_build_object('team_id',T,'project_id',P2,'task_id',tk2,'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=tk2),'base',jsonb_build_object('title','QA foreign task','task_generation',(select task_generation from public.tasks where id=tk2),'project_id',P2),'changes',jsonb_build_object('title','Hijack'))::text),'err');
  perform pg_temp.call('outsider cannot edit own-team task via T scope','outsider',format('select public.taskfold_edit_team_task(%L::jsonb)',jsonb_build_object('team_id',T2,'project_id',Pteam,'task_id',tteam,'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=tteam),'base',jsonb_build_object('title','Edited by member','task_generation',(select task_generation from public.tasks where id=tteam),'project_id',Pteam),'changes',jsonb_build_object('title','Hijack'))::text),'err');
  perform pg_temp.note('no refused edit changed anything',(select title from public.tasks where id=tpriv)='QA private task' and (select title from public.tasks where id=tk2)='QA foreign task' and (select title from public.tasks where id=tteam)='Edited by member');
  perform pg_temp.call('member reviews a move','member',format('select public.taskfold_team_task_move(''review'',%L::jsonb)',jsonb_build_object('team_id',T,'task_id',tteam,'task_generation',(select task_generation from public.tasks where id=tteam),'source_project_id',Pteam,'destination_project_id',Pdest)::text));
  rv:=pg_temp.lv();
  perform pg_temp.call('outsider cannot review the same move','outsider',format('select public.taskfold_team_task_move(''review'',%L::jsonb)',jsonb_build_object('team_id',T,'task_id',tteam,'task_generation',(select task_generation from public.tasks where id=tteam),'source_project_id',Pteam,'destination_project_id',Pdest)::text),'err');
  perform pg_temp.call('guest cannot review a move','guest',format('select public.taskfold_team_task_move(''review'',%L::jsonb)',jsonb_build_object('team_id',T,'task_id',tteam,'task_generation',(select task_generation from public.tasks where id=tteam),'source_project_id',Pteam,'destination_project_id',Pdest)::text),'err');
  perform pg_temp.call('cross-team destination refused','member',format('select public.taskfold_team_task_move(''review'',%L::jsonb)',jsonb_build_object('team_id',T,'task_id',tteam,'task_generation',(select task_generation from public.tasks where id=tteam),'source_project_id',Pteam,'destination_project_id',P2)::text),'err');
  perform pg_temp.call('outsider cannot execute member review proof','outsider',format('select public.taskfold_team_task_move(''move'',%L::jsonb)',jsonb_build_object('team_id',T,'task_id',tteam,'task_generation',(select task_generation from public.tasks where id=tteam),'source_project_id',Pteam,'destination_project_id',Pdest,'request_id',gen_random_uuid(),'expires_at',rv->>'expires_at','review_token',rv->>'review_token')::text),'err');
  perform pg_temp.note('refused move left task in place',(select project_id from public.tasks where id=tteam)=Pteam);
  perform pg_temp.call('member moves task to destination','member',format('select public.taskfold_team_task_move(''move'',%L::jsonb)',jsonb_build_object('team_id',T,'task_id',tteam,'task_generation',(select task_generation from public.tasks where id=tteam),'source_project_id',Pteam,'destination_project_id',Pdest,'request_id',gen_random_uuid(),'expires_at',rv->>'expires_at','review_token',rv->>'review_token')::text));
  perform pg_temp.note('task now in destination',(select project_id from public.tasks where id=tteam)=Pdest);
  perform pg_temp.vis('outsider cannot see moved task','outsider','tasks',tteam,0);
  perform pg_temp.vis('peer sees moved task','peer','tasks',tteam,1);
 end if;

 ---------------- S4 project adoption ----------------
 insert into public.projects(id,user_id,name) values (PP,pg_temp.pid('owner'),'QA personal project to adopt');
 insert into public.tasks(id,user_id,project_id,title) values (tpp,pg_temp.pid('owner'),PP,'QA personal task');
 b:=jsonb_build_object('team_id',T,'roots',jsonb_build_array(PP),'visibility','team','folder_id',null,'parent_id',null);
 if not c_adopt then
  perform pg_temp.call('closed: owner inspect (read-only) outcome','owner',format('select public.taskfold_team_project_adoption(''inspect'',%L::jsonb)',b::text),'any');
  insp:=pg_temp.lv();
  b:=b||jsonb_build_object('inspection_token',coalesce(insp->>'inspection_token',repeat('0',64)),'decisions','[]'::jsonb);
  perform pg_temp.call('closed: review outcome','owner',format('select public.taskfold_team_project_adoption(''review'',%L::jsonb)',b::text),'any');
  reviewed:=pg_temp.lv();
  perform pg_temp.call('closed: adopt refused','owner',format('select public.taskfold_team_project_adoption(''adopt'',%L::jsonb)',(b||jsonb_build_object('review_token',coalesce(reviewed->>'review_token',repeat('0',64)),'expires_at',coalesce(reviewed->>'expires_at',to_char(clock_timestamp() + interval '5 minutes','YYYY-MM-DD"T"HH24:MI:SS"Z"')),'request_id',gen_random_uuid()))::text),'err');
  perform pg_temp.note('closed: project still personal',not exists(select 1 from taskfold_private.team_content_projects where project_id=PP));
  perform pg_temp.vis('personal project untouched','owner','projects',PP,1);
 else
  perform pg_temp.call('owner inspects personal project','owner',format('select public.taskfold_team_project_adoption(''inspect'',%L::jsonb)',b::text));
  insp:=pg_temp.lv();
  perform pg_temp.call('outsider cannot inspect owners project','outsider',format('select public.taskfold_team_project_adoption(''inspect'',%L::jsonb)',b::text),'err');
  b:=b||jsonb_build_object('inspection_token',insp->>'inspection_token','decisions','[]'::jsonb);
  perform pg_temp.call('owner reviews adoption','owner',format('select public.taskfold_team_project_adoption(''review'',%L::jsonb)',b::text));
  reviewed:=pg_temp.lv();
  perform pg_temp.call('adoption without review proof refused','owner',format('select public.taskfold_team_project_adoption(''adopt'',%L::jsonb)',b::text),'err');
  perform pg_temp.call('owner adopts project into team','owner',format('select public.taskfold_team_project_adoption(''adopt'',%L::jsonb)',(b||jsonb_build_object('review_token',reviewed->>'review_token','expires_at',reviewed->>'expires_at','request_id',gen_random_uuid()))::text));
  perform pg_temp.note('project bound to team',exists(select 1 from taskfold_private.team_content_projects where project_id=PP and team_id=T));
  perform pg_temp.vis('member sees adopted project','member','projects',PP,1);
  perform pg_temp.vis('member sees adopted task','member','tasks',tpp,1);
  perform pg_temp.vis('outsider cannot see adopted project','outsider','projects',PP,0);
  perform pg_temp.vis('outsider cannot see adopted task','outsider','tasks',tpp,0);
  perform pg_temp.vis('guest cannot see adopted project (no grant)','guest','projects',PP,0);
 end if;

 ---------------- S5 task types ----------------
 perform pg_temp.eq('boundary task_types_protocol follows switch','owner','select to_jsonb(coalesce((public.taskfold_workspace_boundary()->>''task_types_protocol'')::int,-1))',to_jsonb(case when c_types and c_edits and c_reads then 1 else 0 end));

 ---------------- S6 templates ----------------
 if not c_tpl then
  perform pg_temp.call('closed: owner publish refused','owner',format('select public.taskfold_team_templates(''publish'',%L::jsonb)',jsonb_build_object('team_id',T,'template_id',tmpl,'request_id',gen_random_uuid(),'name','QA template','document',jsonb_build_object('version',1,'tasks','[]'::jsonb))::text),'PT503');
  perform pg_temp.call('closed: member list refused','member',format('select public.taskfold_team_templates(''list'',%L::jsonb)',jsonb_build_object('team_id',T)::text),'PT503');
 else
  perform pg_temp.call('owner publishes template','owner',format('select public.taskfold_team_templates(''publish'',%L::jsonb)',jsonb_build_object('team_id',T,'template_id',tmpl,'request_id',gen_random_uuid(),'name','QA template','document',jsonb_build_object('version',1,'tasks','[]'::jsonb))::text));
  perform pg_temp.call('member cannot publish','member',format('select public.taskfold_team_templates(''publish'',%L::jsonb)',jsonb_build_object('team_id',T,'template_id',gen_random_uuid(),'request_id',gen_random_uuid(),'name','Nope','document',jsonb_build_object('version',1))::text),'42501');
  perform pg_temp.eq('member lists 1 template','member',format('select to_jsonb(jsonb_array_length(public.taskfold_team_templates(''list'',%L::jsonb)->''items''))',jsonb_build_object('team_id',T)::text),'1'::jsonb);
  perform pg_temp.call('member reads template','member',format('select public.taskfold_team_templates(''get'',%L::jsonb)',jsonb_build_object('team_id',T,'template_id',tmpl)::text));
  perform pg_temp.call('guest cannot list templates','guest',format('select public.taskfold_team_templates(''list'',%L::jsonb)',jsonb_build_object('team_id',T)::text),'PT404');
  perform pg_temp.call('outsider cannot list templates','outsider',format('select public.taskfold_team_templates(''list'',%L::jsonb)',jsonb_build_object('team_id',T)::text),'PT404');
  perform pg_temp.call('outsider cannot read template by id','outsider',format('select public.taskfold_team_templates(''get'',%L::jsonb)',jsonb_build_object('team_id',T,'template_id',tmpl)::text),'PT404');
  perform pg_temp.call('owner deletes template','owner',format('select public.taskfold_team_templates(''delete'',%L::jsonb)',jsonb_build_object('team_id',T,'template_id',tmpl,'request_id',gen_random_uuid(),'revision',1)::text));
 end if;

 ---------------- S1b role change and removal revoke access ----------------
 perform pg_temp.vis('before demotion member sees team project','member','projects',Pteam,1);
 perform pg_temp.org('owner demotes member to guest','owner','change_role',T,jsonb_build_object('user_id',pg_temp.pid('member'),'role','guest'));
 perform pg_temp.vis('demoted guest loses team project','member','projects',Pteam,0);
 perform pg_temp.vis('demoted guest loses team task','member','tasks',tdest,0);
 if c_edits then
  perform pg_temp.call('demoted guest cannot edit','member',format('select public.taskfold_edit_team_task(%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Pdest,'task_id',tdest,'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=tdest),'base',jsonb_build_object('title','QA dest task','task_generation',(select task_generation from public.tasks where id=tdest),'project_id',Pdest),'changes',jsonb_build_object('title','Hijack'))::text),'err');
 end if;
 perform pg_temp.org('owner restores member role','owner','change_role',T,jsonb_build_object('user_id',pg_temp.pid('member'),'role','member'));
 perform pg_temp.vis('restored member sees project again','member','projects',Pteam,1);
 perform pg_temp.org('owner removes member','owner','remove_member',T,jsonb_build_object('user_id',pg_temp.pid('member')));
 perform pg_temp.getteam('removed member cannot get team','member',T,'PT404');
 perform pg_temp.eq('removed member list empty','member','select (public.taskfold_teams(''list'',''{}''::jsonb))->''teams''','[]'::jsonb);
 perform pg_temp.vis('removed member loses team project','member','projects',Pteam,0);
 perform pg_temp.vis('removed member loses moved task','member','tasks',tteam,0);
 perform pg_temp.vis('removed member loses own RPC-created project','member','projects',Prpc,0);
 if c_edits then
  perform pg_temp.call('removed member cannot edit','member',format('select public.taskfold_edit_team_task(%L::jsonb)',jsonb_build_object('team_id',T,'project_id',Pdest,'task_id',tteam,'request_id',gen_random_uuid(),'task_generation',(select task_generation from public.tasks where id=tteam),'base',jsonb_build_object('title','Edited by member','task_generation',(select task_generation from public.tasks where id=tteam),'project_id',Pdest),'changes',jsonb_build_object('title','Hijack'))::text),'err');
 end if;
 perform pg_temp.org('admin leaves','admin','leave',T,'{}');
 perform pg_temp.vis('left admin loses team project','admin','projects',Pteam,0);
 perform pg_temp.org('owner removes peer (project creator)','owner','remove_member',T,jsonb_build_object('user_id',pg_temp.pid('peer')));
 perform pg_temp.vis('removed creator loses own created project','peer','projects',Pteam,0);
 perform pg_temp.vis('removed creator loses own created task','peer','tasks',tdest,0);
 perform pg_temp.org('owner deletes team','owner','delete',T,'{}');
 perform pg_temp.getteam('deleted team unavailable','owner',T,'PT404');
 perform pg_temp.vis('after deletion owner sees no team project','owner','projects',Pteam,0);
end$do$;
select jsonb_build_object('passed',count(*) filter (where ok),'failed',count(*) filter (where not ok),'total',count(*),
 'verdict',case when count(*) filter (where not ok)=0 then 'CHECK_OK' else 'CHECK_FAILED' end,
 'failures',coalesce(jsonb_agg(jsonb_build_object('n',n,'label',label,'detail',detail) order by n) filter (where not ok),'[]'),
 'info',coalesce(jsonb_agg(detail order by n) filter (where label in ('config','boundary keys (info)')),'[]')) as result from acc;
rollback;
