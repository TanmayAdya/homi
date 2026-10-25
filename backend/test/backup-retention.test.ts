import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { planBackupRetention, retainPrivateBackupArtifacts, inspectPrivateBackupArtifacts, summarizeBackupRecoveryWindow, checkBackupPreflight, type BackupArtifact } from '../tool/backup-retention.ts';
const now=Date.parse('2026-10-22T05:00:00Z');
const item=(id:number,successful=true):BackupArtifact=>({id,name:`safeathome-encrypted-backup-${id}-1`,runId:id,createdAt:new Date(now-(10-id)*86400000).toISOString(),expiresAt:new Date(now+(80+id)*86400000).toISOString(),sizeBytes:1024,expired:false,completed:true,successful});
test('latest-three policy preserves newest successful copy; failed/in-progress/future/malformed inputs fail safely',()=>{
 assert.deepEqual(planBackupRetention([item(1),item(2),item(3),item(4)],4,now),{keep:[4,3,2],remove:[1]});
 assert.deepEqual(planBackupRetention([item(1),item(2,false),{...item(3,false),completed:false},item(4)],4,now),{keep:[4,1],remove:[2]});
 for(const records of [[item(1)], [item(4,false)], [item(4),item(4)], [{...item(4),name:'another-project-backup'}], [{...item(4),createdAt:'2099-01-01T00:00:00Z'}], [{...item(4),sizeBytes:100*1024*1024}]])assert.throws(()=>planBackupRetention(records,4,now));
 assert.throws(()=>planBackupRetention([item(1),item(2),item(3),item(4)],1,now));
});
function transport(options:{privateRepo?:boolean;foreignWorkflow?:boolean;malformed?:boolean}={}){
 const calls:{url:string;method:string}[]=[];
 const fetcher=async(input:URL|RequestInfo,init?:RequestInit)=>{
  const url=String(input),method=init?.method??'GET';calls.push({url,method});let body:unknown;
  assert.ok(url.startsWith('https://api.github.com/repos/fictional/team'));assert.equal(init?.redirect,'error');
  if(method==='DELETE')return new Response(null,{status:204});
  if(url.endsWith('/fictional/team'))body={id:77,private:options.privateRepo!==false,default_branch:'main'};
  else if(url.endsWith('/actions/workflows/private-operations.yml'))body={id:88,path:'.github/workflows/private-operations.yml'};
  else if(url.includes('/actions/artifacts?'))body={total_count:4,artifacts:[1,2,3,4].map(id=>({id,name:item(id).name,size_in_bytes:1024,created_at:item(id).createdAt,expires_at:item(id).expiresAt,expired:false,
   workflow_run:{id,repository_id:77,head_repository_id:77}}))};
  else{const id=Number(url.split('/').at(-1));body={id,workflow_id:options.foreignWorkflow?99:88,head_repository:{id:77},repository:{id:77},head_branch:'main',head_sha:'fictional-sha',event:'schedule',status:id===4?'in_progress':'completed',conclusion:id===4?null:'success'};}
  if(options.malformed&&url.includes('/actions/runs/2'))body={};
  return new Response(JSON.stringify(body),{status:200,headers:{'content-type':'application/json'}});
 };
 return {calls,fetcher:fetcher as typeof fetch};
}
const env={GITHUB_REPOSITORY:'fictional/team',GITHUB_TOKEN:'fictional-token',GITHUB_RUN_ID:'4',SAFEATHOME_BACKUP_ARTIFACT_ID:'4',GITHUB_REF_NAME:'main',GITHUB_SHA:'fictional-sha'};
test('retention verifies private repository/workflow provenance for every artifact before deleting only oldest owned copy',async()=>{
 const mock=transport();assert.deepEqual(await retainPrivateBackupArtifacts(env,mock.fetcher,now),{mode:'private_backup_retention',keptSuccessful:3,removed:1,maximumSuccessfulCopies:3});
 assert.deepEqual(mock.calls.filter(c=>c.method==='DELETE').map(c=>c.url),['https://api.github.com/repos/fictional/team/actions/artifacts/1']);
 for(const settings of [{privateRepo:false},{foreignWorkflow:true},{malformed:true}]){
  const mock=transport(settings);await assert.rejects(retainPrivateBackupArtifacts(env,mock.fetcher,now));assert.equal(mock.calls.some(c=>c.method==='DELETE'),false);
 }
});
test('scheduled workflow is opt-in, private/default-branch only, bounded and never receives the private recovery key',async()=>{
 const workflow=await readFile(new URL('../../.github/workflows/private-operations.yml',import.meta.url),'utf8');
 assert.match(workflow,/SAFEATHOME_ENABLE_PRIVATE_OPERATIONS == 'true'/);assert.match(workflow,/SAFEATHOME_ACTIONS_BUDGET_ACK == 'included-only'/);
 assert.equal((workflow.match(/github.event.repository.private == true/g)??[]).length,2);assert.equal((workflow.match(/github.event.repository.default_branch/g)??[]).length,2);
 assert.match(workflow,/timeout-minutes: 2/);assert.match(workflow,/timeout-minutes: 5/);assert.match(workflow,/retention-days: 90/);
 assert.doesNotMatch(workflow,/pull_request|SAFEATHOME_BACKUP_PRIVATE|recovery\.pem|--schedule|--unschedule/);
 const backup=workflow.slice(workflow.indexOf('\n  backup:'));assert.doesNotMatch(backup,/SUPABASE_SECRET_KEY/);
 assert.ok(backup.indexOf('backup-public.ts scheduled')<backup.indexOf('actions/upload-artifact@'));
 assert.ok(backup.indexOf('backup-retention.ts preflight')<backup.indexOf('backup-public.ts scheduled'));
 assert.ok(backup.indexOf('actions/upload-artifact@')<backup.lastIndexOf('backup-retention.ts'));
 assert.match(workflow,/backup-retention\.ts health/);assert.match(workflow,/SAFEATHOME_DATABASE_CA_PEM/);
 assert.ok(backup.includes('if: ${{ always() }}'));assert.ok(backup.includes('rm -f -- "$archive_dir/copy.sah-backup"'));
});

