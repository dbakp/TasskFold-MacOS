import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,symlink,rm,readdir,mkdir,rename} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {randomUUID} from 'node:crypto';
import {createMappingSQLChannel,identity,atomicFile,boundedFile,relocatedSimulatorChannel} from './child-mapping-native-channel.mjs';
const make=()=>({protocol:1,nonce:'test-run-nonce',id:randomUUID(),path:'/rest/v1/rpc/taskfold_review_child_adoption',body:Buffer.from(JSON.stringify({_id:identity.root,_generation:identity.generation})).toString('base64')});
test('untrusted requests cannot select SQL or fixture identity',async()=>{
 let calls=0;const pg={raw:async()=>{calls++;throw Error('Unexpected query');}},channel=createMappingSQLChannel(pg,{session:randomUUID(),nonce:'test-run-nonce'});
 const base=make();for(const change of [{nonce:'old'},{protocol:2},{id:'not-an-id'},{path:'/rest/v1/rpc/evil'},{body:'e30=extra'},{body:Buffer.from(JSON.stringify({_id:randomUUID(),_generation:identity.generation})).toString('base64')},{body:'x'.repeat(800001)}])await assert.rejects(channel.dispatch({...base,...change}));
 assert.equal(calls,0);
});
test('canonical database wire is carried without JSON re-encoding',async()=>{
 const exact='{"ordered": [9007199254740993, 1e1000, 1.00], "é": 1, "e\\u0301": 2}';let calls=0,published=0;
 const pg={raw:async(sql)=>{calls++;assert.ok(sql.includes('set local role authenticated'));return JSON.stringify({value:exact,code:null});}};
 const channel=createMappingSQLChannel(pg,{session:randomUUID(),nonce:'test-run-nonce',beforeReply:async()=>{published++;}}),dir=await mkdtemp(tmpdir()+'/taskfold-channel-wire-');
 try{const request=make();await atomicFile(dir+'/'+request.id+'.request',JSON.stringify(request));await channel.drain(dir);const reply=JSON.parse(await readFile(dir+'/'+request.id+'.reply'));assert.equal(Buffer.from(reply.data,'base64').toString(),exact);assert.equal(reply.code,null);assert.equal(published,1);assert.equal(calls,1);assert.deepEqual(await readdir(dir),[request.id+'.reply']);}finally{await rm(dir,{recursive:true,force:true});}
});
test('malformed envelopes and symlinks fail closed without reading target or querying',async()=>{
 const dir=await mkdtemp(tmpdir()+'/taskfold-channel-refusal-');let calls=0;const channel=createMappingSQLChannel({raw:async()=>{calls++;}},{session:randomUUID(),nonce:'test-run-nonce'});
 try{
  const id=randomUUID(),target=dir+'/private-source';await writeFile(target,'untouched');await symlink(target,dir+'/'+id+'.request');await assert.rejects(boundedFile(dir+'/'+id+'.request',100));await channel.drain(dir);assert.equal(JSON.parse(await readFile(dir+'/'+id+'.reply')).code,'PT503');assert.equal(await readFile(target,'utf8'),'untouched');assert.equal(calls,0);
  const mismatch=randomUUID();await atomicFile(dir+'/'+mismatch+'.request',JSON.stringify(make()));await channel.drain(dir);assert.equal(JSON.parse(await readFile(dir+'/'+mismatch+'.reply')).code,'PT503');assert.equal(calls,0);
 }finally{await rm(dir,{recursive:true,force:true});}
});

