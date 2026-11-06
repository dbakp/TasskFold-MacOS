// Real local Auth/REST regression for identity initPlans; no hosted mutations.
import assert from 'node:assert/strict';
import {randomUUID,createHash} from 'node:crypto';
import {writeFile,readFile} from 'node:fs/promises';
import {createFullSchemaRuntime} from './full-schema-runtime.mjs';
const output=process.argv[2];assert(/^\/tmp\/taskfold-[^/]+\.json$/.test(output));
const report={hostedChanges:false,normalUseGatesChanged:false,checks:{}};
const lit=v=>"'"+String(v).replaceAll("'","''")+"'";
const check=(name,value)=>{assert.equal(value,true,name);report.checks[name]=true;console.log('passed',name)};
const policySQL=`select coalesce(json_agg(row_to_json(p) order by schemaname,tablename,policyname),'[]') from pg_policies p`;
const ancillarySQL=`select json_build_object('tables',(select json_agg(row_to_json(t) order by oid) from (select oid,relrowsecurity,relforcerowsecurity,relacl from pg_class where relnamespace in ('public'::regnamespace,'taskfold_private'::regnamespace))t),'functions',(select json_agg(row_to_json(f) order by oid) from (select oid,proacl,md5(pg_get_functiondef(oid)) as definition from pg_proc where pronamespace in ('public'::regnamespace,'taskfold_private'::regnamespace) and prokind='f')f))`;
// pg_get_expr renders an identity subquery this way. Remove only that exact
// scalar wrapper, preserving all row-dependent predicates and other structure.
const normalize=s=>s?.replace(/\(\s*SELECT auth\.uid\(\) AS uid\s*\)/g,'auth.uid()').replace(/\s+/g,'')??null;
let runtime,before,ancillary,migration;
try{
 runtime=await createFullSchemaRuntime({beforeMigration:async(name,{raw})=>{
  if(name.endsWith('_legacy_policy_auth_initplans.sql')){
   assert(!before,'Only one owning optimization migration');migration=name;
   before=JSON.parse(await raw(policySQL));ancillary=JSON.parse(await raw(ancillarySQL));
  }
 }});
 assert(before&&migration);report.migrations=runtime.migrations;report.images=runtime.images;
 report.migrationSHA256=createHash('sha256').update(await readFile(new URL('../../supabase/migrations/'+migration,import.meta.url))).digest('hex');
 const after=JSON.parse(await runtime.raw(policySQL));report.beforePolicies=before;report.afterPolicies=after;
 check('no policy added or removed',before.length===after.length);
 const changed=[];
 for(let i=0;i<before.length;i++){
  const b=before[i],a=after[i];assert.deepEqual({...a,qual:null,with_check:null},{...b,qual:null,with_check:null});
  assert.equal(normalize(a.qual),normalize(b.qual),b.policyname+' USING');
  assert.equal(normalize(a.with_check),normalize(b.with_check),b.policyname+' CHECK');
  if(a.qual!==b.qual||a.with_check!==b.with_check)changed.push({table:b.tablename,policy:b.policyname});
 }
 report.changedPolicies=changed;
 check('exactly 14 existing policies optimized',changed.length===14);
 check('all policy roles commands and predicates preserved',true);
 check('RLS flags grants and functions unchanged',JSON.stringify(JSON.parse(await runtime.raw(ancillarySQL)))===JSON.stringify(ancillary));
 const ok=(name,response,status=200)=>{if(response.status!==status)report.lastFailure={name,status:response.status,value:response.value};check(name,response.status===status);return response.value};
 const sign=async label=>ok('real signup '+label,await runtime.request('auth','/signup',{method:'POST',body:{email:'rls-'+label+'-'+randomUUID()+'@example.invalid',password:randomUUID()+'Aa42!'}}));
 const owner=await sign('owner'),member=await sign('member'),outsider=await sign('outsider');
 const request=(who,path,opts={})=>runtime.request('rest',path,{authorization:who.access_token,...opts});
 const insert=(who,table,body)=>request(who,'/'+table,{method:'POST',headers:{Prefer:'return=representation'},body});
 const project=randomUUID(),task=randomUUID(),label=randomUUID(),section=randomUUID();
 ok('owner creates project',await insert(owner,'projects',{id:project,user_id:owner.user.id,name:'Identity cache workshop'}),201);
 ok('owner creates private label',await insert(owner,'labels',{id:label,user_id:owner.user.id,name:'Private label'}),201);
 ok('owner edits private label',await request(owner,'/labels?id=eq.'+label,{method:'PATCH',headers:{Prefer:'return=representation'},body:{name:'Updated label'}}));
 const foreignLabels=ok('outsider reads labels',await request(outsider,'/labels?select=*'));check('private labels hidden',foreignLabels.length===0);
 ok('outsider cannot create owner label',await insert(outsider,'labels',{id:randomUUID(),user_id:owner.user.id,name:'Forbidden'}),403);
 ok('owner cannot transfer label ownership',await request(owner,'/labels?id=eq.'+label,{method:'PATCH',body:{user_id:outsider.user.id}}),403);
 const foreignEdit=ok('outsider label update is filtered',await request(outsider,'/labels?id=eq.'+label,{method:'PATCH',headers:{Prefer:'return=representation'},body:{name:'Forbidden'}}));check('outsider updates zero labels',foreignEdit.length===0);
 const profiles=ok('owner profile remains readable',await request(owner,'/profiles?select=*'));check('owner sees only own profile',profiles.length===1&&profiles[0].user_id===owner.user.id);
 const hiddenProfiles=ok('outsider queries owner profile',await request(outsider,'/profiles?user_id=eq.'+owner.user.id));check('owner profile hidden from outsider',hiddenProfiles.length===0);
 ok('owner creates section',await insert(owner,'sections',{id:section,user_id:owner.user.id,project_id:project,name:'Planning'}),201);
 ok('outsider cannot create section in private project',await insert(outsider,'sections',{id:randomUUID(),user_id:outsider.user.id,project_id:project,name:'Forbidden'}),403);
 ok('owner creates task',await insert(owner,'tasks',{id:task,user_id:owner.user.id,project_id:project,title:'Review identity caching'}),201);
 ok('outsider cannot create task in private project',await insert(outsider,'tasks',{id:randomUUID(),user_id:outsider.user.id,project_id:project,title:'Forbidden'}),403);
 const invitation=randomUUID();
 ok('owner invites existing account',await insert(owner,'project_collaborators',{id:invitation,project_id:project,invited_by:owner.user.id,invited_email:member.user.email,role:'collaborator',status:'pending'}),201);
 const invites=ok('invitee reads own pending invitation',await request(member,'/project_collaborators?id=eq.'+invitation));check('own pending invitation visible',invites.length===1&&invites[0].user_id===member.user.id);
 const outsiderInvites=ok('outsider reads invitations',await request(outsider,'/project_collaborators?project_id=eq.'+project));check('private invitations hidden',outsiderInvites.length===0);
 ok('invitee accepts own invitation',await request(member,'/project_collaborators?id=eq.'+invitation,{method:'PATCH',headers:{Prefer:'return=representation'},body:{status:'accepted'}}));
 const shared=ok('member reads shared task',await request(member,'/tasks?id=eq.'+task));check('accepted membership retained',shared.length===1);
 ok('member creates own task in shared project',await insert(member,'tasks',{id:randomUUID(),user_id:member.user.id,project_id:project,title:'Shared task'}),201);
 ok('member creates own section in shared project',await insert(member,'sections',{id:randomUUID(),user_id:member.user.id,project_id:project,name:'Shared section'}),201);
 const cannotDelete=ok('member project delete is filtered',await request(member,'/projects?id=eq.'+project,{method:'DELETE',headers:{Prefer:'return=representation'}}));check('member deletes zero projects',cannotDelete.length===0);
 const revoke=ok('invitee removes own collaboration',await request(member,'/project_collaborators?id=eq.'+invitation,{method:'DELETE',headers:{Prefer:'return=representation'}}));check('own collaboration removal retained',revoke.length===1);
 const revoked=ok('former member reads shared task',await request(member,'/tasks?id=eq.'+task));check('revoked membership hides shared task',revoked.length===0);
 // A bounded fixture dataset lets EXPLAIN ANALYZE prove the identity subplan
 // executes once while actual RLS returns 1,001 owned rows. No timing claim.
 await runtime.raw(`insert into public.labels(id,user_id,name) select gen_random_uuid(),${lit(owner.user.id)}::uuid,'Plan row '||g from generate_series(1,1000)g`);
 const plan=JSON.parse(await runtime.raw(`set local role authenticated;set local request.jwt.claims=${lit(JSON.stringify({sub:owner.user.id,role:'authenticated'}))};explain (analyze,format json) select * from public.labels`))[0].Plan;
 report.queryPlan=plan;
 const nodes=p=>[p,...(p.Plans??[]).flatMap(nodes)];const init=nodes(plan).filter(n=>n['Parent Relationship']==='InitPlan');
 check('real plan uses identity initPlan once',init.length>=1&&init.every(n=>n['Actual Loops']===1));
 check('RLS plan returns all 1001 owned rows',plan['Actual Rows']===1001);
 const removed=ok('owner deletes project',await request(owner,'/projects?id=eq.'+project,{method:'DELETE',headers:{Prefer:'return=representation'}}));check('owner project deletion retained',removed.length===1);
 report.advisors=await runtime.advisors();
 check('no auth per-row advisor warnings remain',!report.advisors.result.some(x=>x.name==='auth_rls_initplan'));
 check('only known pg_net placement warning remains',report.advisors.result.length===1&&report.advisors.result[0].cache_key==='extension_in_public_pg_net');
 check('scheduler stays disabled',await runtime.raw('show cron.launch_active_jobs')==='off');
 check('no outbound jobs queued',await runtime.raw('select count(*) from net.http_request_queue')==='0');
 report.checkCount=Object.keys(report.checks).length;report.accepted=true;
}catch(error){report.error={message:error.message,code:error.code,migration:error.migration};process.exitCode=1}
finally{if(runtime)report.cleanedUp=await runtime.close();await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({accepted:report.accepted,checks:report.checkCount,error:report.error,lastFailure:report.lastFailure,cleanedUp:report.cleanedUp}))}
