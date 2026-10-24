import assert from 'node:assert/strict';
import test from 'node:test';
import { generateKeyPairSync } from 'node:crypto';
import { chmod, mkdir, mkdtemp, realpath, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { captureDatabaseBackup } from '../../src/storage/database-backup.ts';
import { sealBackupToRecipient, writeRecipientBackup } from '../../src/storage/backup-envelope.ts';
import { writePrivateBackupFile } from '../../src/storage/backup-archive.ts';
import { parsePublicBackupArguments, runPublicBackup } from '../../tool/backup-public.ts';
import { PostgresCaseRepository } from '../../src/storage/postgres-case-repository.ts';
import { create } from './fixtures.ts';

test('public-key archive completes an isolated native PostgreSQL drill without reading remote configuration',async t=>{
 const source=await TestPostgres.start();t.after(()=>source.close());const admin=source.pool();await applyMigrations(admin);
 await create(new PostgresCaseRepository(admin));
 const project='https://abcdefghijklmnopqrst.supabase.co',plaintext=await captureDatabaseBackup(admin,project);
 const pair=generateKeyPairSync('rsa',{modulusLength:3072,publicKeyEncoding:{format:'pem',type:'spki'},privateKeyEncoding:{format:'pem',type:'pkcs8'}});
 const root=await mkdtemp(join(await realpath(tmpdir()),'sah-public-drill-'));await chmod(root,0o700);t.after(()=>rm(root,{recursive:true,force:true}));
 for(const child of ['keys','archives'])await mkdir(join(root,child),{mode:0o700});
 const key=join(root,'keys','fictional.pem'),archive=join(root,'archives','fixture.sah-backup');
 await writePrivateBackupFile(key,Buffer.from(pair.privateKey));await writeRecipientBackup(archive,sealBackupToRecipient(plaintext,pair.publicKey));plaintext.fill(0);
 const reports:unknown[]=[];const original=console.log;console.log=(report)=>{reports.push(JSON.parse(report));};
 try{
  await runPublicBackup(parsePublicBackupArguments(['drill','--private-key',key,'--archive',archive,'--project',project]),{
   SAFEATHOME_RESTORE_PG_BIN:process.env.SAFEATHOME_TEST_PG_BIN,
   SAFEATHOME_MIGRATION_DATABASE_URL:'NEVER_CONNECT_TO_A_REMOTE_DATABASE',SAFEATHOME_SUPABASE_SECRET_KEY:'NEVER_USE_AUTH',
  });
 }finally{console.log=original;}
 assert.equal(reports.length,1);const report=reports[0] as Record<string,any>;
 assert.equal(report.mode,'drill');assert.equal(report.quarantined,true);assert.equal(report.liveRestore,false);
 assert.equal(report.isolatedDatabaseRemoved,true);assert.equal(report.sourceRows.cases,1);
 assert.ok(!JSON.stringify(report).includes('fictional-alice'));
 assert.equal((await admin.query('SELECT count(*)::integer AS count FROM safeathome_private.cases')).rows[0].count,1);
});
