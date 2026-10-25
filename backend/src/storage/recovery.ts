import { createHash } from 'node:crypto';
import type { Pool } from 'pg';
import { canonicalJson } from '../evidence/validation.ts';
import { captureDatabaseBackup, parseArchive, restoreDatabaseBackup, MAX_DATABASE_BACKUP_BYTES } from './database-backup.ts';
import { lockRecoveryControl, recoveryTransaction, requireRecovery } from './recovery-control.ts';

type Archive=Awaited<ReturnType<typeof parseArchive>>;
type Head={caseHash:string;ownerHash:string;revision:string;catalogRevision:string;fingerprint:string};
const hash=(value:string|Buffer)=>createHash('sha256').update(value).digest('hex');
const HASH=/^[a-f0-9]{64}$/, UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const FORMAT='safeathome-frozen-privacy-checkpoint-v1';
function heads(archive:Archive):Head[]{
 return archive.tables.cases.map(row=>({caseHash:hash(String(row.case_id)),ownerHash:hash(String(row.owner_id)),
  revision:String(row.revision),catalogRevision:String(row.catalog_revision),
  fingerprint:hash(canonicalJson(Object.fromEntries(Object.entries(archive.tables).map(([table,rows])=>[table,
   rows.filter(item=>item.case_id===row.case_id).map(item=>canonicalJson(item)).sort()])))),
 })).sort((a,b)=>a.caseHash.localeCompare(b.caseHash));
}
function encoded(value:unknown){return Buffer.from(JSON.stringify(value));}
function emptyContent(archive:Archive):Archive{
 const copy=structuredClone(archive);
 for(const name of Object.keys(copy.tables) as (keyof Archive['tables'])[]){
  if(!['repository_quota','deleted_cases','closed_accounts','auth_deletion_jobs'].includes(name))copy.tables[name]=[];
 }
 copy.tables.repository_quota=[{singleton:true,case_count:'0',asset_count:'0',artifact_count:'0',stored_bytes:'0'}];return copy;
}
interface Checkpoint {format:typeof FORMAT;sourceId:string;generation:string;heads:Head[];privacy:Archive}
async function parseCheckpoint(bytes:Buffer,origin:string):Promise<Checkpoint>{
 requireRecovery(Buffer.isBuffer(bytes)&&bytes.length>0&&bytes.length<=MAX_DATABASE_BACKUP_BYTES);
 const raw=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
 requireRecovery(raw&&Object.keys(raw).sort().join(',')==='format,generation,heads,privacy,sourceId'&&raw.format===FORMAT
  &&UUID.test(raw.sourceId)&&UUID.test(raw.generation)&&Array.isArray(raw.heads)&&raw.heads.length<=64);
 const privacy=await parseArchive(encoded(raw.privacy),origin);
 requireRecovery(privacy.tables.cases.length===0 && canonicalJson(emptyContent(privacy))===canonicalJson(privacy));
 const seen=new Set<string>();for(const head of raw.heads){
  requireRecovery(head&&Object.keys(head).sort().join(',')==='caseHash,catalogRevision,fingerprint,ownerHash,revision'
   &&[head.caseHash,head.ownerHash,head.fingerprint].every(v=>typeof v==='string'&&HASH.test(v))
   &&typeof head.revision==='string'&&/^[1-9][0-9]*$/.test(head.revision)&&Number.isSafeInteger(Number(head.revision))
   &&typeof head.catalogRevision==='string'&&/^(0|[1-9][0-9]*)$/.test(head.catalogRevision)&&Number.isSafeInteger(Number(head.catalogRevision))&&!seen.has(head.caseHash)
   &&!privacy.tables.closed_accounts.some(r=>r.owner_hash===head.ownerHash)
   &&!privacy.tables.deleted_cases.some(r=>r.case_hash===head.caseHash));seen.add(head.caseHash);
 }
 return {...raw,privacy};
}
export async function captureRecoveryCheckpoint(source:Pool,origin:string):Promise<Buffer>{
 const identity=await recoveryTransaction(source,async client=>{
  const row=await lockRecoveryControl(client);requireRecovery(row.state==='frozen');return row;
 });
 const bytes=await captureDatabaseBackup(source,origin);
 try{
  const archive=await parseArchive(bytes,origin);
  const checkpoint=encoded({format:FORMAT,sourceId:identity.database_id,generation:identity.generation,
   heads:heads(archive),privacy:emptyContent(archive)} satisfies Checkpoint);
  await parseCheckpoint(checkpoint,origin);
  await recoveryTransaction(source,async client=>{const row=await lockRecoveryControl(client);
   requireRecovery(row.state==='frozen'&&row.database_id===identity.database_id&&row.generation===identity.generation);
   await client.query('UPDATE safeathome_recovery.control SET checkpoint_hash=$1 WHERE singleton',[hash(checkpoint)]);
  });return checkpoint;
 }finally{bytes.fill(0);}
}
async function sourceProof(source:Pool,cp:Checkpoint,sha:string,targetId?:string){
 return recoveryTransaction(source,async client=>{const row=await lockRecoveryControl(client);
  requireRecovery(row.database_id===cp.sourceId&&row.generation===cp.generation&&row.checkpoint_hash===sha
   &&(row.state==='frozen'||targetId!==undefined&&row.state==='retired'&&row.promoted_target===targetId));return row;
 });
}
export async function prepareRecovery(source:Pool,target:Pool,backup:Buffer,checkpoint:Buffer,origin:string){
 const cp=await parseCheckpoint(checkpoint,origin),sha=hash(checkpoint);
 await sourceProof(source,cp,sha);
 const archive=await parseArchive(backup,origin);
 requireRecovery(Date.parse(archive.capturedAt)<=Date.parse(cp.privacy.capturedAt));
 const targetIdentity=await recoveryTransaction(target,async client=>{const row=await lockRecoveryControl(client);
  requireRecovery(row.database_id!==cp.sourceId&&['open','quarantine'].includes(row.state));return row.database_id as string;
 });
 const current=new Map(cp.heads.map(h=>[h.caseHash,h])),old=heads(archive),keep=new Set<string>();
 for(const h of old)if(canonicalJson(h)===canonicalJson(current.get(h.caseHash)??null))keep.add(h.caseHash);
 requireRecovery(archive.tables.deleted_cases.every(r=>cp.privacy.tables.deleted_cases.some(c=>c.case_hash===r.case_hash&&c.owner_hash===r.owner_hash))
  &&archive.tables.closed_accounts.every(r=>cp.privacy.tables.closed_accounts.some(c=>c.owner_hash===r.owner_hash)));
 const removedIds=archive.tables.cases.filter(r=>!keep.has(hash(String(r.case_id)))).map(r=>r.case_id);
 for(const rows of Object.values(archive.tables))for(let i=rows.length-1;i>=0;i--)
  if(Object.hasOwn(rows[i],'case_id')&&removedIds.includes(rows[i].case_id))rows.splice(i,1);
 archive.tables.deleted_cases=structuredClone(cp.privacy.tables.deleted_cases);
 archive.tables.closed_accounts=structuredClone(cp.privacy.tables.closed_accounts);
 archive.tables.auth_deletion_jobs=structuredClone(cp.privacy.tables.auth_deletion_jobs);
 archive.tables.account_deletion_previews=[];
 const retired=new Map(archive.tables.deleted_cases.map(row=>[row.case_hash,row]));
 for(const h of [...cp.heads,...old])if(!keep.has(h.caseHash)&&!retired.has(h.caseHash))retired.set(h.caseHash,
  {case_hash:h.caseHash,owner_hash:h.ownerHash,revision:h.revision,catalog_revision:h.catalogRevision});
 archive.tables.deleted_cases=[...retired.values()];
 archive.tables.repository_quota=[{singleton:true,case_count:String(archive.tables.cases.length),
  asset_count:String(archive.tables.evidence.length),artifact_count:String(archive.tables.exports.filter(r=>r.bytes!==null).length),
  stored_bytes:String([...archive.tables.evidence,...archive.tables.exports].reduce((n,r)=>n+(r.bytes===null?0:Buffer.byteLength(String(r.bytes),'base64')),0)
   +archive.tables.case_scan_models.reduce((n,r)=>n+Buffer.byteLength(String(r.record),'base64'),0))}];
 const reconciled=encoded(archive);
 try{
  await parseArchive(reconciled,origin);const report=await restoreDatabaseBackup(target,reconciled,origin);
  await sourceProof(source,cp,sha);
  await recoveryTransaction(target,async client=>{const row=await lockRecoveryControl(client);
   requireRecovery(row.database_id===targetIdentity&&row.state==='quarantine');
   await client.query('UPDATE safeathome_recovery.control SET staged=$1::jsonb WHERE singleton',[JSON.stringify({
    checkpointSha256:sha,sourceId:cp.sourceId,sourceGeneration:cp.generation,targetGeneration:row.generation,projectOrigin:origin})]);
  });
  return {mode:'prepared' as const,quarantined:true,retainedCases:keep.size,excludedOldCases:old.length-keep.size,
   unavailableCurrentCases:cp.heads.length-keep.size,retiredCaseIds:retired.size,storedBytes:report.storedBytes};
 }finally{reconciled.fill(0);}
}
export async function promoteRecovery(source:Pool,target:Pool,checkpoint:Buffer,origin:string){
 const cp=await parseCheckpoint(checkpoint,origin),sha=hash(checkpoint);
 const staged=await recoveryTransaction(target,async client=>{const row=await lockRecoveryControl(client);
  requireRecovery(row.state==='quarantine'&&row.database_id!==cp.sourceId&&row.staged?.checkpointSha256===sha
   &&row.staged.sourceId===cp.sourceId&&row.staged.sourceGeneration===cp.generation
   &&row.staged.targetGeneration===row.generation&&row.staged.projectOrigin===origin);return row;
 });
 await sourceProof(source,cp,sha,staged.database_id);
 await recoveryTransaction(source,async client=>{const row=await lockRecoveryControl(client);
  requireRecovery(row.database_id===cp.sourceId&&row.generation===cp.generation&&row.checkpoint_hash===sha
   &&(row.state==='frozen'||row.state==='retired'&&row.promoted_target===staged.database_id));
  await client.query("UPDATE safeathome_recovery.control SET state='retired',promoted_target=$1 WHERE singleton",[staged.database_id]);
  await client.query('REVOKE USAGE ON SCHEMA safeathome_private FROM safeathome_app');
 });
 await recoveryTransaction(target,async client=>{const row=await lockRecoveryControl(client);
  requireRecovery(row.state==='quarantine'&&row.generation===staged.generation&&canonicalJson(row.staged)===canonicalJson(staged.staged));
  await client.query("UPDATE safeathome_recovery.control SET state='open',staged=NULL WHERE singleton");
  await client.query('GRANT USAGE ON SCHEMA safeathome_private TO safeathome_app');
 });return {mode:'promoted' as const,sourceRetired:true,targetOpen:true};
}
