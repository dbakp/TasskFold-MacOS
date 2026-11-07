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
 const sorted=[...saved].sort((a,b)=>a.command.request_id.localeCompare(b.command.request_id));
 const page=async(after=null,limit=50,token=authorization)=>api('/rpc/taskfold_child_repair_archives',{_after:after,_limit:limit},token);
 const fetchOriginal=(r,token=authorization)=>runtime.request('rest','/rpc/taskfold_child_repair_original',{authorization:token,method:'POST',body:{_request:r.request_id,_archive:r.archive_id},includeText:true});
 const compare=(r,token=authorization)=>runtime.request('rest','/rpc/taskfold_compare_child_repair_original',{authorization:token,method:'POST',body:{_request:r.request_id,_archive:r.archive_id},includeText:true});
 let cursor=null;const loaded=[];
 for(let i=0;i<3;i++){
  const p=ok('read keyset page '+i,await page(cursor,1));check('page account '+i,p.account===account&&p.protocol===1);check('one bounded entry '+i,p.entries.length===1);
  const entry=p.entries[0];check('stable UUID order '+i,entry.receipt.request_id===sorted[i].command.request_id);check('receipt matches immutable send '+i,JSON.stringify(entry.receipt)===JSON.stringify(sorted[i].receipt));
  check('content retained '+i,entry.content_retained===true);check('current readable title '+i,entry.current_title===sorted[i].task.title&&entry.title_truncated===false);check('discovery excludes archived source '+i,!JSON.stringify(p).includes('Legacy text'));
  loaded.push(entry);cursor=p.next;check('cursor contract '+i,i===2?cursor===null:cursor===entry.receipt.request_id);
 }
 const originalResponse=await fetchOriginal(loaded[0].receipt);const original=ok('discover original without command',originalResponse);
 check('new route exact canonical content',JSON.stringify(original)===JSON.stringify(sorted[0].original.value));
 report.clientContract={page:ok('capture bounded client page',await page(null,2)),originalReply:original,originalWire:originalResponse.text};
 const allStored=()=>runtime.raw("select jsonb_build_object('tasks',(select jsonb_agg(to_jsonb(t) order by id) from public.tasks t),'records',(select jsonb_agg(to_jsonb(r) order by task_id,node_key) from taskfold_private.child_task_records r),'projections',(select jsonb_agg(to_jsonb(p) order by task_id) from taskfold_private.child_task_projections p),'authority',(select jsonb_agg(to_jsonb(a) order by task_id) from taskfold_private.child_task_record_authority a),'originals',(select jsonb_agg(to_jsonb(o) order by id) from taskfold_private.child_task_repair_originals o),'repairs',(select jsonb_agg(to_jsonb(r) order by request_id) from taskfold_private.child_task_repairs r),'root_history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_activity h),'child_history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_node_activity h))::text");
 const beforeComparison=await allStored(),comparisonResponse=await compare(loaded[0].receipt),comparison=ok('compare genuine repaired source',comparisonResponse);
 check('comparison binds exact export',JSON.stringify(comparison.original)===JSON.stringify(original)&&comparison.account===account&&comparison.protocol===1);
 const actualCurrent=ok('current root for comparison',await runtime.request('rest','/tasks?id=eq.'+loaded[0].receipt.task_id,{authorization}))[0];
 check('comparison uses fresh current structure',JSON.stringify(comparison.current.source_tree)===JSON.stringify(actualCurrent.subtasks)&&comparison.current.task_generation===loaded[0].receipt.task_generation&&comparison.current.project_id===project);
 check('comparison preserves all stored work',await allStored()===beforeComparison);
 report.comparisonClientContract={page:report.clientContract.page,wire:comparisonResponse.text};

 const rawOriginal=await runtime.raw(`select original::text from taskfold_private.child_task_repair_originals where id=${lit(loaded[0].receipt.archive_id)}`);
 report.originalSHA256=createHash('sha256').update(rawOriginal).digest('hex');report.originalBytes=Buffer.byteLength(rawOriginal);
 check('receipt hash binds original bytes',report.originalSHA256===loaded[0].receipt.archive_digest&&report.originalBytes===loaded[0].receipt.archive_bytes);

 // Personal shared projects have two legitimate original custodians: older
 // ordinary repairs store actor custody; mapped repairs can store root-owner custody.
 const collaborator=ok('genuine collaborator signup',await runtime.request('auth','/signup',{method:'POST',body:{email:'archive-collaborator-'+randomUUID()+'@example.invalid',password:randomUUID()+'Aa42!'}}));
 const invite=ok('owner invites actual collaborator',await runtime.request('rest','/project_collaborators',{authorization,method:'POST',headers:{Prefer:'return=representation'},body:{project_id:project,invited_email:collaborator.user.email,role:'collaborator',status:'pending',invited_by:account}}),201)[0];
 ok('recipient accepts actual invitation',await runtime.request('rest','/project_collaborators?id=eq.'+invite.id,{authorization:collaborator.access_token,method:'PATCH',body:{status:'accepted'}}),204);
 const shared=ok('create personally shared repair source',await runtime.request('rest','/tasks',{authorization,method:'POST',headers:{Prefer:'return=representation'},body:{id:randomUUID(),user_id:account,project_id:project,title:'Personal collaboration original',subtasks:[{id:randomUUID(),title:'Parent',subtasks:['Keep shared original']}]}}),201)[0];
 const sharedRead=ok('collaborator current review',await api('/rpc/taskfold_review_child_adoption',{_id:shared.id,_generation:shared.task_generation},collaborator.access_token));
 const sharedBody=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,sharedRead[k]]));sharedBody.changes=[{kind:'wrap_item',path:[0,0],reference:randomUUID(),title:'Reviewed shared child'}];
 const sharedPreview=ok('collaborator repair preview',await api('/rpc/taskfold_preview_child_repair',{_body:sharedBody},collaborator.access_token));
 const sharedCommand={...sharedBody,request_id:randomUUID(),repair_digest:sharedPreview.repair_digest};
 const sharedReceipt=ok('collaborator saves actual repair',await api('/rpc/taskfold_repair_children',{_operation:'send',_body:sharedCommand},collaborator.access_token));
 check('ordinary shared original has actor custody',await runtime.raw(`select owner_id::text from taskfold_private.child_task_repair_originals where id=${lit(sharedReceipt.archive_id)}`)===collaborator.user.id);
 const oldShared=ok('collaborator old original route',await api('/rpc/taskfold_repair_children',{_operation:'original',_body:sharedCommand},collaborator.access_token));
 check('command-free shared original retains old-route parity',JSON.stringify(ok('collaborator discovered original',await fetchOriginal(sharedReceipt,collaborator.access_token)))===JSON.stringify(oldShared));
 check('read access alone cannot export another actors original',(await fetchOriginal(loaded[0].receipt,collaborator.access_token)).status===403);
 const ownShared=ok('collaborator own discovery',await page(null,50,collaborator.access_token));check('collaborator discovers only own repair',ownShared.entries.length===1&&ownShared.entries[0].receipt.archive_id===sharedReceipt.archive_id);
 ok('owner revokes actual collaboration',await runtime.request('rest','/project_collaborators?id=eq.'+invite.id,{authorization,method:'DELETE'}),204);
 check('revoked collaborator cannot export retained original',(await fetchOriginal(sharedReceipt,collaborator.access_token)).status===403);
 const revoked=ok('revoked collaborator metadata',await page(null,50,collaborator.access_token));check('revoked collaborator retains contentless own receipt',revoked.entries.length===1&&revoked.entries[0].current_title===null);
 const beforeComparisonAfterSharing=await allStored();
 await runtime.raw('update taskfold_private.child_task_record_config set reads_enabled=false,edits_enabled=false,completions_enabled=false,structure_reads_enabled=false,structure_edits_enabled=false,adoption_enabled=false,repair_reviews_enabled=false,repair_writes_enabled=false');
 check('recovery list survives paused writes',ok('paused list',await page()).entries.length===3);ok('paused export remains authorized',await fetchOriginal(loaded[0].receipt));
 const pausedComparison=ok('comparison independent of paused authoring',await compare(loaded[0].receipt));check('paused comparison cannot authorize adoption',pausedComparison.current.can_adopt===false);check('paused comparison still preserves work',await allStored()===beforeComparisonAfterSharing);
 check('outsider list empty',ok('outsider discovery',await page(null,50,outsider.access_token)).entries.length===0);
 check('outsider cannot compare known archive',(await compare(loaded[0].receipt,outsider.access_token)).status===403);
 check('outsider cannot export known archive',(await fetchOriginal(loaded[0].receipt,outsider.access_token)).status===403);
 check('comparison refuses swapped archive',(await compare({...loaded[0].receipt,archive_id:loaded[1].receipt.archive_id})).status===403);
 check('mismatched archive refused',(await fetchOriginal({...loaded[0].receipt,archive_id:loaded[1].receipt.archive_id})).status===403);
 for(const limit of [0,51,null])check('invalid page limit '+limit,(await page(null,limit)).status===400);
 const target=sorted[0].task.id;
 await runtime.raw(`create policy archive_test_current_root on public.tasks as restrictive for select to authenticated using(id<>${lit(target)}::uuid)`);
 check('comparison enforces current root RLS',(await compare(loaded[0].receipt)).status===403);
 check('current caller task policy enforced',(await fetchOriginal(loaded[0].receipt)).status===403);
 const lostPage=ok('list with lost root access',await page());check('contentless receipt survives lost read access',lostPage.entries.length===3);check('current title hidden by caller RLS',lostPage.entries.find(e=>e.receipt.task_id===target).current_title===null);
 await runtime.raw('drop policy archive_test_current_root on public.tasks');
 const historyCount=original.original.child_history.length;check('test archive has real child history',historyCount>0);
 await runtime.raw('create policy archive_test_history on public.task_node_activity as restrictive for select to authenticated using(false)');
 check('comparison enforces archived history RLS',(await compare(loaded[0].receipt)).status===403);
 check('current caller history policy enforced',(await fetchOriginal(loaded[0].receipt)).status===403);await runtime.raw('drop policy archive_test_history on public.task_node_activity');
 ok('export recovers after access restored',await fetchOriginal(loaded[0].receipt));
 await runtime.raw(`update taskfold_private.child_task_repair_originals set original=jsonb_set(original,'{root,title}','"Damaged archive"'),bytes=octet_length(jsonb_set(original,'{root,title}','"Damaged archive"')::text) where id=${lit(loaded[0].receipt.archive_id)}`);
 check('comparison refuses damaged original',(await compare(loaded[0].receipt)).status===409);
 check('damaged original refused',(await fetchOriginal(loaded[0].receipt)).status===409);
 check('metadata discovery does not depend on original decoding',ok('damaged-original metadata',await page()).entries.length===3);
 await runtime.raw(`delete from taskfold_private.child_task_repair_originals where id=${lit(loaded[1].receipt.archive_id)}`);
 const missing=ok('purged-original metadata',await page()).entries.find(e=>e.receipt.archive_id===loaded[1].receipt.archive_id);check('purged original marked unavailable',missing.content_retained===false);
 check('comparison refuses removed original',(await compare(loaded[1].receipt)).status===403);
 check('purged original cannot export',(await fetchOriginal(loaded[1].receipt)).status===403);
 await runtime.raw(`delete from auth.sessions where user_id=${lit(account)}`);
 check('expired session cannot compare',(await compare(loaded[2].receipt)).value?.code==='28000');
 const expiredPage=await page(),expiredOriginal=await fetchOriginal(loaded[2].receipt);report.expiredSessionResponses={page:{status:expiredPage.status,code:expiredPage.value?.code},original:{status:expiredOriginal.status,code:expiredOriginal.value?.code}};check('expired session cannot discover',expiredPage.status>=400&&expiredPage.value?.code==='28000');check('expired session cannot export',expiredOriginal.status>=400&&expiredOriginal.value?.code==='28000');
 check('no public definer entrypoints',await runtime.raw("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('taskfold_child_repair_archives','taskfold_child_repair_original') and p.prosecdef")==='0');
 check('no anonymous API grants',await runtime.raw("select bool_and(not has_function_privilege('anon',p.oid,'EXECUTE')) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('taskfold_child_repair_archives','taskfold_child_repair_original')")==='t');
 check('no direct archive table grant',await runtime.raw("select has_table_privilege('authenticated','taskfold_private.child_task_repair_originals','SELECT')")==='f');
 check('comparison public entrypoint is invoker',await runtime.raw("select not prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='taskfold_compare_child_repair_original'")==='t');
 check('comparison anonymous execution refused',await runtime.raw("select not has_function_privilege('anon','public.taskfold_compare_child_repair_original(uuid,uuid)','EXECUTE')")==='t');
 report.advisors=await runtime.advisors();report.passed=true;
}catch(e){report.failure={message:e.message,migration:e.migration};process.exitCode=1;}finally{if(runtime)report.cleanup=await runtime.close();await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:report.passed??false,checks:Object.keys(report.checks).length,failure:report.failure,lastFailure:report.lastFailure,cleanup:report.cleanup}));}