test('actual workflow job conditions isolate backup success from maintenance for every supported trigger', async () => {
 const workflow = await readFile(new URL('../../.github/workflows/private-operations.yml', import.meta.url), 'utf8');
 const defaultTask = /^        default: (\w+)$/m.exec(workflow)?.[1];
 assert.equal(defaultTask, 'backup');
 assert.match(workflow, /options: \[maintenance, backup\]/);
 const conditions = ['maintenance', 'backup'].map(job => {
  const match = new RegExp(`^  ${job}:\\n    if: >-\\n([\\s\\S]*?)^    runs-on:`, 'm').exec(workflow);
  assert.ok(match, `Missing ${job} condition`);
  return match[1].trim();
 });
 const selected = (event: string, task: string | undefined, schedule: string | undefined, overrides: Record<string, unknown> = {}) => {
  const context = {
   vars: { SAFEATHOME_ENABLE_PRIVATE_OPERATIONS: 'true', SAFEATHOME_ENABLE_PRIVATE_SCHEDULES:'true', SAFEATHOME_ACTIONS_BUDGET_ACK: 'included-only' },
   github: { event_name: event, event: { repository: { private: true, default_branch: 'main' }, schedule }, ref: 'refs/heads/main' },
   inputs: { task }, format: (pattern: string, value: string) => pattern.replace('{0}', value), ...overrides,
  };
  return conditions.map(condition => runInNewContext(condition, context, { timeout: 1000 }) === true);
 };
 assert.deepEqual(selected('workflow_dispatch', defaultTask, undefined), [false, true]);
 assert.deepEqual(selected('workflow_dispatch', 'maintenance', undefined), [true, false]);
 assert.deepEqual(selected('workflow_dispatch', 'both', undefined), [false, false]);
 assert.deepEqual(selected('workflow_dispatch', 'unknown', undefined), [false, false]);
 assert.deepEqual(selected('schedule', undefined, '17 * * * *'), [true, false]);
 assert.deepEqual(selected('schedule', undefined, '37 3 * * *'), [false, true]);
 const manualOnly={vars:{SAFEATHOME_ENABLE_PRIVATE_OPERATIONS:'true',SAFEATHOME_ENABLE_PRIVATE_SCHEDULES:'false',SAFEATHOME_ACTIONS_BUDGET_ACK:'included-only'}};
 assert.deepEqual(selected('workflow_dispatch','backup',undefined,manualOnly),[false,true]);
 assert.deepEqual(selected('workflow_dispatch','maintenance',undefined,manualOnly),[true,false]);
 assert.deepEqual(selected('schedule',undefined,'17 * * * *',manualOnly),[false,false]);
 assert.deepEqual(selected('schedule',undefined,'37 3 * * *',manualOnly),[false,false]);
 assert.deepEqual(selected('schedule', 'backup', '17 * * * *'), [true, false]);
 assert.deepEqual(selected('workflow_dispatch', 'backup', '17 * * * *'), [false, true]);
 assert.deepEqual(selected('push', 'backup', '37 3 * * *'), [false, false]);
 assert.deepEqual(selected('workflow_dispatch', 'backup', undefined, {
  vars: { SAFEATHOME_ENABLE_PRIVATE_OPERATIONS: 'false', SAFEATHOME_ACTIONS_BUDGET_ACK: 'included-only' },
 }), [false, false]);
 assert.deepEqual(selected('workflow_dispatch', 'backup', undefined, {
  vars: { SAFEATHOME_ENABLE_PRIVATE_OPERATIONS: 'true', SAFEATHOME_ACTIONS_BUDGET_ACK: '' },
 }), [false, false]);
 for (const [privateRepo, branch] of [[false, 'main'], [true, 'feature']] as const) {
  assert.deepEqual(selected('workflow_dispatch', 'backup', undefined, {
   github: { event_name: 'workflow_dispatch', event: { repository: { private: privateRepo, default_branch: 'main' } }, ref: `refs/heads/${branch}` },
  }), [false, false]);
 }
});

