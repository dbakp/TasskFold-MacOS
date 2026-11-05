import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {readFile,writeFile} from 'node:fs/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
const output=process.argv[2];assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));
const report={checks:{},genuineLocalAuth:true,genuineLocalPostgREST:true,genuineLocalStorage:true,validatedLoopbackTLS:false,storageBackend:'Pinned Storage API with owned tmpfs file backend; not hosted S3',normalUseEnabled:false,hostedChanges:false,fileTransferImplemented:false,nativeAppAccepted:false};
const check=(name,value,expected=true)=>{assert.deepEqual(value,expected,name);report.checks[name]=true;console.log('passed',name)};
const ok=(name,response,status=200)=>{if(response.status!==status)report.lastFailure={name,status:response.status,value:response.value};check(name,response.status,status);return response.value};
const lit=x=>"'"+String(x).replaceAll("'","''")+"'";
const sourcePaths=['Scripts/Database/full-schema-runtime.mjs','Scripts/Database/full-schema-gateway.mjs','Scripts/Database/test-full-schema-project-files.mjs'];
const hash=async path=>createHash('sha256').update(await readFile(new URL('../../'+path,import.meta.url))).digest('hex');
report.sourceSHA256=Object.fromEntries(await Promise.all(sourcePaths.map(async p=>[p,await hash(p)])));
let runtime;
try {
 runtime=await createFullSchemaRuntime({onMigration:name=>console.log('replayed',name)});report.migrations=runtime.migrations;report.images=runtime.images;
 const users={};
 for(const name of ['owner','outside']){
  const value=ok('genuine signup '+name,await runtime.request('auth','/signup',{method:'POST',body:{email:'file-'+name+'@example.invalid',password:'Disposable-'+randomUUID()+'!'}}));
  const claims=JSON.parse(Buffer.from(value.access_token.split('.')[1],'base64url'));check('genuine live session '+name,typeof claims.session_id,'string');users[name]={id:value.user.id,token:value.access_token};
 }
 const owner=users.owner,team=randomUUID(),headers={Prefer:'return=representation'};
 const request=(path,body,method='POST',user=owner)=>runtime.request('rest',path,{authorization:user.token,method,headers,...(body===undefined?{}:{body})});
 const project=ok('genuine personal project creation',await request('/projects',{user_id:owner.id,name:'File inventory API proof'}),201)[0];
 const task=ok('genuine personal task creation',await request('/tasks',{user_id:owner.id,project_id:project.id,title:'Preserve the private original'}),201)[0];
 await runtime.raw(`insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(owner.id)},'File review workshop');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(owner.id)},'admin');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_project_adoption_enabled=true;`);
 const bytes=Buffer.from('%PDF-1.7\nSynthetic Taskfold private attachment\n%%EOF\n'),name=owner.id+'/'+randomUUID()+'.pdf';
 const origin=new URL(runtime.urls.storage);check('actual Storage endpoint is owned loopback',origin.hostname,'127.0.0.1');
 const storage=async(method,path,user=owner,body)=>{
  const response=await fetch(runtime.urls.storage+path,{method,headers:{apikey:runtime.anon,Authorization:'Bearer '+user.token,...(body?{'Content-Type':'application/pdf','x-upsert':'false'}:{})},...(body?{body}:{}),signal:AbortSignal.timeout(30000)});
  return {status:response.status,bytes:Buffer.from(await response.arrayBuffer())};
 };
 const upload=await storage('POST','/object/task-attachments/'+name,owner,bytes);check('actual private Storage upload',upload.status,200);
 const object=JSON.parse(await runtime.raw(`select jsonb_build_object('id',id,'bucket_id',bucket_id,'name',name,'owner',owner,'owner_id',owner_id,'metadata',metadata,'version',version) from storage.objects where bucket_id='task-attachments' and name=${lit(name)}`));
 check('Storage created a real object identity',typeof object.id,'string');check('Storage metadata records original size',Number(object.metadata.size),bytes.length);
 const read=await storage('GET','/object/authenticated/task-attachments/'+name);check('original owner downloads actual provider bytes',read.status,200);check('original file bytes are exact',read.bytes,bytes);
 const denied=await storage('GET','/object/authenticated/task-attachments/'+name,users.outside);check('outside account cannot download original private bytes',denied.status>=400);
 ok('genuine inline-comment file reference save',await request('/tasks?id=eq.'+task.id,{comments:[{id:randomUUID(),text:'Keep the original discussion',attachment:{storage_object_id:object.id,name:'Private original.pdf'}}]},'PATCH'));
 const body={team_id:team,roots:[project.id],visibility:'private',folder_id:null,parent_id:null};
 const rpc=(operation,scope=body,user=owner)=>request('/rpc/taskfold_team_project_adoption',{operation,body:scope},'POST',user);
 const inspection=ok('genuine project inspection',await rpc('inspect'));check('real Storage reference is included',inspection.contents.file_custody,{protocol:1,stored:1,legacy:0,unavailable:0});check('comment file contributes to actual attachment count',inspection.contents.attachments,1);check('unreviewed file transfer stays closed',inspection.commit_supported,false);
 const serialized=JSON.stringify(inspection);check('inspection hides provider path',serialized.includes(name),false);check('inspection hides object identity',serialized.includes(object.id),false);
 const reviewed=ok('genuine project access review',await rpc('review',{...body,inspection_token:inspection.inspection_token,decisions:[]}));check('file access requires separate custody approval',reviewed.requires_provider_custody,true);
 const command={...body,request_id:randomUUID(),inspection_token:reviewed.inspection_token,decisions:[],expires_at:reviewed.expires_at,review_token:reviewed.review_token};
 const refused=await rpc('adopt',command);check('real API refuses unapproved custody change',refused.status,409);
 const unauthorized=await rpc('inspect',body,users.outside);check('outside account cannot inspect project file metadata',unauthorized.status,403);
 const after=ok('source task remains readable',await request('/tasks?id=eq.'+task.id,undefined,'GET'))[0];check('task retains its original project',after.project_id,project.id);check('task keeps original file identity',after.comments[0].attachment.storage_object_id,object.id);
 const again=await storage('GET','/object/authenticated/task-attachments/'+name);check('review does not replace original bytes',again.bytes,bytes);
 const current=JSON.parse(await runtime.raw(`select jsonb_build_object('id',id,'bucket_id',bucket_id,'name',name,'owner',owner,'owner_id',owner_id,'metadata',metadata,'version',version) from storage.objects where id=${lit(object.id)}`));check('review preserves material provider identity and metadata',current,object);
 check('no replacement file was uploaded',Number(await runtime.raw("select count(*) from storage.objects where bucket_id='task-attachments'")),1);
 check('scheduler remains disabled',await runtime.raw('show cron.launch_active_jobs'),'off');report.advisors=await runtime.advisors();
 report.sourceUnchanged=true;for(const path of sourcePaths)report.sourceUnchanged&&=(await hash(path))===report.sourceSHA256[path];check('tested service sources remain unchanged',report.sourceUnchanged);
} catch(error){report.error={message:error.message,code:error.code,migration:error.migration};throw error}finally{if(runtime)report.runtimeRemoved=await runtime.close();report.checkCount=Object.keys(report.checks).length;await writeFile(output,JSON.stringify(report,null,2)+'\n')}
console.log(JSON.stringify({checks:report.checkCount,runtimeRemoved:report.runtimeRemoved}));
