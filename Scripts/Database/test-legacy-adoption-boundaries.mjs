// Genuine local Auth/REST legacy migration refusal and reviewed replacement.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {isDeepStrictEqual} from 'node:util';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
const output=process.argv[2];assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));
const report={hostedChanges:false,nativeUIOrStoreAcceptance:false,normalUseGatesChanged:false,checks:{},cases:[]};let runtime;
const lit=v=>"'"+String(v).replaceAll("'","''")+"'";
const check=(name,value)=>{assert.equal(value,true,name);report.checks[name]=true;console.log('passed',name)};
const ok=(name,response,status=200)=>{if(response.status!==status)report.lastFailure={name,status:response.status,code:response.value?.code,message:response.value?.message};check(name,response.status===status);return response.value};
try{
 runtime=await createFullSchemaRuntime();report.migrations=runtime.migrations;report.images=runtime.images;
 const nonce=randomUUID(),signup=ok('genuine owner signup',await runtime.request('auth','/signup',{method:'POST',body:{email:'legacy-boundary-'+nonce+'@example.invalid',password:randomUUID()+'Aa42!'}}));
 const account=signup.user.id,authorization=signup.access_token;
 const api=(path,options={})=>runtime.request('rest',path,{authorization,...options});
 const project=randomUUID();ok('genuine owner project',await api('/projects',{method:'POST',body:{id:project,user_id:account,name:'Legacy boundary workshop'}}),201);
 await runtime.raw('update taskfold_private.child_task_record_config set reads_enabled=true,edits_enabled=true,completions_enabled=true,structure_reads_enabled=true,structure_edits_enabled=true,adoption_enabled=true');
 const make=async(title,tree)=>ok('create '+title,await api('/tasks',{method:'POST',headers:{Prefer:'return=representation'},body:{id:randomUUID(),user_id:account,project_id:project,title,description:'Keep original root notes',subtasks:tree}}),201)[0];
 const root=async task=>ok('read '+task.title,await api('/tasks?id=eq.'+task.id+'&select=*'))[0];
 const review=async task=>ok('review '+task.title,await api('/rpc/taskfold_review_child_adoption',{method:'POST',body:{_id:task.id,_generation:task.task_generation}}));
 const command=(r,id=randomUUID())=>Object.fromEntries(['protocol','account','task_id','task_generation','project_id','workspace_id','review_digest'].map(k=>[k,r[k]]).concat([['request_id',id]]));
 const operation=(body,operation='send',token=authorization)=>api('/rpc/taskfold_adopt_child_records',{method:'POST',authorization:token,body:{_operation:operation,_body:body}});
 const key=randomUUID();
 const cases=[['duplicate identity',[{id:key,title:'First original',future:{keep:[null,false,'first']}},{id:key,title:'Second original',future:{keep:'second'}}]],['canonical identity collision',[{id:'é',title:'Composed original'},{id:'e\u0301',title:'Decomposed original'}]],['missing identity',[{title:'Original without identity',future:{keep:{'é':1,'e\u0301':2}}}]],['unsupported root shape',{legacy:'Keep this object exactly',original:[false,null,'source']}]];
 for(const [name,tree] of cases){
  const task=await make(name,tree),before=await root(task),r=await review(task),body=command(r);
  check(name+' requires review and cannot adopt',r.state==='review'&&r.can_adopt===false&&typeof r.issue==='string'&&r.source_included===true);
  check(name+' exposes the exact original JSON value',isDeepStrictEqual(r.source_tree,tree));
  ok(name+' direct stale or invalid send refused',await operation(body),409);
  const after=await root(task);
  check(name+' retains original task and generation',isDeepStrictEqual(after,before));
  check(name+' creates no record authority',await runtime.raw(`select count(*) from taskfold_private.child_task_record_authority where task_id=${lit(task.id)}`)==='0');
  report.cases.push({name,issue:r.issue,original:tree,reviewSource:r.source_tree,retained:true,authority:false});
 }
 const originalTree=[{id:randomUUID(),title:'Original reviewed child',completed:true,completed_at:'2026-10-01T09:00:00Z',future:{keep:[false,null,'original']}}];
 const task=await make('changed reviewed source',originalTree),first=await review(task),old=command(first),oldBytes=JSON.stringify(old);
 check('valid original review is eligible',first.state==='ready'&&first.can_adopt===true);
 const remoteTree=[{...originalTree[0],title:'Newer remote child',future:{keep:[false,null,'remote original']}}];
 ok('real other-client source edit',await api('/tasks?id=eq.'+task.id,{method:'PATCH',body:{subtasks:remoteTree}}),204);
 const remote=await root(task);
 ok('old review digest cannot promote changed source',await operation(old),409);
 check('refused old digest preserves newer task exactly',isDeepStrictEqual(await root(task),remote));
 check('old digest refusal establishes no authority',await runtime.raw(`select count(*) from taskfold_private.child_task_record_authority where task_id=${lit(task.id)}`)==='0');
 const closed=ok('close original reviewed migration',await operation(old,'close'));
 check('genuine closure proof binds old review',closed.state==='closed'&&closed.request_id===old.request_id&&closed.review_digest===old.review_digest);
 const late=ok('late old send returns its closed proof',await operation(old));
 check('closed old send cannot upgrade or overwrite newer source',late.state==='closed'&&late.replayed===true&&isDeepStrictEqual(await root(task),remote));
 const fresh=await review(task),replacement=command(fresh);
 check('fresh review captures changed digest and original request is immutable',fresh.can_adopt===true&&fresh.review_digest!==old.review_digest&&replacement.request_id!==old.request_id&&JSON.stringify(old)===oldBytes);
 const applied=ok('explicit fresh migration applies',await operation(replacement));
 check('fresh migration confirms exact new digest',applied.state==='applied'&&applied.replayed===false&&applied.review_digest===fresh.review_digest);
 check('fresh migration preserves current source and generation',isDeepStrictEqual(await root(task),remote));
 check('one applied and one closed migration proof retained',await runtime.raw(`select count(*) filter(where state='applied')||':'||count(*) filter(where state='closed') from taskfold_private.child_task_adoptions where task_id=${lit(task.id)}`)==='1:1');
 const outsider=ok('genuine outsider signup',await runtime.request('auth','/signup',{method:'POST',body:{email:'legacy-outsider-'+nonce+'@example.invalid',password:randomUUID()+'Aa42!',data:{role:'service_role'}}}));
 const hidden=ok('outsider ordinary task query',await api('/tasks?id=eq.'+task.id+'&select=*',{authorization:outsider.access_token}));check('outsider cannot read private source',hidden.length===0);
 ok('outsider cannot review original source',await api('/rpc/taskfold_review_child_adoption',{method:'POST',authorization:outsider.access_token,body:{_id:task.id,_generation:task.task_generation}}),403);
 ok('outsider cannot reuse owner request',await operation(replacement,'send',outsider.access_token),403);
 check('outsider attempts preserve current task',isDeepStrictEqual(await root(task),remote));
 check('cron remains disabled',await runtime.raw('show cron.launch_active_jobs')==='off');
 check('no outgoing jobs queued',await runtime.raw('select count(*) from net.http_request_queue')==='0');
 report.checkCount=Object.keys(report.checks).length;report.accepted=true;
}catch(error){report.error={message:error.message,code:error.code,migration:error.migration};process.exitCode=1}
finally{if(runtime)report.cleanedUp=await runtime.close();await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({accepted:report.accepted,checks:report.checkCount,error:report.error,lastFailure:report.lastFailure,cleanedUp:report.cleanedUp}))}
