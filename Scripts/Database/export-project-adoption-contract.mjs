import {writeFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {createPostgresFixture,literal as lit} from './postgres-fixture.mjs';
import {loadProjectAdoptionSchema} from './project-adoption-schema.mjs';
const id=n=>'fdad0000-0000-4000-8000-'+String(n).padStart(12,'0'),account=id(1),member=id(2),outside=id(3),team=id(4),root=id(5),child=id(6),session=id(7);
const json=x=>lit(JSON.stringify(x))+'::jsonb';let pg;
try {
 pg=await createPostgresFixture();await loadProjectAdoptionSchema(pg.raw);
 for(const a of [account,member,outside])await pg.raw(`insert into auth.users(id,email,email_confirmed_at) values(${lit(a)},${lit(a+'@example.invalid')},now());insert into public.profiles(user_id) values(${lit(a)});`);
 await pg.raw(`insert into auth.sessions(id,user_id) values(${lit(session)},${lit(account)});insert into taskfold_private.teams(id,owner_id,name) values(${lit(team)},${lit(account)},'Design Studio');insert into taskfold_private.team_members(team_id,user_id,role) values(${lit(team)},${lit(account)},'admin'),(${lit(team)},${lit(member)},'member');update taskfold_private.team_config set enabled=true;update taskfold_private.team_project_config set native_reads_enabled=true,native_task_edits_enabled=true,native_project_adoption_enabled=true;insert into public.projects(id,user_id,name) values(${lit(root)},${lit(account)},'Studio plan');insert into public.projects(id,user_id,name,parent_id,is_archived) values(${lit(child)},${lit(account)},'Research archive',${lit(root)},true);`);
 const identity=`set local request.jwt.claim.sub=${lit(account)};set local request.jwt.claims=${lit(JSON.stringify({sub:account,session_id:session}))};`;
 await pg.raw(`begin;${identity}insert into public.project_collaborators(id,project_id,invited_email,invited_by) values(${lit(id(8))},${lit(root)},${lit(member+'@example.invalid')},${lit(account)}),(${lit(id(9))},${lit(root)},${lit(outside+'@example.invalid')},${lit(account)});update public.project_collaborators set status='accepted';insert into public.tasks(id,user_id,project_id,title,description,assigned_to,attachments) values(${lit(id(10))},${lit(account)},${lit(root)},'Synthetic transfer task','Never put task text in a retry',${lit(outside)},'[{"id":"synthetic-file","url":"data:text/plain;base64,QQ=="}]');commit;`);
 const body={team_id:team,roots:[root],visibility:'private',folder_id:null,parent_id:null};
 const call=(op,b)=>pg.scalar(`begin;${identity}set local role authenticated;select public.taskfold_team_project_adoption(${lit(op)},${json(b)});commit;`);
 const inspect=await call('inspect',body),decisions=[{project_id:root,user_id:member,role:'editor'},{project_id:root,user_id:outside,role:null}],review=await call('review',{...body,inspection_token:inspect.inspection_token,decisions});
 const command={...body,inspection_token:inspect.inspection_token,decisions,review_token:review.review_token,expires_at:review.expires_at,request_id:randomUUID()},receipt=await call('adopt',command);
 const removed=await pg.close();pg=null;
 await writeFile(process.argv[2],JSON.stringify({protocol:1,account,origin:'https://synthetic.example',body,inspect,decisions,review,command,receipt,syntheticOnly:true,containerRemoved:removed},null,2)+'\n');console.log(JSON.stringify({fixtureWritten:true,containerRemoved:removed}));
}finally{if(pg)await pg.close()}
