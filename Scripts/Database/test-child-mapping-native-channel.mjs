import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,readFile,writeFile,symlink,rm,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {randomUUID} from 'node:crypto';
import {createMappingSQLChannel,identity,atomicFile,boundedFile} from './child-mapping-native-channel.mjs';
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
