// Local synthetic test channel only. No listening ports or hosted credentials.
import {readFile, writeFile, rename, lstat, readdir, unlink} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {resolve,join} from 'node:path';
import {literal as lit} from './postgres-fixture.mjs';
export const identity={account:'ec990000-0000-4000-8000-000000000001',root:'ec990000-0000-4000-8000-000000000002',generation:'ec990000-0000-4000-8000-000000000003'};
export async function atomicFile(path, data) {
 const temporary=path+'.'+randomUUID()+'.tmp';
 try {await writeFile(temporary,data,{mode:0o600,flag:'wx'});await rename(temporary,path);} finally {await unlink(temporary).catch(()=>{});}
}
export async function boundedFile(path, maximum) {
 const info=await lstat(path);if(!info.isFile()||info.isSymbolicLink()||info.size>maximum)throw new Error('Invalid channel file');
 const data=await readFile(path);if(data.length>maximum)throw new Error('Oversized channel file');return data;
}
export function createMappingSQLChannel(pg,{session,nonce,loseFirstSave=false,beforeReply=async()=>{}}) {
 let lost=false;
 const json=v=>lit(JSON.stringify(v))+'::jsonb';
 async function dispatch(request) {
  if(request.protocol!==1||request.nonce!==nonce||!/^[a-f0-9-]{36}$/.test(request.id??'')||typeof request.body!=='string'||request.body.length>800000)throw new Error('Invalid channel request');
  const bytes=Buffer.from(request.body,'base64');if(bytes.toString('base64')!==request.body||bytes.length>600000)throw new Error('Invalid request bytes');
  const body=JSON.parse(bytes.toString('utf8'));let expression;
  switch(request.path){
   case '/rest/v1/rpc/taskfold_search_child_adoption_targets':
    if(Object.keys(body).sort().join(',')!=='_after,_limit,_query'||typeof body._query!=='string'||![...body._query].length||[...body._query].length>256||Buffer.byteLength(body._query)>1024||body._query.includes('\0')||!Number.isInteger(body._limit)||body._limit<1||body._limit>100||body._after!==null&&!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(body._after??''))throw new Error('Invalid search scope');
    expression=`public.taskfold_search_child_adoption_targets(${lit(body._query)},${body._after===null?'null':lit(body._after)},${body._limit})`;break;
   case '/rest/v1/rpc/taskfold_child_adoption_targets':
    if(Object.keys(body).sort().join(',')!=='_after,_id,_limit'||!Number.isInteger(body._limit)||body._limit<1||body._limit>100||body._id!==null&&body._id!==identity.root||body._after!==null&&!/^[a-f0-9-]{36}$/.test(body._after??''))throw new Error('Invalid discovery scope');
    expression=`public.taskfold_child_adoption_targets(${body._after===null?'null':lit(body._after)},${body._limit},${body._id===null?'null':lit(body._id)})`;break;
   case '/rest/v1/rpc/taskfold_child_repair_archives':
    if(Object.keys(body).sort().join(',')!=='_after,_limit'||!Number.isInteger(body._limit)||body._limit<1||body._limit>50||body._after!==null&&!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(body._after??''))throw new Error('Invalid archive page');
    expression=`public.taskfold_child_repair_archives(${body._after===null?'null':lit(body._after)},${body._limit})`;break;
   case '/rest/v1/rpc/taskfold_compare_child_repair_original':
   case '/rest/v1/rpc/taskfold_child_repair_original':
    if(Object.keys(body).sort().join(',')!=='_archive,_request'||!['_archive','_request'].every(k=>/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(body[k]??'')))throw new Error('Invalid archive identity');
    expression=`public.${request.path.split('/').at(-1)}(${lit(body._request)},${lit(body._archive)})`;break;
   case '/rest/v1/rpc/taskfold_child_repair_original_cleanup':
    if(Object.keys(body).sort().join(',')!=='_archive,_bytes,_digest,_operation,_request'||!['review','remove'].includes(body._operation)||!Number.isInteger(body._bytes)||body._bytes<1||body._bytes>8000000||!/^[a-f0-9]{64}$/.test(body._digest??'')||!['_archive','_request'].every(k=>/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(body[k]??'')))throw new Error('Invalid original cleanup');
    expression=`public.taskfold_child_repair_original_cleanup(${lit(body._operation)},${lit(body._request)},${lit(body._archive)},${lit(body._digest)},${body._bytes})`;break;
   case '/rest/v1/rpc/taskfold_review_child_restore':
    if(Object.keys(body).sort().join(',')!=='_archive,_mode,_repair,_restore'||!['restore','restore_newer','undo','redo','finish'].includes(body._mode)||!['_archive','_repair'].every(k=>/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(body[k]??''))||(['restore','restore_newer'].includes(body._mode))!==(body._restore===null)||body._restore!==null&&!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(body._restore??''))throw new Error('Invalid restoration review');
    expression=`public.taskfold_review_child_restore(${lit(body._mode)},${lit(body._repair)},${lit(body._archive)},${body._restore===null?'null':lit(body._restore)})`;break;
   case '/rest/v1/rpc/taskfold_restore_child_original':
    if(Object.keys(body).sort().join(',')!=='_body,_operation'||!['send','check','close'].includes(body._operation)||!body._body||Array.isArray(body._body)||typeof body._body!=='object'||Buffer.byteLength(JSON.stringify(body._body))>4096)throw new Error('Invalid restoration decision');
    expression=`public.taskfold_restore_child_original(${lit(body._operation)},${json(body._body)})`;break;
   case '/rest/v1/rpc/taskfold_review_child_adoption':
    if(Object.keys(body).sort().join(',')!=='_generation,_id'||body._id!==identity.root||body._generation!==identity.generation)throw new Error('Invalid root');
    expression=`public.taskfold_review_child_adoption(${lit(body._id)},${lit(body._generation)})`;break;
   case '/rest/v1/rpc/taskfold_child_restore_status':
    if(Object.keys(body).sort().join(',')!=='_actor,_body,_restore'||body._actor!==identity.account||!/^[a-f0-9-]{36}$/.test(body._restore??''))throw new Error('Invalid live restoration reference');
    expression=`public.taskfold_child_restore_status(${json(body._body)},${lit(body._actor)},${lit(body._restore)})`;break;
   case '/rest/v1/rpc/taskfold_review_restored_child_copies':
    if(Object.keys(body).sort().join(',')!=='_actor,_body,_restore'||body._actor!==identity.account||!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(body._restore??''))throw new Error('Invalid restored comparison');
    expression=`public.taskfold_review_restored_child_copies(${json(body._body)},${lit(body._actor)},${lit(body._restore)})`;break;
   case '/rest/v1/rpc/taskfold_review_child_copies':
   case '/rest/v1/rpc/taskfold_preview_child_repair':
    if(Object.keys(body).join(',')!=='_body')throw new Error('Invalid envelope');
    expression=`public.${request.path.split('/').at(-1)}(${json(body._body)})`;break;
   case '/rest/v1/rpc/taskfold_repair_children':
    if(Object.keys(body).sort().join(',')!=='_body,_operation'||!['send','check','close','original'].includes(body._operation))throw new Error('Invalid operation');
    expression=`public.taskfold_repair_children(${lit(body._operation)},${json(body._body)})`;break;
   default:throw new Error('Unsupported SQL route');
  }
  if(body._body&&(body._body.account!==identity.account||body._body.task_id!==identity.root||body._body.task_generation!==identity.generation))throw new Error('Foreign request scope');
  // The actor/session come from the owned fixture, never from channel input.
  const delimiter='$channel_'+randomUUID().replaceAll('-','')+'$';
  const wire=await pg.raw(`begin;create temp table channel_reply(value jsonb,code text) on commit drop;grant all on channel_reply to authenticated;set local request.jwt.claim.sub=${lit(identity.account)};set local request.jwt.claims=${lit(JSON.stringify({sub:identity.account,session_id:session}))};set local role authenticated;do ${delimiter} begin begin insert into channel_reply values(${expression},null);exception when others then insert into channel_reply values(null,sqlstate);end;end ${delimiter};select jsonb_build_object('value',value::text,'code',code) from channel_reply;commit;`);
  const reply=JSON.parse(wire),lose=loseFirstSave&&!lost&&!reply.code&&body._operation==='send';if(lose)lost=true;
  // value::text preserves PostgreSQL's exact archived JSON token stream.
  return {protocol:1,id:request.id,code:reply.code,data:Buffer.from(reply.value??'null').toString('base64'),lose};
 }
 async function drain(directory) {
  for(const name of (await readdir(directory)).filter(n=>/^[a-f0-9-]{36}\.request$/.test(n)).sort()){
   const id=name.slice(0,-8),path=directory+'/'+name;
   try {
    const request=JSON.parse((await boundedFile(path,810000)).toString('utf8'));if(request.id!==id)throw new Error('Request filename mismatch');
    const reply=await dispatch(request);await beforeReply(request,reply);await atomicFile(directory+'/'+id+'.reply',JSON.stringify(reply));
   } catch {await atomicFile(directory+'/'+id+'.reply',JSON.stringify({protocol:1,id,code:'PT503',data:'bnVsbA==',lose:false}));}
   await unlink(path);
  }
 }
 return {dispatch,drain};
}

