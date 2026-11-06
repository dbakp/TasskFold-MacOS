// Owned synthetic PostgreSQL only. Exercise the real reviewed adoption API.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadProjectAdoptionSchema} from './project-adoption-schema.mjs';
const migration='20261026121332_task_node_project_adoption_review.sql';
const report={checks:{},hostedChanges:false,realUserDataChanged:false};
const check=(name,a,b=true)=>{assert.deepEqual(a,b,name);report.checks[name]=true};
const json=x=>lit(JSON.stringify(x))+'::jsonb',owner=randomUUID(),member=randomUUID(),actor=randomUUID(),team=randomUUID(),session=randomUUID();
const source=async file=>readFile(new URL('../../'+file,import.meta.url),'utf8');
const sql=await source('supabase/migrations/'+migration);
function definition(text,name){const starts=[...text.matchAll(new RegExp('create (?:or replace )?function taskfold_private\\.'+name+'\\(','g'))];assert.equal(starts.length,1);const start=starts[0].index,end=text.indexOf('$$;',text.indexOf('as $$',start))+3;return text.slice(start,end).replace('create or replace function','create function');}
for(const [name,file] of [['capture_project_realm_write','20261025011154_team_project_ownership_fences.sql'],['project_adoption_people','20261025031915_team_project_adoption_connection_fences.sql'],['project_adoption_contents','20261025033903_team_project_adoption_connection_policy.sql'],['project_adoption_review','20261025033903_team_project_adoption_connection_policy.sql']]) {
 let actual=definition(sql,name).split('\n').filter(l=>!l.includes('public.task_node_activity')&&!l.includes("('task_node_activity',")).join('\n');
 actual=actual.replace("elsif tg_table_name in('task_activity','task_node_activity') then","elsif tg_table_name='task_activity' then").replace("'child_history_protocol',1,",'').replace("'to_jsonb(x)'),\n ) v(rel", "'to_jsonb(x)')\n ) v(rel");
 check('preserved existing '+name,actual,definition(await source('supabase/migrations/'+file),name));
}
report.migrationSHA256=createHash('sha256').update(sql).digest('hex');let pg,step='load';
try {
 pg=await createPostgresFixture({advisors:true});await loadProjectAdoptionSchema(pg.raw,{nodes:false});
 await pg.raw('alter table public.tasks add column is_heading boolean');
 for(const file of ['20261026095807_task_node_activity_history.sql','20261026104450_task_activity_root_context.sql','20261026113556_task_node_activity_custody.sql'])await pg.raw(await source('supabase/migrations/'+file));
 for(const id of [owner,member,actor])await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(id)},${lit(id+'@example.invalid')},now());insert into public.profiles(user_id) values(${lit(id)})`);
 await pg.raw(`insert into auth.sessions(id,user_id) values(${lit(session)},${lit(owner)});insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(member)},'Synthetic studio');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner)},'member'),(${lit(team)},${lit(member)},'admin');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_project_adoption_enabled=true`);
 const identity=`set local request.jwt.claim.sub=${lit(owner)};set local request.jwt.claims=${lit(JSON.stringify({sub:owner,session_id:session}))};`;
 const call=(op,b)=>pg.scalar(`begin;${identity}set local role authenticated;select public.taskfold_team_project_adoption(${lit(op)},${json(b)});commit`);
 const expect=async(name,fn,code)=>{try{await fn();assert.fail(name+' unexpectedly succeeded')}catch(e){check(name,e.code,code)}};
 const project=async()=>{const p=randomUUID();await pg.raw(`insert into public.projects(id,user_id,name) values(${lit(p)},${lit(owner)},'Synthetic project')`);return p};
 const p=await project(),elsewhere=await project(),root=randomUUID(),node=randomUUID(),deleted=randomUUID();
 const tree=done=>[{id:node,title:'Private child title',completed:done,...(done?{completed_at:new Date().toISOString()}:{}),subtasks:[]}];
 await pg.raw(`begin;${identity}insert into public.tasks(id,user_id,project_id,title,is_heading,subtasks) values(${lit(root)},${lit(owner)},${lit(p)},'Private heading title',true,${json(tree(false))}),(${lit(deleted)},${lit(owner)},${lit(p)},'Deleted heading',true,${json(tree(false))});update public.tasks set subtasks=${json(tree(true))} where id=${lit(root)};delete from public.tasks where id=${lit(deleted)};commit`);
 const base={team_id:team,roots:[p],visibility:'private',folder_id:null,parent_id:null};
 const ledger=()=>pg.scalar(`select coalesce(jsonb_agg(to_jsonb(x) order by sequence),'[]') from public.task_node_activity x`);
 step='upgrade';const legacyInspection=await call('inspect',base),legacyReview=await call('review',{...base,inspection_token:legacyInspection.inspection_token,decisions:[]}),beforeUpgrade=await ledger();
 check('old inspection has no child contract',legacyInspection.child_history_protocol===undefined&&legacyInspection.contents.counts.task_node_activity===undefined);
 await pg.raw('begin;'+sql+';commit');check('upgrade preserves existing child history',await ledger(),beforeUpgrade);
 await expect('old inspection cannot approve unreviewed history',()=>call('review',{...base,inspection_token:legacyInspection.inspection_token,decisions:[]}),'PT409');
 await expect('old saved command cannot transfer unreviewed history',()=>call('adopt',{...base,inspection_token:legacyReview.inspection_token,decisions:[],review_token:legacyReview.review_token,expires_at:legacyReview.expires_at,request_id:randomUUID()}),'PT409');
 let inspected=await call('inspect',base);step='review';
 check('explicit child history protocol',inspected.child_history_protocol,1);
 check('child counts include existing and deleted roots',inspected.contents.counts.task_node_activity,(await ledger()).length);
 check('child count is nonzero',inspected.contents.counts.task_node_activity>0);
 check('all nine bounded content categories included',Object.keys(inspected.contents.counts).length,9);
 check('review hides child titles',!JSON.stringify(inspected).includes('Private child title'));
 check('review hides heading titles',!JSON.stringify(inspected).includes('Private heading title'));
 check('no history bodies or hashes exposed',!JSON.stringify(inspected).includes('before_state')&&!JSON.stringify(inspected.contents).includes('hashes'));
 const fresh=async()=>{const i=await call('inspect',base);return call('review',{...base,inspection_token:i.inspection_token,decisions:[]})};
 const rows=await ledger(),event=rows.find(e=>e.task_id===deleted),eid=event.id;
 // A node-only change leaves the live task untouched, but must change the proof.
 await pg.raw(`update public.task_node_activity set actor_id=${lit(actor)} where id=${lit(eid)}`);
 await expect('child-only edit invalidates prior inspection',()=>call('review',{...base,inspection_token:inspected.inspection_token,decisions:[]}),'PT409');
 inspected=await call('inspect',base);
 check('child-only actor participates in locked cohort',(await pg.scalar(`select to_jsonb(taskfold_private.project_adoption_people(array[${lit(p)}::uuid],${lit(team)}))`)).includes(actor));
 const authHold=await pg.hold(`update auth.users set banned_until=now()+interval '1 day' where id=${lit(actor)}`);
 try {await expect('child participant lock uses existing bounded timeout',()=>call('inspect',base),'55P03')}finally{await authHold.release('rollback')}
 // Same bytes restored must still invalidate via the new per-row epoch trigger.
 await pg.raw(`update public.task_node_activity set actor_id=null where id=${lit(eid)};update public.task_node_activity set actor_id=${lit(actor)} where id=${lit(eid)}`);
 await expect('child edit revert invalidates proof',()=>call('review',{...base,inspection_token:inspected.inspection_token,decisions:[]}),'PT409');
 const epoch=await pg.scalar(`select revision from taskfold_private.project_content_epochs where table_name='task_node_activity' and row_id=${lit(eid)}`);check('child monotonic epoch captured',epoch>=3);
 const historyHold=await pg.hold(`update public.task_node_activity set actor_id=null where id=${lit(eid)}`);
 try{await expect('busy child row refuses without deadlock',()=>call('inspect',base),'PT409')}finally{await historyHold.release('rollback')}
 // A scope-only historic record must remain included after its live root moves.
 await pg.raw(`update public.tasks set project_id=${lit(elsewhere)} where id=${lit(root)}`);
 inspected=await call('inspect',base);check('state-only history included after live root moves',inspected.contents.counts.task_node_activity>0);
 const expected=await pg.scalar(`select count(*) from public.task_node_activity x where exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=${lit(p)}) or x.before_state->>'project_id'=${lit(p)} or x.after_state->>'project_id'=${lit(p)}`);check('historic rows counted once',inspected.contents.counts.task_node_activity,expected);
 // The adoption fence must also cover direct node writes, including deleted roots.
 const fence=await pg.hold(`select pg_advisory_xact_lock(hashtextextended('project-realm:'||${lit(p)},20261025))`);
 try{await expect('child write cannot commit through ownership fence',()=>pg.raw(`update public.task_node_activity set actor_id=null where id=${lit(eid)}`),'PT409')}finally{await fence.release('rollback')}
 step='commit';const reviewed=await fresh(),before=await ledger();
 const command={...base,inspection_token:reviewed.inspection_token,decisions:[],review_token:reviewed.review_token,expires_at:reviewed.expires_at,request_id:randomUUID()};
 // New child rows appearing after review must make the saved command stale.
 const replacement=randomUUID();await pg.raw(`insert into public.tasks(id,user_id,project_id,title,is_heading,subtasks) values(${lit(replacement)},${lit(owner)},${lit(p)},'New group',true,${json(tree(false))})`);
 await expect('new child history invalidates saved commit',()=>call('adopt',command),'PT409');
 check('stale transfer has no custody side effects',await pg.scalar(`select count(*) from taskfold_private.team_project_identities where project_id=${lit(p)}`),0);
 const finalReview=await fresh(),finalCommand={...command,inspection_token:finalReview.inspection_token,review_token:finalReview.review_token,expires_at:finalReview.expires_at,request_id:randomUUID()},finalBefore=await ledger();
 const receipt=await call('adopt',finalCommand);check('reviewed child transfer succeeds',receipt.applied);check('receipt retry preserved',(await call('adopt',finalCommand)).replayed);
 check('transfer preserves recorded children byte for byte',await ledger(),finalBefore);
 report.historicalCustodyObservation=await pg.scalar(`select jsonb_build_object('deleted_root_registered',taskfold_private.is_team_content_task(${lit(deleted)}),'moved_outside_root_registered',taskfold_private.is_team_content_task(${lit(root)}),'current_selected_root_registered',taskfold_private.is_team_content_task(${lit(replacement)}))`);
 report.remainingLimitations=['The existing adoption registry binds current task roots only. History-only/deleted roots and prior project intervals still need event-level custody and retention acceptance before rollout.'];
 check('no private authority left',await pg.scalar('select count(*) from taskfold_private.team_project_adoption_scope'),0);
 for(const role of ['authenticated','anon','service_role'])check('private child transfer helpers closed to '+role,await pg.scalar(`select to_json(has_function_privilege(${lit(role)},'taskfold_private.project_adoption_contents(uuid[])','EXECUTE'))`),false);
 report.advisors=await pg.advisors();check('official advisors ran',report.advisors.ran);check('no new object advisor finding',report.advisors.result.filter(f=>/task_node_activity|project_adoption|capture_project_realm_write/.test(JSON.stringify(f))),[]);
 console.log('PASS '+Object.keys(report.checks).length+' child adoption checks');
}catch(error){report.failedStep=step;report.error={message:error.message,code:error.code};process.exitCode=1;console.error('FAIL '+step+': '+error.message+' '+(error.code??''))}
finally{if(pg)report.ownedFixtureRemoved=await pg.close();const i=process.argv.indexOf('--report');if(i>=0)await writeFile(process.argv[i+1],JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({checks:Object.keys(report.checks).length,failedStep:report.failedStep,ownedFixtureRemoved:report.ownedFixtureRemoved}))}
