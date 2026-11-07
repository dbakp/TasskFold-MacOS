// Genuine, isolated Auth/PostgREST; no production account, release flag or task.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
const output=process.argv[2];assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));
const report={checks:{},hostedChanges:false,normalUseGatesChanged:false};let runtime;
const lit=x=>"'"+String(x).replaceAll("'","''")+"'";
const check=(name,value)=>{assert.equal(value,true,name);report.checks[name]=true;console.log('passed',name)};
const ok=(name,r,status=200)=>{if(r.status!==status)report.lastFailure={name,status:r.status,code:r.value?.code,message:r.value?.message};check(name,r.status===status);return r.value};
try{
 runtime=await createFullSchemaRuntime();report.migrations=runtime.migrations;report.images=runtime.images;
 const owner=ok('genuine owner signup',await runtime.request('auth','/signup',{method:'POST',body:{email:'archive-owner-'+randomUUID()+'@example.invalid',password:randomUUID()+'Aa42!'}}));
 const outsider=ok('genuine outsider signup',await runtime.request('auth','/signup',{method:'POST',body:{email:'archive-outsider-'+randomUUID()+'@example.invalid',password:randomUUID()+'Aa42!'}}));
 const account=owner.user.id,authorization=owner.access_token;
 const api=(path,body,token=authorization)=>runtime.request('rest',path,{authorization:token,method:'POST',body});
 const project=randomUUID();ok('genuine project creation',await api('/projects',{id:project,user_id:account,name:'Original recovery workshop'}),201);
 await runtime.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true,adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true');
 const saved=[];
 for(let i=0;i<3;i++){
  const task=ok('create repair source '+i,await runtime.request('rest','/tasks',{authorization,method:'POST',headers:{Prefer:'return=representation'},body:{id:randomUUID(),user_id:account,project_id:project,title:'Private repair original '+i,description:'Keep every detail',subtasks:[{id:randomUUID(),title:'Parent',subtasks:['Legacy text '+i],future:{precise:'Keep this string'}}]}}),201)[0];
  const review=ok('review repair source '+i,await api('/rpc/taskfold_review_child_adoption',{_id:task.id,_generation:task.task_generation}));
  const b=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,review[k]]));
  b.changes=[{kind:'wrap_item',path:[0,0],reference:randomUUID(),title:'Recovered child '+i}];
  const preview=ok('preview repair '+i,await api('/rpc/taskfold_preview_child_repair',{_body:b}));
  const command={...b,request_id:randomUUID(),repair_digest:preview.repair_digest};
  const receipt=ok('save real repair '+i,await api('/rpc/taskfold_repair_children',{_operation:'send',_body:command}));check('repair applied '+i,receipt.state==='applied');
  const original=await api('/rpc/taskfold_repair_children',{_operation:'original',_body:command});ok('original old route '+i,original);
  saved.push({task,command,receipt,original});
 }

 const cleanup=(r,operation='review',token=authorization,extra={})=>api('/rpc/taskfold_child_repair_original_cleanup',{_operation:operation,_request:r.request_id,_archive:r.archive_id,_digest:r.archive_digest,_bytes:r.archive_bytes,...extra},token);
 const stored=async()=>JSON.parse(await runtime.raw("select jsonb_build_object('tasks',(select jsonb_agg(to_jsonb(t) order by id) from public.tasks t),'repairs',(select jsonb_agg(to_jsonb(r) order by request_id) from taskfold_private.child_task_repairs r),'originals',(select jsonb_agg(to_jsonb(o) order by id) from taskfold_private.child_task_repair_originals o),'records',(select jsonb_agg(to_jsonb(r) order by task_id,node_key) from taskfold_private.child_task_records r),'child_history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_node_activity h),'root_history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_activity h))::text"));
 const r=saved[0].receipt,before=await stored();
 const paused=ok('review while cleanup disabled',await cleanup(r));check('disabled review is retained and paused',paused.state==='retained'&&paused.cleanup_enabled===false);
 ok('disabled remove refused',await cleanup(r,'remove'),503);check('paused cleanup preserved every row',JSON.stringify(await stored())===JSON.stringify(before));
 for(const [name,extra,status] of [['wrong digest',{_digest:'a'.repeat(64)},409],['wrong byte count',{_bytes:r.archive_bytes+1},409],['swapped archive',{_archive:saved[1].receipt.archive_id},403],['null request',{_request:null},400],['null bytes',{_bytes:null},400],['oversized bytes',{_bytes:8000001},400],['unknown operation',{_operation:'restore'},400]])ok(name,await cleanup(r,'remove',authorization,extra),status);
 ok('foreign account refused',await cleanup(r,'remove',outsider.access_token),403);
 check('all invalid requests preserved work',JSON.stringify(await stored())===JSON.stringify(before));
 await runtime.raw('update taskfold_private.child_task_record_config set archive_cleanup_enabled=true,repair_writes_enabled=false');
 const review=ok('enabled exact review',await cleanup(r));check('review binds only exact metadata',Object.keys(review).sort().join(',')==='account,archive_bytes,archive_digest,archive_id,cleanup_enabled,protocol,request_id,state'&&review.archive_id===r.archive_id&&review.archive_digest===r.archive_digest&&review.archive_bytes===r.archive_bytes&&review.account===account&&review.cleanup_enabled);
 check('review never removes data',JSON.stringify(await stored())===JSON.stringify(before));
 ok('remove selected original',await cleanup(r,'remove'));const after=await stored();const expected={...before,originals:before.originals.filter(o=>o.id!==r.archive_id)};
 check('only selected original removed',JSON.stringify(after)===JSON.stringify(expected));
 check('stored charge removed exactly once',before.originals.reduce((n,x)=>n+x.bytes,0)-after.originals.reduce((n,x)=>n+x.bytes,0)===r.archive_bytes);
 await runtime.raw('update taskfold_private.child_task_record_config set archive_cleanup_enabled=false');
 const replay=ok('lost reply retry after pause',await cleanup(r,'remove'));check('replay confirms unavailable',replay.state==='unavailable'&&!replay.cleanup_enabled);check('replay never removes another copy',JSON.stringify(await stored())===JSON.stringify(after));
 const discovery=ok('discovery after cleanup',await api('/rpc/taskfold_child_repair_archives',{_after:null,_limit:50}));check('receipt retained with unavailable original',discovery.entries.find(e=>e.receipt.archive_id===r.archive_id)?.content_retained===false&&discovery.entries.length===3);
 ok('removed copy cannot export',await api('/rpc/taskfold_child_repair_original',{_request:r.request_id,_archive:r.archive_id}),403);
 // A personal original follows its storage owner, including after its root is gone.
 const orphan=saved[1];await runtime.raw(`delete from public.tasks where id=${lit(orphan.task.id)};update taskfold_private.child_task_record_config set archive_cleanup_enabled=true`);
 const orphanBefore=await stored();ok('remove owned orphan original',await cleanup(orphan.receipt,'remove'));check('orphan cleanup preserves current work and receipts',JSON.stringify(await stored())===JSON.stringify({...orphanBefore,originals:orphanBefore.originals.filter(o=>o.id!==orphan.receipt.archive_id)}));
 const third=saved[2];await runtime.raw(`update taskfold_private.child_task_repair_originals set owner_id=${lit(outsider.user.id)} where id=${lit(third.receipt.archive_id)}`);
 const foreignCustody=await stored();ok('personal storage owner required',await cleanup(third.receipt,'remove'),403);check('foreign custody unchanged',JSON.stringify(await stored())===JSON.stringify(foreignCustody));
 await runtime.raw(`update taskfold_private.child_task_repair_originals set owner_id=${lit(account)} where id=${lit(third.receipt.archive_id)}`);
 // Genuine repair under a seeded team boundary; token belongs to an accepted admin.
 const team=randomUUID(),tp=randomUUID(),tid=randomUUID(),gen=randomUUID();
 await runtime.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(outsider.user.id)},'Cleanup workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(outsider.user.id)},'admin'),(${lit(team)},${lit(account)},'admin');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_task_types_enabled=true;update taskfold_private.child_task_record_config set adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true,reads_enabled=true,edits_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true;insert into public.projects(id,user_id,name) values(${lit(tp)},${lit(outsider.user.id)},'Team originals');insert into taskfold_private.team_content_projects(project_id,team_id,visibility) values(${lit(tp)},${lit(team)},'private');insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(${lit(tp)},${lit(team)},${lit(account)},'editor');insert into public.tasks(id,task_generation,user_id,project_id,title,subtasks) values(${lit(tid)},${lit(gen)},${lit(outsider.user.id)},${lit(tp)},'Keep the team root','["Legacy team instruction"]')`);
 const tr=ok('review genuine shared root',await api('/rpc/taskfold_review_child_adoption',{_id:tid,_generation:gen}));const body=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,tr[k]]));body.changes=[{kind:'wrap_item',path:[0],reference:randomUUID(),title:'Team instruction'}];
 const pv=ok('preview genuine shared repair',await api('/rpc/taskfold_preview_child_repair',{_body:body}));const command={...body,request_id:randomUUID(),repair_digest:pv.repair_digest};const teamReceipt=ok('save genuine shared repair',await api('/rpc/taskfold_repair_children',{_operation:'send',_body:command}));check('shared repair archive is real',teamReceipt.state==='applied'&&teamReceipt.workspace_id===team);
 ok('accepted admin can review own team original',await cleanup(teamReceipt));
 await runtime.raw(`update taskfold_private.team_members set role='member' where team_id=${lit(team)} and user_id=${lit(account)}`);const demoted=await stored();ok('ordinary editor cannot remove team original',await cleanup(teamReceipt,'remove'),403);check('demotion preserved archived content',JSON.stringify(await stored())===JSON.stringify(demoted));
 await runtime.raw(`delete from taskfold_private.team_members where team_id=${lit(team)} and user_id=${lit(account)}`);ok('departed actor cannot remove team original',await cleanup(teamReceipt,'remove'),403);
 await runtime.raw(`insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(account)},'admin');update taskfold_private.team_config set enabled=false;update taskfold_private.team_project_config set native_reads_enabled=false,native_task_edits_enabled=false,native_task_types_enabled=false;update taskfold_private.child_task_record_config set repair_writes_enabled=false`);
 const teamBefore=await stored();ok('admin cleanup independent of paused task authoring',await cleanup(teamReceipt,'remove'));check('team cleanup changes only selected archive',JSON.stringify(await stored())===JSON.stringify({...teamBefore,originals:teamBefore.originals.filter(o=>o.id!==teamReceipt.archive_id)}));
 await runtime.raw(`delete from auth.sessions where user_id=${lit(account)}`);const expired=await cleanup(third.receipt,'remove');check('expired session refused',expired.status>=400&&expired.value?.code==='28000');
 check('public endpoint is invoker',await runtime.raw("select not prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='taskfold_child_repair_original_cleanup'")==='t');
 check('anonymous cannot execute cleanup',await runtime.raw("select not has_function_privilege('anon','public.taskfold_child_repair_original_cleanup(text,uuid,uuid,text,integer)','EXECUTE')")==='t');
 check('no direct original delete grant',await runtime.raw("select not has_table_privilege('authenticated','taskfold_private.child_task_repair_originals','DELETE')")==='t');
 report.fixture={entry:discovery.entries.find(e=>e.receipt.archive_id===r.archive_id),review,removed:replay};report.advisors=await runtime.advisors();report.passed=true;
}catch(e){report.failure={message:e.message,migration:e.migration};process.exitCode=1;}finally{if(runtime)report.cleanup=await runtime.close();await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:report.passed??false,checks:Object.keys(report.checks).length,failure:report.failure,lastFailure:report.lastFailure,cleanup:report.cleanup}));}