test('Simulator relocation follows only the same unique owned nonce',async()=>{
 const temp=await mkdtemp(tmpdir()+'/taskfold-channel-relocation-'),base=temp+'/CoreSimulator/Devices/'+randomUUID()+'/data/Containers/Data/Application',oldID=randomUUID(),newID=randomUUID(),nonce=randomUUID(),suffix='/Library/Application Support/Child mapping SQL native peer';
 const previous=base+'/'+oldID+suffix,current=base+'/'+newID+suffix;
 try{
  await mkdir(previous,{recursive:true});await atomicFile(previous+'/channel.json',JSON.stringify({protocol:1,nonce,...identity}));await writeFile(previous+'/proof','preserved');
  await rename(base+'/'+oldID,base+'/'+newID);
  assert.equal(await relocatedSimulatorChannel(previous,nonce),current);assert.equal(await readFile(current+'/proof','utf8'),'preserved');
  await assert.rejects(relocatedSimulatorChannel(previous,randomUUID()));await assert.rejects(relocatedSimulatorChannel(temp,nonce));
  const duplicate=base+'/'+randomUUID()+suffix;await mkdir(duplicate,{recursive:true});await writeFile(duplicate+'/channel.json',await readFile(current+'/channel.json'));await assert.rejects(relocatedSimulatorChannel(previous,nonce));
 }finally{await rm(temp,{recursive:true,force:true});}
});

test('native discovery rejects foreign roots and invalid pagination before SQL',async()=>{
 let calls=0;const channel=createMappingSQLChannel({raw:async()=>{calls++;}},{session:randomUUID(),nonce:'test-run-nonce'});
 const base={_after:null,_id:identity.root,_limit:1};
 for(const change of [{_id:randomUUID()},{_limit:0},{_limit:101},{_limit:'1; drop table tasks'},{_after:'not-a-uuid'},{extra:true}]){
  const request={...make(),path:'/rest/v1/rpc/taskfold_child_adoption_targets',body:Buffer.from(JSON.stringify({...base,...change})).toString('base64')};await assert.rejects(channel.dispatch(request));
 }
 assert.equal(calls,0);
});

test('search channel validates query and cursor before SQL and quotes literal text',async()=>{
 let calls=0;
 const pg={raw:async(sql)=>{calls++;assert.ok(sql.includes("public.taskfold_search_child_adoption_targets('O''Brien %_"));return JSON.stringify({value:'{}',code:null});}};
 const channel=createMappingSQLChannel(pg,{session:randomUUID(),nonce:'test-run-nonce'});
 const base={_query:"O'Brien %_",_after:null,_limit:100};
 const request=body=>({...make(),path:'/rest/v1/rpc/taskfold_search_child_adoption_targets',body:Buffer.from(JSON.stringify(body)).toString('base64')});
 for(const change of [{_query:null},{_query:''},{_query:'x'.repeat(257)},{_query:'🪴'.repeat(257)},{_query:'a\0b'},{_limit:0},{_after:"bad' cursor"},{_id:identity.root}])await assert.rejects(channel.dispatch(request({...base,...change})));
 assert.equal(calls,0);await channel.dispatch(request(base));assert.equal(calls,1);
});

test('archive routes bind only bounded typed arguments before querying',async()=>{
 let calls=0;const channel=createMappingSQLChannel({raw:async()=>{calls++;return JSON.stringify({value:'{}',code:null});}},{session:randomUUID(),nonce:'test-run-nonce'});
 const request=(path,body)=>({...make(),path:'/rest/v1/rpc/'+path,body:Buffer.from(JSON.stringify(body)).toString('base64')});
 for(const body of [{_after:null,_limit:0},{_after:null,_limit:51},{_after:'not-a-uuid',_limit:2},{_after:null,_limit:2,account:identity.account}])await assert.rejects(channel.dispatch(request('taskfold_child_repair_archives',body)));
 for(const body of [{_archive:randomUUID(),_request:'bad'},{_archive:randomUUID(),_request:randomUUID(),account:identity.account}])await assert.rejects(channel.dispatch(request('taskfold_child_repair_original',body)));
 assert.equal(calls,0);
 await channel.dispatch(request('taskfold_child_repair_archives',{_after:null,_limit:2}));await channel.dispatch(request('taskfold_child_repair_original',{_archive:randomUUID(),_request:randomUUID()}));assert.equal(calls,2);
});
