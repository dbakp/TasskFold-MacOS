// Real Supabase PostgreSQL/Auth/PostgREST/Storage, isolated to an internal Docker
// network and disposable tmpfs data. No user database, mounted data or live key.
import {execFile,spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {randomBytes,randomUUID,createHmac,createHash} from 'node:crypto';
import {readFile,readdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {storageImage} from './storage-provider-fixture.mjs';
const exec=promisify(execFile);
export const fullSchemaImages={
 db:'supabase/postgres@sha256:a9946f08d31e8eb1149229c94e5c26603a9233116807cbbd93d75179cbac516a',
 auth:'supabase/gotrue@sha256:1736a63078f5922b198c4cbe50f80ab9a2d3b54fe8b7b6cfb2e9dc5dbbc12c6b',
 rest:'postgrest/postgrest@sha256:c7cd7e265a85b05248abf53f4473fcec7e327c282d0bd0cf60f1551996d09fcf',
 storage:storageImage,
 gateway:'node@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43',
};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const lit=v=>"'"+String(v).replaceAll("'","''")+"'";
export async function createFullSchemaRuntime({onMigration=()=>{},beforeMigration=async()=>{}}={}) {
 await exec('python3',[fileURLToPath(new URL('../check_test_storage.py',import.meta.url)),'--path','/tmp']);
 const owner=randomUUID(),network='taskfold-full-schema-'+owner.slice(0,8),names={},urls={},created=[];
 const password=randomBytes(32).toString('hex'),secret=randomBytes(48).toString('hex');
 let networkCreated=false;
 const docker=async(args,timeout=15000)=>{try{return(await exec('docker',args,{timeout,maxBuffer:1024*1024})).stdout}catch(e){throw Error('Owned Docker operation failed ('+(e.code??'unknown')+')')}};
 const inspect=async name=>JSON.parse(await docker(['inspect',name]))[0];
 function token(role){const encode=x=>Buffer.from(JSON.stringify(x)).toString('base64url');const value=encode({alg:'HS256',typ:'JWT'})+'.'+encode({role,iss:'taskfold-local-full-schema',iat:Math.floor(Date.now()/1000),exp:Math.floor(Date.now()/1000)+3600});return value+'.'+createHmac('sha256',secret).update(value).digest('base64url')}
 const service=token('service_role'),anon=token('anon');
 async function close(){
  for(const name of [...created].reverse()){
   const info=await inspect(name);if(info.Config.Labels['com.taskfold.fullschema']!==owner)throw Error('Full-schema container ownership mismatch');
   await docker(['rm','--force',name]);created.splice(created.indexOf(name),1);
  }
  if(networkCreated){const info=JSON.parse(await docker(['network','inspect',network]))[0];if(info.Labels['com.taskfold.fullschema']!==owner)throw Error('Full-schema network ownership mismatch');await docker(['network','rm',network]);networkCreated=false}
  return true;
 }
 async function run(kind,env,port,command=[],mounts=[]){
  const name=network+'-'+kind;names[kind]=name;
  const args=['run','--detach','--rm','--name',name,'--label','com.taskfold.fullschema='+owner,'--network',kind==='gateway'?'bridge':network,'--memory',kind==='db'||kind==='storage'?'768m':'256m','--cpus','1',...mounts.flatMap(x=>['--tmpfs',x]),...(kind==='gateway'?['--publish','127.0.0.1::'+port,'--publish','127.0.0.1::3002']:[]),...Object.entries(env).flatMap(([k,v])=>['-e',k+'='+v]),fullSchemaImages[kind],...command];
  await docker(args,30000);created.push(name);
  if(kind==='gateway'){await docker(['network','connect',network,name]);let p;for(let i=0;i<30;i++){p=Number((await inspect(name)).NetworkSettings.Ports[port+'/tcp']?.[0]?.HostPort);if(p)break;await sleep(100)}if(!p)throw Error('Missing loopback-only gateway port');const origin='http://127.0.0.1:'+p;urls.auth=origin+'/auth/v1';urls.rest=origin+'/rest/v1';urls.storage=origin+'/storage/v1'}
 }
 async function raw(sql,role="postgres"){
  if(!["postgres","supabase_admin"].includes(role))throw Error("Invalid owned SQL role");
  return new Promise((resolve,reject)=>{
   const child=spawn('docker',['exec','-i',names.db,'psql','-X','-qAt','--single-transaction','-v','ON_ERROR_STOP=1','-v','VERBOSITY=verbose','-U',role,'-d','postgres'],{stdio:['pipe','pipe','pipe']});let out='',err='';
   const timer=setTimeout(()=>{child.kill();reject(Error('Full-schema SQL deadline exceeded'))},30000);
   child.stdout.on('data',x=>{out+=x;if(out.length>4*1024*1024)child.kill()});child.stderr.on('data',x=>{err=(err+x).slice(-12000)});child.once('error',()=>{clearTimeout(timer);reject(Error('Full-schema SQL process failed'))});child.once('exit',code=>{clearTimeout(timer);if(code===0)resolve(out.trim());else{const e=Error('Full-schema SQL failed: '+(err.match(/ERROR:.*\n/)?.[0]?.trim()??'process exit '+code));e.code=err.match(/ERROR:\s+([A-Z0-9]{5}):/)?.[1];reject(e)}});child.stdin.end(sql);
  });
 }
 async function request(kind,path,{method='GET',body,authorization=anon,headers={}}={}){
  if(!urls[kind]||!path.startsWith('/')||path.startsWith('//'))throw Error('Owned local service path required');
  const response=await fetch(urls[kind]+path,{method,redirect:'error',signal:AbortSignal.timeout(30000),headers:{apikey:anon,Authorization:'Bearer '+authorization,...(body===undefined?{}:{'Content-Type':'application/json'}),...headers},...(body===undefined?{}:{body:JSON.stringify(body)})});
  const text=await response.text();let value;try{value=JSON.parse(text)}catch{value=text};return {status:response.status,value};
 }
 async function ready(kind,path){
  for(let i=0;i<150;i++){try{if((await request(kind,path)).status===200)return}catch{};const info=await inspect(names[kind]);if(!info.State.Running)throw Error('Owned '+kind+' service exited before ready');await sleep(100)}
  throw Error('Owned '+kind+' readiness deadline exceeded');
 }
 try{
  for(const image of Object.values(fullSchemaImages))await docker(['image','inspect',image]);
  await docker(['network','create','--internal','--label','com.taskfold.fullschema='+owner,network]);networkCreated=true;
  await run('db',{POSTGRES_PASSWORD:password,PGPASSWORD:password,POSTGRES_DB:'postgres'},null,['postgres','-c','config_file=/etc/postgresql/postgresql.conf','-c','cron.launch_active_jobs=off','-c','shared_buffers=32MB','-c','max_connections=60'],['/var/lib/postgresql/data:rw,size=512m']);
  let started=false;
  for(let i=0;i<200;i++){try{if(await raw('select 1')==='1'){started=true;break}}catch{};if(!(await inspect(names.db)).State.Running)throw Error('Owned database exited during platform initialization');await sleep(100)}
  if(!started)throw Error('Owned database readiness deadline exceeded');
  // Wait for the platform entrypoint's final server, not its temporary init server.
  for(let i=0;i<200;i++){const logs=await docker(['logs','--tail','10',names.db]);if(logs.includes('init process complete'))break;await sleep(100)}
  await raw(`alter role supabase_auth_admin password ${lit(password)};alter role supabase_storage_admin password ${lit(password)};alter role authenticator password ${lit(password)};`,"supabase_admin");
  await run('gateway',{PUBLIC_KEY:anon,SERVER_KEY:service,AUTH_HOST:network+'-auth',REST_HOST:network+'-rest',STORAGE_HOST:network+'-storage',DB_HOST:network+'-db'},3001,['node','--input-type=module','-e',await readFile(new URL('./full-schema-gateway.mjs',import.meta.url),'utf8')]);
  await run('auth',{GOTRUE_API_HOST:'0.0.0.0',GOTRUE_API_PORT:'9999',API_EXTERNAL_URL:'http://localhost/auth/v1',GOTRUE_DB_DRIVER:'postgres',GOTRUE_DB_DATABASE_URL:'postgres://supabase_auth_admin:'+password+'@'+names.db+':5432/postgres',GOTRUE_SITE_URL:'http://localhost',GOTRUE_JWT_SECRET:secret,GOTRUE_JWT_ADMIN_ROLES:'service_role',GOTRUE_JWT_AUD:'authenticated',GOTRUE_JWT_DEFAULT_GROUP_NAME:'authenticated',GOTRUE_JWT_EXP:'3600',GOTRUE_EXTERNAL_EMAIL_ENABLED:'true',GOTRUE_MAILER_AUTOCONFIRM:'true',GOTRUE_DISABLE_SIGNUP:'false',GOTRUE_RATE_LIMIT_EMAIL_SENT:'1000'},9999);
  await ready('auth','/health');
  await run('storage',{DATABASE_URL:'postgresql://supabase_storage_admin:'+password+'@'+names.db+':5432/postgres',AUTH_JWT_SECRET:secret,AUTH_JWT_ALGORITHM:'HS256',DB_INSTALL_ROLES:'false',STORAGE_BACKEND:'file',STORAGE_FILE_BACKEND_PATH:'/var/lib/storage',TENANT_ID:'taskfold-full-schema',REGION:'local',GLOBAL_S3_BUCKET:'taskfold-full-schema',FILE_SIZE_LIMIT:'5242880',SERVER_PORT:'5000',SERVER_HOST:'0.0.0.0',PG_QUEUE_ENABLE:'false',ENABLE_IMAGE_TRANSFORMATION:'false',LOG_LEVEL:'error'},5000,[],['/var/lib/storage:rw,size=64m,mode=1777','/tmp:rw,size=64m,mode=1777']);
  await ready('storage','/status');
  const migrations=[];
  for(const name of (await readdir(new URL('../../supabase/migrations/',import.meta.url))).filter(x=>/^\d{14}_.+\.sql$/.test(x)).sort()){
   const bytes=await readFile(new URL('../../supabase/migrations/'+name,import.meta.url));
   await beforeMigration(name,{raw});
   try{await raw(bytes.toString())}catch(e){e.migration=name;throw e}
   migrations.push({file:name,sha256:createHash('sha256').update(bytes).digest('hex')});onMigration(name);
  }
  if(await raw("show cron.launch_active_jobs")!=='off')throw Error('Scheduler must stay disabled');
  await run('rest',{PGRST_DB_URI:'postgres://authenticator:'+password+'@'+names.db+':5432/postgres',PGRST_DB_SCHEMAS:'public',PGRST_DB_ANON_ROLE:'anon',PGRST_JWT_SECRET:secret,PGRST_DB_POOL:'5',PGRST_DB_MAX_ROWS:'5000'},3000);
  await ready('rest','/');
  async function advisors(){
   const info=await inspect(names.gateway),bindings=info.NetworkSettings.Ports['3002/tcp'];
   if(info.Config.Labels['com.taskfold.fullschema']!==owner||bindings?.length!==1||bindings[0].HostIp!=='127.0.0.1')throw Error('Owned advisors port required');
   try{const result=await exec('supabase',['db','advisors','--db-url','postgresql://postgres:'+password+'@127.0.0.1:'+bindings[0].HostPort+'/postgres?sslmode=disable','--type','all','--fail-on','none','--output','json'],{timeout:60000,maxBuffer:4*1024*1024});return {ran:true,source:'Official CLI on complete owned local schema',result:JSON.parse(result.stdout)}}catch{throw Error('Full-schema advisor query failed')}
  }
  return {request,raw,urls,service,anon,migrations,close,advisors,images:fullSchemaImages};
 }catch(error){try{error.cleanedUp=await close()}catch{error.cleanupFailed=true}throw error}
}
