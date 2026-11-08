import assert from 'node:assert/strict';
import {writeFile,readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
import {literal as lit} from './postgres-fixture.mjs';
const report={checks:{},deployed:false,scope:'Disposable full-schema Auth/PostgREST fixture; no native UI acceptance'};let runtime;
const check=(name,value)=>{assert.equal(value,true,name);report.checks[name]=true;console.log('passed',name)};
const ok=(name,r,status=200)=>{if(r.status!==status)report.lastFailure={name,status:r.status,value:r.value};check(name,r.status===status);return r.value};
const json=v=>lit(JSON.stringify(v))+'::jsonb';
try{
 runtime=await createFullSchemaRuntime();report.migrations=runtime.migrations;report.baselineAdvisors=await runtime.advisors();
 const owner=ok('owner signup',await runtime.request('auth','/signup',{method:'POST',body:{email:'format-'+randomUUID()+'@example.invalid',password:randomUUID()+'Aa42!'}}));
 const other=ok('other signup',await runtime.request('auth','/signup',{method:'POST',body:{email:'other-'+randomUUID()+'@example.invalid',password:randomUUID()+'Aa42!'}}));
 const account=owner.user.id,authorization=owner.access_token;
 const api=(path,body,token=authorization)=>runtime.request('rest',path,{authorization:token,method:'POST',body,includeText:true});
 await runtime.raw('update taskfold_private.child_task_record_config set adoption_enabled=true,repair_reviews_enabled=true,repair_writes_enabled=true,reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true,copy_reconciliation_enabled=true,mapping_reconciliation_enabled=true');
 const id=randomUUID();const tree=[{id:'parent',title:'Keep parent',completed:false,subtasks:[{id:'child',title:'Current instruction',completed:false}]}];
 ok('create source',await api('/tasks',{id,user_id:account,title:'Keep current task',description:'Current notes',priority:1,subtasks:tree}),201);
 await runtime.raw(`select taskfold_private.adopt_child_task_records(id,task_generation,subtasks) from public.tasks where id=${lit(id)};select taskfold_private.promote_child_task_records(t.id,t.task_generation,t.project_id,p.revision,t.subtasks) from public.tasks t join taskfold_private.child_task_projections p on p.task_id=t.id where t.id=${lit(id)}`);
 const row=async()=>JSON.parse(await runtime.raw(`select to_jsonb(t)::text from public.tasks t where id=${lit(id)}`));
 const records=async()=>JSON.parse(await runtime.raw(`select jsonb_agg(to_jsonb(r) order by node_key)::text from taskfold_private.child_task_records r where task_id=${lit(id)}`));
 const state=()=>runtime.raw(`select jsonb_build_object('restorations',(select jsonb_agg(to_jsonb(r) order by restore_id) from taskfold_private.child_repair_restorations r),'payloads',(select jsonb_agg(to_jsonb(p) order by restore_id) from taskfold_private.child_repair_restore_payloads p),'restore_requests',(select jsonb_agg(to_jsonb(r) order by request_id) from taskfold_private.child_repair_restore_requests r),'root_history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_activity h),'root',(select to_jsonb(t) from public.tasks t where id=${lit(id)}),'projections',(select jsonb_agg(to_jsonb(p)) from taskfold_private.child_task_projections p),'records',(select jsonb_agg(to_jsonb(r) order by node_key) from taskfold_private.child_task_records r),'authority',(select jsonb_agg(to_jsonb(a)) from taskfold_private.child_task_record_authority a),'repairs',(select jsonb_agg(to_jsonb(r) order by request_id) from taskfold_private.child_task_repairs r),'originals',(select jsonb_agg(to_jsonb(o) order by id) from taskfold_private.child_task_repair_originals o),'history',(select jsonb_agg(to_jsonb(h) order by sequence) from public.task_node_activity h),'scopes',(select jsonb_agg(to_jsonb(s)) from taskfold_private.child_mapping_scope s))::text`);
 let rows=await records(),r=rows.find(n=>n.node_key==='child');
 const baseline=JSON.parse(await runtime.raw(`select taskfold_private.child_task_completion_state(fields)::text from taskfold_private.child_task_records where task_id=${lit(id)} and node_key='child'`));
 ok('earn completion before recovery',await api('/rpc/taskfold_complete_child_task',{_body:{protocol:1,account,request_id:randomUUID(),task_id:id,task_generation:(await row()).task_generation,project_id:null,node_key:'child',incarnation:r.incarnation,revision:r.revision,action:'complete',baseline}}));
 // A divergent malformed saved copy is synthetic setup only. All reviewed
 // operations below use the real authenticated API and caller RLS.
 await runtime.raw(`alter table taskfold_private.child_task_projections disable trigger user;update taskfold_private.child_task_projections set source_tree='[{"id":"parent","title":"Older parent","completed":false,"future":{"exact":9007199254740993,"huge":1e500,"é":1,"é":2},"subtasks":["Original instruction"]}]'::jsonb where task_id=${lit(id)};alter table taskfold_private.child_task_projections enable trigger user`);
 const reviewWire=await api('/rpc/taskfold_review_child_adoption',{_id:id,_generation:(await row()).task_generation});
 const review=ok('current source review',reviewWire);
 const identity=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,review[k]]));
 const copiesWire=await api('/rpc/taskfold_review_child_copies',{_body:identity});const copies=ok('read malformed copy',copiesWire);
 check('malformed saved copy needs review',copies.copies.find(c=>c.id==='projection').state==='review');
 rows=await records();
 const mapping={version:1,nodes:[{source_key:'parent',history_key:'parent',incarnation:rows.find(n=>n.node_key==='parent').incarnation,lifecycle:'recorded'},{source_key:'repaired-instruction',history_key:'child',incarnation:rows.find(n=>n.node_key==='child').incarnation,lifecycle:'recorded'}],retire:[]};
 const changes=[{kind:'choose_copy',path:[],source:'projection',copy_digest:copies.copy_digest,mapping,format_changes:[{kind:'wrap_item',path:[0,0],reference:'repaired-instruction',title:'Recovered instruction'}]}];
 const body={...identity,changes};
 const preview=b=>api('/rpc/taskfold_preview_child_repair',{_body:b});
 const send=(b,operation='send',token=authorization)=>api('/rpc/taskfold_repair_children',{_operation:operation,_body:b},token);
 const before=await state(),rootWire=await runtime.raw(`select to_jsonb(t)::text from public.tasks t where id=${lit(id)}`);const previewWire=await preview(body);const p=ok('combined format and mapping preview',previewWire);
 check('review has no writes',await state()===before);check('valid mapped repaired source eligible',p.mutation_available&&p.proposal_valid&&p.node_count===2);
 check('repaired wrapped original retained',p.proposed_tree[0].subtasks[0].legacy_original==='Original instruction');
 check('recorded completed state retained',p.proposed_tree[0].subtasks[0].completed===true);
 for(const [name,format,status] of [['empty',[],400],['scalar','wrong',400],['nested choice',[changes[0]],400],['incomplete repair',[{kind:'assign_reference',path:[0],reference:'different-parent'}],409],['unknown operation',[{kind:'overwrite',path:[]}],400],['fractional path',[{kind:'wrap_item',path:[0,0.5],reference:'x',title:'X'}],400],['too many',Array(65).fill(changes[0].format_changes[0]),400],['oversized',[{kind:'wrap_item',path:[0,0],reference:'x',title:'x'.repeat(66000)}],400]]){
  ok('reject '+name,await preview({...body,changes:[{...changes[0],format_changes:format}]}),status);check(name+' retains all work',await state()===before);
 }
 const plain=structuredClone(body);delete plain.changes[0].mapping;ok('format cannot bypass mapping',await preview(plain),400);
 // Match the existing journal/send ceiling before doing format work: a valid
 // mapping and valid-sized format list cannot each consume the full envelope.
 const many={version:1,nodes:[],retire:[]};
 for(let i=0;i<900;i++){
  many.nodes.push({source_key:('source-'+i+'-').padEnd(128,'s'),history_key:null,incarnation:null,lifecycle:'selected',new_reference:('new-'+i+'-').padEnd(128,'n')});
  many.retire.push({node_key:('old-'+i+'-').padEnd(128,'o'),incarnation:randomUUID()});
 }
 const longFormat=Array.from({length:60},(_,i)=>({kind:'wrap_item',path:[0,0],reference:'long-'+i,title:'é'.repeat(420)}));
 const largeChoice={...changes[0],mapping:many,format_changes:longFormat};
 check('combined limit fixture parts individually bounded',Buffer.byteLength(JSON.stringify(many))<512000&&Buffer.byteLength(JSON.stringify(longFormat))<65536&&Buffer.byteLength(JSON.stringify(largeChoice))>550000);
 const tooLarge=await preview({...body,changes:[largeChoice]});ok('combined metadata ceiling enforced before planning',tooLarge,400);
 check('combined rejection explains bounded review',tooLarge.value.message==='Review bounded format repairs before mapping their histories');check('combined rejection preserves every copy',await state()===before);
 const cmd={...body,request_id:randomUUID(),repair_digest:p.repair_digest};
 const tampered=structuredClone(cmd);tampered.changes[0].format_changes[0].title='Changed after review';ok('format consent bound to exact digest',await send(tampered),409);check('tamper has no writes',await state()===before);
 ok('another account denied',await send({...cmd,account:other.user.id},'send',other.access_token),403);check('other actor cannot alter copies',await state()===before);
 await runtime.raw(`create policy fixture_format_no_update on public.tasks as restrictive for update to authenticated using(id<>${lit(id)}::uuid) with check(id<>${lit(id)}::uuid)`);
 ok('actual caller update denial',await send(cmd),403);check('RLS failure rolls back archive records history and receipt',await state()===before);
 await runtime.raw('drop policy fixture_format_no_update on public.tasks');
 const rawCopy=await runtime.raw(`select source_tree::text from taskfold_private.child_task_projections where task_id=${lit(id)}`);
 const beforeHistory=JSON.parse(await runtime.raw(`select jsonb_agg(to_jsonb(h) order by sequence)::text from public.task_node_activity h where task_id=${lit(id)}`));
 const resultWire=await send(cmd);const result=ok('atomic reviewed repaired copy applied',resultWire);check('applied receipt',result.state==='applied');
 const applied=await state();check('repeat exactly one decision',ok('retry after lost reply',await send(cmd)).replayed===true&&await state()===applied);
 const originalWire=await send(cmd,'original');ok('complete original recovery',originalWire);
 check('original divergent malformed copy exact',await runtime.raw(`select (original->'projection'->'source_tree')::text from taskfold_private.child_task_repair_originals where id=${lit(result.archive_id)}`)===rawCopy);
 check('root notes and priority survive',(await row()).description==='Current notes'&&(await row()).priority===1);
 check('all prior events unchanged',beforeHistory.every(h=>JSON.parse(applied).history.some(a=>JSON.stringify(a)===JSON.stringify(h))));
 check('mapping history emitted once',JSON.parse(applied).history.filter(h=>h.format_version===4).length===1);
 check('all current incarnations retained',(await records()).every(n=>rows.some(r=>r.node_key===n.node_key&&r.incarnation===n.incarnation)));
 check('exact opaque fields survive repair and mapping',await runtime.raw(`select (subtasks->0->'future')::text from public.tasks where id=${lit(id)}`)===await runtime.raw(`select (original->'projection'->'source_tree'->0->'future')::text from taskfold_private.child_task_repair_originals where id=${lit(result.archive_id)}`));
 check('no transaction scopes leaked',await runtime.raw('select not exists(select 1 from taskfold_private.child_mapping_scope) and not exists(select 1 from taskfold_private.team_task_edit_scope)')==='t');
 await runtime.raw('update taskfold_private.child_task_record_config set mapping_reconciliation_enabled=false');
 ok('receipt recovery while gate paused',await send(cmd,'check'));check('paused replay does not alter work',ok('paused exact send recovery',await send(cmd)).replayed&&await state()===applied);
 const contract='{'+Object.entries({root:rootWire,review:reviewWire.text,copies:copiesWire.text,preview:previewWire.text,choice:JSON.stringify(cmd),receipt:resultWire.text,original:originalWire.text}).map(([k,v])=>JSON.stringify(k)+':'+v).join(',')+'}';
 if(process.argv[3])await writeFile(process.argv[3],JSON.stringify({value:null}).replace('null',contract)+'\n');
 // An active restoration may inspect the mapping but needs a distinct final
 // adoption transaction. The ordinary repair must leave every copy protected.
 await runtime.raw('update taskfold_private.child_task_record_config set archive_restore_enabled=true,archive_restore_reversals_enabled=true,mapping_reconciliation_enabled=true');
 const rv=ok('restore review for adoption fence',await api('/rpc/taskfold_review_child_restore',{_mode:'restore',_repair:result.request_id,_archive:result.archive_id,_restore:null}));
 const restoreKeys=['protocol','account','task_id','task_generation','project_id','workspace_id','repair_request_id','archive_id','archive_digest','mode','restore_id','revision','review_digest'];
 const restored=ok('real restore before adoption fence',await api('/rpc/taskfold_restore_child_original',{_operation:'send',_body:{...Object.fromEntries(restoreKeys.map(k=>[k,rv[k]])),request_id:randomUUID()}}));
 const ar=ok('restored adoption source review',await api('/rpc/taskfold_review_child_adoption',{_id:id,_generation:(await row()).task_generation}));
 const ai=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,ar[k]]));
 const ac=ok('restored copy comparison',await api('/rpc/taskfold_review_child_copies',{_body:ai}));
 const am={version:1,nodes:(await records()).map(r=>({source_key:r.node_key==='parent'?'renamed-parent':r.node_key,history_key:r.node_key,incarnation:r.incarnation,lifecycle:'recorded'})),retire:[]};
 const ab={...ai,changes:[{kind:'choose_copy',path:[],source:'task',copy_digest:ac.copy_digest,mapping:am,format_changes:[{kind:'assign_reference',path:[0],reference:'renamed-parent'}]}]};
 const held=await state();ok('retained shadow copies still require access review',await preview(ab),409);
 ok('ordinary mapping cannot read or end held restoration',await send({...ab,request_id:randomUUID(),repair_digest:'a'.repeat(64)}),409);
 check('hidden-copy rejection keeps all work exact',await state()===held);
 const ur=ok('review Undo for next fixture',await api('/rpc/taskfold_review_child_restore',{_mode:'undo',_repair:result.request_id,_archive:result.archive_id,_restore:restored.restoration_id}));
 ok('Undo restores current editable source',await api('/rpc/taskfold_restore_child_original',{_operation:'send',_body:{...Object.fromEntries(restoreKeys.map(k=>[k,ur[k]])),request_id:randomUUID()}}));
 // A restoration with identical independently readable copies reaches the
 // explicit custody blocker rather than an earlier access-denial branch.
 async function choiceForCurrent(rename=false){
  const source=ok('fresh readable source '+rename,await api('/rpc/taskfold_review_child_adoption',{_id:id,_generation:(await row()).task_generation}));
  const identity=Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,source[k]]));
  const copies=ok('fresh readable copies '+rename,await api('/rpc/taskfold_review_child_copies',{_body:identity}));
  return {...identity,changes:[{kind:'choose_copy',path:[],source:'task',copy_digest:copies.copy_digest,mapping:{version:1,nodes:(await records()).map(r=>({source_key:rename&&r.node_key==='parent'?'renamed-parent':r.node_key,history_key:r.node_key,incarnation:r.incarnation,lifecycle:'recorded'})),retire:[]},...(rename?{format_changes:[{kind:'assign_reference',path:[0],reference:'renamed-parent'}]}:{})}]};
 }
 const equal=await choiceForCurrent(),ep=ok('equal copy mapping review',await preview(equal));
 const er=ok('equal copy mapped archive',await send({...equal,request_id:randomUUID(),repair_digest:ep.repair_digest}));
 const ev=ok('equal copy restoration review',await api('/rpc/taskfold_review_child_restore',{_mode:'restore',_repair:er.request_id,_archive:er.archive_id,_restore:null}));
 ok('equal copy real restoration',await api('/rpc/taskfold_restore_child_original',{_operation:'send',_body:{...Object.fromEntries(restoreKeys.map(k=>[k,ev[k]])),request_id:randomUUID()}}));
 const equalChoice=await choiceForCurrent(true),equalBefore=await state(),ap=ok('readable restored format inspection',await preview(equalChoice));
 check('active restoration has explicit custody blocker',ap.custody_blocker==='restoration_custody'&&ap.mutation_available===false);
 ok('readable ordinary mapping cannot end restoration',await send({...equalChoice,request_id:randomUUID(),repair_digest:ap.repair_digest}),409);
 check('failed adoption keeps current root history receipts and inverse payload exact',await state()===equalBefore);
 check('private format helper not callable by authenticated role',await runtime.raw("select not has_function_privilege('authenticated','taskfold_private.format_child_copy_for_mapping(jsonb,jsonb)','execute') and not has_function_privilege('anon','taskfold_private.format_child_copy_for_mapping(jsonb,jsonb)','execute')")==='t');
 report.advisors=await runtime.advisors();report.passed=true;
}catch(e){report.failure={message:e.message,stack:e.stack};process.exitCode=1;}finally{if(runtime)try{await runtime.close();report.fixtureRemoved=true}catch(e){report.cleanupFailure=e.message;process.exitCode=1}await writeFile(process.argv[2]??'/tmp/taskfold-copy-format-service.json',JSON.stringify(report,null,2)+'\n');}
