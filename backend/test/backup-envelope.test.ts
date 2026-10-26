import assert from 'node:assert/strict';
import { before, test } from 'node:test';
import { generateKeyPairSync } from 'node:crypto';
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { backupRecipientFingerprint, createBackupRecipient, openRecipientBackup, readBackupRecipient, readRecipientBackup,
 sealBackupToRecipient, writeRecipientBackup } from '../src/storage/backup-envelope.ts';
import { parsePublicBackupArguments } from '../tool/backup-public.ts';

let publicPem:string,privatePem:string,wrongPrivate:string;
before(()=>{
 const pair=()=>generateKeyPairSync('rsa',{modulusLength:3072,publicKeyEncoding:{format:'pem',type:'spki'},privateKeyEncoding:{format:'pem',type:'pkcs8'}});
 ({publicKey:publicPem,privateKey:privatePem}=pair());wrongPrivate=pair().privateKey;
});
test('public key encrypts but cannot decrypt; every envelope region is authenticated with a fresh content key',()=>{
 const original=Buffer.from(JSON.stringify({fictional:'Only fictional test data',rows:[1,2,3]}));
 const envelope=sealBackupToRecipient(original,publicPem),second=sealBackupToRecipient(original,publicPem);
 assert.notDeepEqual(envelope,second);assert.deepEqual(openRecipientBackup(envelope,privatePem),original);
 assert.match(backupRecipientFingerprint(publicPem),/^[a-f0-9]{64}$/);assert.ok(!envelope.includes(original));
 assert.throws(()=>openRecipientBackup(envelope,publicPem),/^Error: Public-key backup operation failed/);
 assert.throws(()=>openRecipientBackup(envelope,wrongPrivate));
 for(const index of [0,9,10,41,42,425,426,437,438,envelope.length-1]){
  const changed=Buffer.from(envelope);changed[index]^=1;assert.throws(()=>openRecipientBackup(changed,privatePem));
 }
 for(const changed of [envelope.subarray(0,-1),Buffer.concat([envelope,Buffer.from([0])])])assert.throws(()=>openRecipientBackup(changed,privatePem));
 assert.deepEqual(openRecipientBackup(sealBackupToRecipient(Buffer.alloc(0),publicPem),privatePem),Buffer.alloc(0));
});
test('wrong algorithm, weak RSA, private material in public slot and trailing key material are rejected',()=>{
 const weak=generateKeyPairSync('rsa',{modulusLength:2048}).publicKey.export({format:'pem',type:'spki'});
 const ec=generateKeyPairSync('ec',{namedCurve:'prime256v1'}).publicKey.export({format:'pem',type:'spki'});
 for(const value of [weak,ec,privatePem,`${publicPem}${privatePem}`,'not a key'])assert.throws(()=>sealBackupToRecipient(Buffer.from('fictional'),value));
});
test('key and envelope files preserve private modes, no-overwrite and symlink refusal',async t=>{
 const root=await mkdtemp(join(await realpath(tmpdir()),'sah-envelope-'));await chmod(root,0o700);t.after(()=>rm(root,{recursive:true,force:true}));
 const dirs=['private','public','archives'];for(const dir of dirs)await mkdir(join(root,dir),{mode:0o700});
 const secret=join(root,'private','recovery.pem'),recipient=join(root,'public','recovery.pub'),archive=join(root,'archives','copy.sah-backup');
 const fingerprint=await createBackupRecipient(secret,recipient);assert.equal((await stat(secret)).mode&0o777,0o600);
 const pub=await readBackupRecipient(recipient),pem=await readBackupRecipient(secret,true);assert.equal(fingerprint,backupRecipientFingerprint(pub));
 const body=Buffer.from('Fictional retained case');await writeRecipientBackup(archive,sealBackupToRecipient(body,pub));
 assert.deepEqual(openRecipientBackup(await readRecipientBackup(archive),pem),body);
 const before=await readFile(secret);await assert.rejects(createBackupRecipient(secret,recipient));assert.deepEqual(await readFile(secret),before);
 await assert.rejects(writeRecipientBackup(archive,sealBackupToRecipient(body,pub)));
 const link=join(root,'archives','linked.sah-backup');await symlink(archive,link);await assert.rejects(readRecipientBackup(link));
 await chmod(recipient,0o644);await assert.rejects(readBackupRecipient(recipient));
 const wrong=join(root,'archives','wrong.sah-backup');await writeFile(wrong,'not an envelope',{mode:0o600});await assert.rejects(readRecipientBackup(wrong));
 pem.fill(0);
});
test('public backup CLI has no live restore and separates private/public roles and paths',()=>{
 const project='https://abcdefghijklmnopqrst.supabase.co';
 assert.deepEqual(parsePublicBackupArguments([]),{action:'help'});assert.deepEqual(parsePublicBackupArguments(['scheduled']),{action:'scheduled'});
 assert.equal(parsePublicBackupArguments(['keypair','--private-key','/private/keys/recovery.pem','--public-key','/private/public/recovery.pub']).action,'keypair');
 assert.equal(parsePublicBackupArguments(['create','--public-key','/private/public/recovery.pub','--archive','/private/archive/copy.sah-backup','--project',project]).action,'create');
 for(const args of [['restore'],['scheduled','--private-key','/private/keys/recovery.pem'],['keypair','--private-key','/private/keys/recovery.pem','--public-key','/private/keys/recovery.pub'],
  ['create','--private-key','/private/keys/recovery.pem','--archive','/private/archive/copy.sah-backup','--project',project]])assert.throws(()=>parsePublicBackupArguments(args));
});
