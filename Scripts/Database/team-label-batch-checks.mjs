import {randomUUID} from 'node:crypto';
export async function labelBatchChecks({pg,lit,check,body,rpc,row,ids,projects,users,team}) {
 const opaque=randomUUID(),original=[['Design','Keep'],['design',opaque]];
 for(let n=0;n<ids.length;n++)await pg.raw(`update public.tasks set labels=array[${original[n].map(lit).join(',')}]::text[] where id=${lit(ids[n])}`);
 const before=await Promise.all(ids.map(row)),desired=original.map(x=>[...x,'Ship']);
 const add=await body();for(let n=0;n<ids.length;n++)add.items[n].changes={labels:desired[n]};
 const saved=await rpc(add);check('label batch saves every member',saved.code,null);
 const after=await Promise.all(ids.map(row));check('labels preserve per-task order case and opaque values',after,before.map((r,n)=>({...r,labels:desired[n]})));
 check('label receipt contains no task or label content',JSON.stringify(saved.value).includes('Ship'),false);
 const undo=await body();for(let n=0;n<ids.length;n++)undo.items[n].changes={labels:original[n]};
 await pg.raw(`update public.tasks set labels=array['Later']::text[] where id=${lit(ids[0])}`);
 const later=await Promise.all(ids.map(row));check('label retry only confirms original request',(await rpc(add)).value.replayed,true);check('retry keeps later labels',await Promise.all(ids.map(row)),later);
 check('stale linked label inverse refuses whole selection',(await rpc(undo)).code,'PT409');check('stale inverse leaves every member untouched',await Promise.all(ids.map(row)),later);
 const changed=structuredClone(add);changed.items[0].changes.labels=['Other'];check('label request cannot change intent',(await rpc(changed)).code,'PT409');
 await pg.raw(`update public.tasks set labels=array[${desired[0].map(lit).join(',')}]::text[] where id=${lit(ids[0])}`);
 check('frozen label inverse restores all originals',(await rpc(undo)).code,null);check('label inverse restores sparse distinct sets',await Promise.all(ids.map(row)),before);
 const bad=await body({labels:['Valid']});bad.items[1].changes={labels:[{name:'Not a portable value'}]};
 const counts=await pg.scalar('select jsonb_build_array((select count(*)from taskfold_private.team_task_batches),(select count(*)from taskfold_private.team_task_edits))');
 check('invalid last label value rejects transaction',(await rpc(bad)).code,'22023');check('invalid last label rolls back first update',await Promise.all(ids.map(row)),before);
 check('invalid label rolls back every receipt',await pg.scalar('select jsonb_build_array((select count(*)from taskfold_private.team_task_batches),(select count(*)from taskfold_private.team_task_edits))'),counts);
 for(const [name,labels]of [['null',null],['empty name',['']],['oversized name',['x'.repeat(1025)]],['too many',Array(257).fill('Label')],['not array','Label']]) {
  check(name+' labels refused',(await rpc(await body({labels}))).code,'22023');check(name+' labels preserve all tasks',await Promise.all(ids.map(row)),before);
 }
 const denied=await body({labels:['Ship']});await pg.raw(`insert into taskfold_private.team_project_grants values(${lit(projects[1])},${lit(team)},${lit(users.editor.id)},'viewer')on conflict(project_id,user_id)do update set role='viewer';`);
 check('label changes need access to every project',(await rpc(denied)).code,'42501');check('label role loss preserves the cohort',await Promise.all(ids.map(row)),before);
 await pg.raw(`delete from taskfold_private.team_project_grants where user_id=${lit(users.editor.id)}`);
 const remove=await body();for(let n=0;n<ids.length;n++)remove.items[n].changes={labels:original[n].filter(x=>x!=='Design')};
 check('exact label removal saves whole cohort',(await rpc(remove)).code,null);check('removal preserves differently cased label',(await row(ids[1])).labels,original[1]);
 const clear=await body({labels:[]});check('explicit clear saves whole cohort',(await rpc(clear)).code,null);check('clear affects only labels',await Promise.all(ids.map(row)),before.map(r=>({...r,labels:[]})));
}
