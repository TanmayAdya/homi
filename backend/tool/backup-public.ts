import { dirname, isAbsolute, normalize } from 'node:path';
import { pathToFileURL } from 'node:url';
import { backupRecipientFingerprint, createBackupRecipient, MAX_SCHEDULED_ENVELOPE_BYTES, openRecipientBackup,
  readBackupRecipient, readRecipientBackup, sealBackupToRecipient, writeRecipientBackup } from '../src/storage/backup-envelope.ts';
import { captureDatabaseBackup, restoreDatabaseBackup, validateDatabaseBackup } from '../src/storage/database-backup.ts';
import { createPostgresPool, databaseConfigurationFromEnvironment } from '../src/storage/postgres-pool.ts';
import { applyMigrations } from '../src/storage/migrate.ts';
import { assertBackupSource } from './backup.ts';
import { DisposablePostgres } from './disposable-postgres.ts';

const HELP=`Usage:
  node tool/backup-public.ts keypair --private-key /private/keys/recovery.pem --public-key /private/public/recovery.pub
  node tool/backup-public.ts create --public-key /private/public/recovery.pub --archive /private/archives/copy.sah-backup --project https://PROJECT.supabase.co
  node tool/backup-public.ts drill --private-key /private/keys/recovery.pem --archive /private/archives/copy.sah-backup --project https://PROJECT.supabase.co
  node tool/backup-public.ts scheduled
All directories must already exist as owner-only 0700 directories; files are exclusively created 0600.
Keep private recovery keys outside GitHub Actions, repository secrets, archives and runtime API configuration.
scheduled uses only the public recipient key/fingerprint and operator database configuration; it caps the encrypted copy at 96 MiB.
drill accepts no destination database and only creates/removes a fresh local quarantine cluster.
No command restores/promotes live data, uploads an archive, sends notifications or installs a schedule.`;
type Arguments={action:'help'}|{action:'scheduled'}|{action:'keypair';privateKey:string;publicKey:string}
 |{action:'create'|'drill';key:string;archive:string;project:string};
const path=(value:string,suffix:string)=>isAbsolute(value)&&normalize(value)===value&&value.length<=4096&&!/[\u0000-\u001f\u007f]/.test(value)&&value.endsWith(suffix);
export function parsePublicBackupArguments(args:readonly string[]):Arguments{
 if(!args.length||args.length===1&&args[0]==='--help')return {action:'help'};
 if(args.length===1&&args[0]==='scheduled')return {action:'scheduled'};
 const [action,...rest]=args;if(!['keypair','create','drill'].includes(action)||rest.length%2)throw Error('Invalid public backup arguments.');
 const options=new Map<string,string>();for(let i=0;i<rest.length;i+=2){if(!['--private-key','--public-key','--archive','--project'].includes(rest[i])||options.has(rest[i]))throw Error('Invalid public backup arguments.');options.set(rest[i],rest[i+1]);}
 if(action==='keypair'){
  const privateKey=options.get('--private-key')??'',publicKey=options.get('--public-key')??'';
  if(options.size!==2||!path(privateKey,'.pem')||!path(publicKey,'.pub')||dirname(privateKey)===dirname(publicKey))throw Error('Invalid key paths.');
  return {action,privateKey,publicKey};
 }
 const key=options.get(action==='create'?'--public-key':'--private-key')??'',archive=options.get('--archive')??'',project=options.get('--project')??'';
 if(options.size!==3||!path(key,action==='create'?'.pub':'.pem')||!path(archive,'.sah-backup')||dirname(key)===dirname(archive)||!/^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(project))throw Error('Invalid public backup paths or project.');
 return {action:action as 'create'|'drill',key,archive,project};
}
export async function runPublicBackup(args:Arguments,env:NodeJS.ProcessEnv=process.env,signal?:AbortSignal){
 signal?.throwIfAborted();if(args.action==='help'){console.log(HELP);return;}
 if(args.action==='keypair'){console.log(JSON.stringify({mode:'keypair',created:true,privateKeyPrinted:false,recipientSha256:await createBackupRecipient(args.privateKey,args.publicKey)}));return;}
 let plaintext:Buffer|undefined,key:Buffer|undefined;
 try{
  if(args.action==='drill'){
   key=await readBackupRecipient(args.key,true);plaintext=openRecipientBackup(await readRecipientBackup(args.archive),key);
   await validateDatabaseBackup(plaintext,args.project);signal?.throwIfAborted();
   const cluster=await DisposablePostgres.start(env.SAFEATHOME_RESTORE_PG_BIN??'');let report;
   try{const pool=cluster.pool(undefined,'safeathome-public-backup-drill');await applyMigrations(pool);report=await restoreDatabaseBackup(pool,plaintext,args.project,signal);}
   finally{await cluster.close();}
   console.log(JSON.stringify({mode:'drill',...report,isolatedDatabaseRemoved:true,liveRestore:false}));return;
  }
  const scheduled=args.action==='scheduled',project=args.action==='scheduled'?env.SAFEATHOME_SUPABASE_URL??'':args.project;
  const archive=args.action==='scheduled'?env.SAFEATHOME_BACKUP_ARCHIVE??'':args.archive;
  if(!/^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(project)||!path(archive,'.sah-backup'))throw Error();
  if(args.action==='scheduled'){
   if(!env.SAFEATHOME_BACKUP_PUBLIC_KEY||!/^[a-f0-9]{64}$/.test(env.SAFEATHOME_BACKUP_RECIPIENT_SHA256??''))throw Error();
   key=Buffer.from(env.SAFEATHOME_BACKUP_PUBLIC_KEY);
   if(backupRecipientFingerprint(key)!==env.SAFEATHOME_BACKUP_RECIPIENT_SHA256)throw Error();
  }else key=await readBackupRecipient(args.key);
  const config=await databaseConfigurationFromEnvironment(env,'migration');assertBackupSource(config.connectionString,env.SAFEATHOME_SUPABASE_URL,project);
  const pool=createPostgresPool(config);try{plaintext=await captureDatabaseBackup(pool,project,signal);}finally{await pool.end();}
  const summary=await validateDatabaseBackup(plaintext,project);signal?.throwIfAborted();const envelope=sealBackupToRecipient(plaintext,key);
  if(scheduled&&envelope.length>MAX_SCHEDULED_ENVELOPE_BYTES)throw Error();
  await writeRecipientBackup(archive,envelope);signal?.throwIfAborted();
  console.log(JSON.stringify({mode:scheduled?'scheduled':'create',encrypted:true,publicKeyOnly:true,recipientSha256:backupRecipientFingerprint(key),archiveBytes:envelope.length,...summary}));
 }finally{plaintext?.fill(0);key?.fill(0);}
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
 const controller=new AbortController();let interrupted:number|undefined;
 const interrupt=()=>{interrupted=130;controller.abort();};const terminate=()=>{interrupted=143;controller.abort();};
 process.once('SIGINT',interrupt);process.once('SIGTERM',terminate);
 Promise.resolve().then(()=>runPublicBackup(parsePublicBackupArguments(process.argv.slice(2)),process.env,controller.signal)).catch(()=>{
  console.error('Public-key backup failed. Check recipient, private paths, project/operator binding, size limits and local drill tools. No private details logged.');process.exitCode=1;
 }).finally(()=>{process.removeListener('SIGINT',interrupt);process.removeListener('SIGTERM',terminate);if(interrupted!==undefined)process.exitCode=interrupted;});
}