// Xcode can rename a Simulator app container at installation/first launch.
// Follow only the same unique fixture nonce inside that same Simulator.
export async function relocatedSimulatorChannel(directory,nonce) {
 if(!/\/CoreSimulator\/Devices\/[A-Fa-f0-9-]{36}\/data\/Containers\/Data\/Application\/[A-Fa-f0-9-]{36}\/Library\/Application Support\/Child (mapping|archives) SQL native peer$/.test(directory))throw new Error('Container relocation is only for a named Simulator fixture');
 const base=resolve(directory,'../../../..'),matches=[];
 for(const name of await readdir(base)){
  if(!/^[A-Fa-f0-9-]{36}$/.test(name))continue;
  const candidate=join(base,name,'Library/Application Support/'+directory.split('/').at(-1));
  try{
   const info=await lstat(candidate);if(!info.isDirectory()||info.isSymbolicLink())continue;
   const config=JSON.parse(await boundedFile(candidate+'/channel.json',2048));
   if(config.protocol===1&&config.nonce===nonce&&config.account===identity.account&&config.root===identity.root&&config.generation===identity.generation)matches.push(candidate);
  }catch(error){if(error.code!=='ENOENT')throw error;}
 }
 if(matches.length!==1)throw new Error('Owned relocated channel is missing or ambiguous');
 return matches[0];
}