test('recovery window reports stale/no-copy/near-expiry states without pretending latest three remain forever',()=>{
 const fresh={...item(10),expiresAt:new Date(now+90*86400000).toISOString()};
 const report=summarizeBackupRecoveryWindow([fresh],now);
 assert.equal(report.successfulCopies,1);assert.equal(report.latestSuccessfulAgeSeconds,0);assert.equal(report.nextExpirySeconds,90*86400);assert.deepEqual(report.warnings,[]);
 assert.deepEqual(summarizeBackupRecoveryWindow([],now).warnings,['no_successful_backup']);
 assert.deepEqual(summarizeBackupRecoveryWindow([item(4)],now).warnings,['backup_stale']);
 assert.ok(summarizeBackupRecoveryWindow([{...item(4),expiresAt:new Date(now+86400000).toISOString()}],now).warnings.includes('backup_expiry_near'));
 assert.deepEqual(summarizeBackupRecoveryWindow([{...item(4),expiresAt:new Date(now-1000).toISOString()}],now).warnings,['no_successful_backup']);
 assert.throws(()=>summarizeBackupRecoveryWindow([{...item(4),expiresAt:'2099-01-01T00:00:00Z'}],now));
 assert.deepEqual(checkBackupPreflight([],now),{mode:'private_backup_preflight',activeCopies:0,maximumTransientCopies:4});
 assert.equal(checkBackupPreflight([item(1),item(2),item(3)],now).activeCopies,3);
 assert.throws(()=>checkBackupPreflight([item(1),item(2),item(3),item(4)],now));
});

test('remote health and capacity preflight verify provenance but never delete artifacts',async()=>{
 const mock=transport();const report=await inspectPrivateBackupArtifacts(env,'health',mock.fetcher,now);
 assert.equal(report.mode,'private_backup_health');
 if('warnings' in report)assert.deepEqual(report.warnings,['backup_stale','backup_pruning_required']);
 await assert.rejects(inspectPrivateBackupArtifacts(env,'preflight',mock.fetcher,now));
 assert.equal(mock.calls.some(c=>c.method==='DELETE'),false);
 const foreign=transport({foreignWorkflow:true});await assert.rejects(inspectPrivateBackupArtifacts(env,'health',foreign.fetcher,now));
 assert.equal(foreign.calls.some(c=>c.method==='DELETE'),false);
});
