// Production handler + genuine disposable Auth/PostgREST/Storage over validated local TLS.
import assert from 'node:assert/strict';
import https from 'node:https';
import {spawn,execFile} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {promisify} from 'node:util';
import {mkdtemp,chmod,readFile,writeFile,rm} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
const exec=promisify(execFile);
export async function createFullSchemaAudioFixture(runtime,options={}){
 const folder=await mkdtemp('/tmp/taskfold-full-audio-');await chmod(folder,0o700);
 const certPath=folder+'/cert.pem',keyPath=folder+'/key.pem',caPath=folder+'/ca.pem',caKey=folder+'/ca-key.pem';let child,server,closed=false;
 const state={authRequests:0,rpcRequests:0,uploads:0,downloads:0,deletes:0,afterStorageGet:null,afterStoragePut:null};
 const maintenanceKey=randomBytes(32).toString('hex');
 const close=async()=>{
  if(closed)return;closed=true;
  if(child&&child.exitCode===null){child.kill('SIGTERM');await new Promise(resolve=>{const timer=setTimeout(()=>{child.kill('SIGKILL');resolve()},3000);child.once('exit',()=>{clearTimeout(timer);resolve()})})}
  if(server){server.closeAllConnections();await new Promise(resolve=>server.close(resolve))}
  await rm(folder,{recursive:true,force:true});
 };
 try{
  await exec('openssl',['req','-x509','-newkey','rsa:2048','-nodes','-keyout',caKey,'-out',caPath,'-days','1','-subj','/CN=Taskfold Disposable Local CA','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign']);
  await exec('openssl',['req','-newkey','rsa:2048','-nodes','-keyout',keyPath,'-out',folder+'/server.csr','-subj','/CN=localhost']);
  await writeFile(folder+'/extensions.cnf','subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n');
  await exec('openssl',['x509','-req','-in',folder+'/server.csr','-CA',caPath,'-CAkey',caKey,'-CAcreateserial','-out',certPath,'-days','1','-extfile',folder+'/extensions.cnf']);
  await chmod(keyPath,0o600);await chmod(caKey,0o600);
  const cert=await readFile(certPath),key=await readFile(keyPath),ca=await readFile(caPath);
  const origin=new URL(runtime.urls.auth).origin;assert(/^http:\/\/127\.0\.0\.1:\d+$/.test(origin));
  server=https.createServer({cert,key,minVersion:'TLSv1.2'},async(req,res)=>{
   try{
    assert.equal(req.headers.apikey,runtime.service);
    const audioPath=/^\/(auth\/v1\/user|rest\/v1\/rpc\/taskfold_audio_[a-z_]+|storage\/v1\/object\/taskfold-audio-v1(?:\/[a-zA-Z0-9/_.-]+)?)$/.test(req.url);
    const filePath=options.projectFiles===true && /^\/(rest\/v1\/rpc\/taskfold_(project_file_preparation|project_file_producer_terminal|task_file_command)|storage\/v1\/object\/(?:authenticated\/)?task-attachments\/[a-zA-Z0-9/_.-]+)$/.test(req.url);
    assert(audioPath || filePath);
    const parts=[];let length=0;for await(const part of req){length+=part.length;assert(length<=16000000);parts.push(part)}
    const headers={...req.headers};delete headers.host;delete headers.connection;
    const reply=await fetch(origin+req.url,{method:req.method,headers,redirect:'error',signal:AbortSignal.timeout(30000),...(parts.length?{body:Buffer.concat(parts)}:{})});
    const bytes=Buffer.from(await reply.arrayBuffer());
    if(req.url.startsWith('/auth/'))state.authRequests++;
    if(req.url.startsWith('/rest/'))state.rpcRequests++;
    if(req.url.startsWith('/storage/')&&req.method==='POST'&&reply.ok){state.uploads++;if(state.afterStoragePut)await state.afterStoragePut()}
    if(req.url.startsWith('/storage/')&&req.method==='DELETE'&&reply.ok)state.deletes++;
    if(req.url.startsWith('/storage/')&&req.method==='GET'&&reply.ok){state.downloads++;if(state.afterStorageGet)await state.afterStorageGet()}
    const outgoing=Object.fromEntries(reply.headers);delete outgoing['content-encoding'];delete outgoing['content-length'];delete outgoing['transfer-encoding'];
    res.writeHead(reply.status,{...outgoing,'Content-Length':bytes.length});res.end(bytes);
   }catch{if(!res.headersSent)res.writeHead(503,{'Content-Type':'application/json'});res.end('{"error":"Owned upstream operation failed"}')}
  });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve)});
  child=spawn('deno',['run','--cert',caPath,'--allow-net=127.0.0.1','--allow-read='+certPath+','+keyPath,'--allow-env=TASKFOLD_AUDIO_LOCAL_URL,TASKFOLD_AUDIO_LOCAL_SERVICE,TASKFOLD_AUDIO_LOCAL_CERT,TASKFOLD_AUDIO_LOCAL_KEY,TASKFOLD_AUDIO_LOCAL_MAINTENANCE,TASKFOLD_AUDIO_LOCAL_PROJECT_FILES',fileURLToPath(new URL('./full-schema-audio-server.ts',import.meta.url))],{env:{PATH:process.env.PATH,TASKFOLD_AUDIO_LOCAL_URL:'https://127.0.0.1:'+server.address().port,TASKFOLD_AUDIO_LOCAL_SERVICE:runtime.service,TASKFOLD_AUDIO_LOCAL_CERT:certPath,TASKFOLD_AUDIO_LOCAL_KEY:keyPath,TASKFOLD_AUDIO_LOCAL_MAINTENANCE:maintenanceKey,TASKFOLD_AUDIO_LOCAL_PROJECT_FILES:options.projectFiles===true?'1':'0'},stdio:['ignore','pipe','pipe']});
  let diagnostic='';child.stderr.on('data',x=>diagnostic=(diagnostic+x).slice(-1500));
  const port=await new Promise((resolve,reject)=>{
   let buffer='';const timer=setTimeout(()=>reject(Error('Owned TLS handler startup timed out')),15000);
   child.once('error',()=>{clearTimeout(timer);reject(Error('Owned TLS handler could not start'))});child.once('exit',()=>{clearTimeout(timer);reject(Error('Owned TLS handler exited: '+diagnostic))});
   child.stdout.on('data',part=>{buffer+=part;for(const line of buffer.split('\n'))try{const value=JSON.parse(line);if(Number.isInteger(value.ready)){clearTimeout(timer);resolve(value.ready)}}catch{}});
  });
  const untrustedTLSRejected=await new Promise(resolve=>{
   const request=https.request({hostname:'127.0.0.1',port,path:'/',servername:'localhost',rejectUnauthorized:true},response=>{response.resume();resolve(false)});
   request.setTimeout(5000,()=>{request.destroy();resolve(false)});request.once('error',error=>resolve(['UNABLE_TO_VERIFY_LEAF_SIGNATURE','SELF_SIGNED_CERT_IN_CHAIN','CERT_UNTRUSTED'].includes(error.code)));request.end();
  });
  const call=(token,action,body,route=null)=>new Promise((resolve,reject)=>{
   const bytes=Buffer.from(JSON.stringify(body));const request=https.request({hostname:'127.0.0.1',port,path:route?'/'+route+'?action='+action:action==='__maintenance'?'/maintenance':'/?action='+action,method:'POST',ca,servername:'localhost',headers:{...(action==='__maintenance'?{'X-Taskfold-Audio-Maintenance':maintenanceKey}:{Authorization:'Bearer '+token}),'Content-Type':'application/json','Content-Length':bytes.length}},response=>{const chunks=[];let length=0;response.on('data',x=>{length+=x.length;if(length>16000000)request.destroy(Error('Oversized owned reply'));else chunks.push(x)});response.once('end',()=>resolve(new Response(response.statusCode===204?null:Buffer.concat(chunks),{status:response.statusCode,headers:response.headers})));response.once('error',reject)});
   request.setTimeout(30000,()=>request.destroy(Error('Owned TLS handler request timed out')));request.once('error',reject);request.end(bytes);
  });
  const assertProjectFiles=()=>{if(options.projectFiles!==true)throw Error('Combined file fixture is not enabled')};
  return {call,projectFiles:(token,action,body)=>{assertProjectFiles();return call(token,action,body,'project-files')},taskFiles:(token,action,body)=>{assertProjectFiles();return call(token,action,body,'task-files')},maintain:()=>call(null,'__maintenance',{}),state,close,tlsVerified:true,untrustedTLSRejected,endpoint:'https://127.0.0.1:'+port,certificateAuthority:ca.toString('utf8')};
 }catch(error){await close();throw error}
}
