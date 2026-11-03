// Real local Supabase Auth and PostgREST against this repo's complete schema.
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
const report={scope:'Genuine local Auth/REST on the complete owning schema; synthetic users/tasks only',checks:{},hostedChanges:false,nativeStoreAcceptance:false};
const check=(n,a,b=true)=>{assert.deepEqual(a,b,n);report.checks[n]=true;};let runtime;
try{
 let applied=0;runtime=await createFullSchemaRuntime({onMigration:()=>{if(++applied%50===0)console.log('Applied owned migrations:',applied)}});report.migrations=runtime.migrations;
 const signup=async()=>{const r=await runtime.request('auth','/signup',{method:'POST',body:{email:'workflow-'+randomUUID()+'@example.invalid',password:randomBytes(24).toString('hex')}});assert.equal(r.status,200);assert(r.value.access_token);return {id:r.value.user.id,token:r.value.access_token};};
 const actor=await signup(),other=await signup();
 const rpc=(name,body={},who=actor)=>runtime.request('rest','/rpc/'+name,{method:'POST',body,authorization:who.token});
 const caps=await rpc('taskfold_workflow_undo_capabilities');check('authenticated capability uses actual signed-in identity',caps.value,{protocol:1,account:actor.id,undo_protocol:1,bulk_protocol:1});
 check('capability route succeeds',caps.status,200);
 const create=async(table,fields)=>{const r=await runtime.request('rest','/'+table,{method:'POST',body:fields,authorization:actor.token,headers:{Prefer:'return=representation'}});assert.equal(r.status,201,JSON.stringify({table,status:r.status,error:r.value?.code}));return r.value[0];};
 const p=randomUUID(),s=randomUUID(),l=randomUUID(),t=randomUUID(),v='group:'+p+':'+s;
 const values={projects:{id:p,user_id:actor.id,name:'Auth workflow workshop'},sections:{id:s,user_id:actor.id,project_id:p,name:'Prepare'},labels:{id:l,user_id:actor.id,name:'Studio'},tasks:{id:t,user_id:actor.id,project_id:p,section_id:s,title:'Auth workflow task',task_generation:randomUUID()},view_orders:{id:v,user_id:actor.id,ids:[t]}};
 for(const table of ['projects','sections','labels','tasks','view_orders'])await create(table,values[table]);
 const body={user_id:actor.id,items:['view_orders','tasks','labels','sections','projects'].map(table=>({table,id:values[table].id,base:values[table]}))},id=randomUUID();
 const undone=await rpc('taskfold_undo_private_workflow',{_request:id,_body:body});check('authenticated Undo returns success',undone.status,200);check('authenticated Undo atomically applies',undone.value.applied);check('success contains no archived task content',undone.value.rows,[]);
 for(const table of Object.keys(values)){const r=await runtime.request('rest','/'+table+'?id=eq.'+encodeURIComponent(values[table].id),{authorization:actor.token});check('actual REST confirms removal '+table,r.value,[]);}
 await create('projects',{id:p,user_id:actor.id,name:'Recreated after Undo'});const retry=await rpc('taskfold_undo_private_workflow',{_request:id,_body:body});check('real API lost-reply retry returns original confirmation',retry.value,undone.value);
 check('retry keeps recreated project',(await runtime.request('rest','/projects?id=eq.'+p,{authorization:actor.token})).value[0].name,'Recreated after Undo');
 const next={id:randomUUID(),user_id:actor.id,project_id:p,title:'Later edited task',task_generation:randomUUID()};await create('tasks',next);
 const updated=await rpc('taskfold_patch_task',{_id:next.id,_base:{task_generation:next.task_generation,description:null},_changes:{description:'Later notes survive'}});check('ordinary guarded edit remains available',updated.status,200);
 const changed={user_id:actor.id,items:[{table:'tasks',id:next.id,base:next}]},refused=await rpc('taskfold_undo_private_workflow',{_request:randomUUID(),_body:changed});check('real API refuses Undo after later editing',refused.value.applied,false);check('refusal supplies current owned notes',refused.value.rows[0].row.description,'Later notes survive');
 const foreign=await rpc('taskfold_undo_private_workflow',{_request:randomUUID(),_body:changed},other);check('another real Auth account cannot Undo owner work',foreign.value.code,'22023');
 const anonymous=await runtime.request('rest','/rpc/taskfold_undo_private_workflow',{method:'POST',body:{_request:randomUUID(),_body:changed}});check('actual anonymous role cannot execute Undo',anonymous.value.code,'42501');
 const lit=x=>"'"+String(x).replaceAll("'","''")+"'";await runtime.raw('delete from auth.sessions where user_id='+lit(actor.id));
 const revoked=await rpc('taskfold_undo_private_workflow',{_request:randomUUID(),_body:changed});check('still-valid JWT cannot bypass revoked Auth session',revoked.value.code,'28000');
 const revokedCaps=await rpc('taskfold_workflow_undo_capabilities');check('revoked session cannot advertise support',revokedCaps.value.code,'28000');
 report.passed=Object.keys(report.checks).length;
}catch(e){report.error=e.message;report.failedMigration=e.migration;process.exitCode=1;}finally{if(runtime)report.runtimeRemoved=await runtime.close();await writeFile(new URL('../../docs/daily-use-build/personal-workflow-service-http.json',import.meta.url),JSON.stringify(report,null,2)+'\n');}
console.log(JSON.stringify({checks:report.passed,error:report.error,failedMigration:report.failedMigration,runtimeRemoved:report.runtimeRemoved}));
