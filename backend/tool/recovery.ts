import { pathToFileURL } from 'node:url';
import { dirname,isAbsolute,normalize } from 'node:path';
import { createPostgresPool,databaseConfigurationFromEnvironment } from '../src/storage/postgres-pool.ts';
import { freezeRepository,thawRepository,recoveryTransaction,lockRecoveryControl,requireRecovery } from '../src/storage/recovery-control.ts';
import { captureRecoveryCheckpoint,prepareRecovery,promoteRecovery } from '../src/storage/recovery.ts';
import { readBackupRecipient,readRecipientBackup,openRecipientBackup,sealBackupToRecipient,writeRecipientBackup } from '../src/storage/backup-envelope.ts';
import { assertBackupSource } from './backup.ts';

const HELP=`Usage: node tool/recovery.ts <action> --project https://PROJECT.supabase.co [options]
  status | freeze | thaw
  checkpoint --public-key /private/public/recovery.pub --checkpoint /private/archives/checkpoint.sah-backup
  prepare --private-key /private/keys/recovery.pem --archive /private/archives/older.sah-backup --checkpoint /private/archives/checkpoint.sah-backup
  promote --private-key /private/keys/recovery.pem --checkpoint /private/archives/checkpoint.sah-backup --acknowledge exclude-changed-cases
Source: existing project-bound migration/operator configuration.
Target (prepare/promote only): explicit SAFEATHOME_RECOVERY_DATABASE_URL and optional SAFEATHOME_RECOVERY_DATABASE_CA_PEM.
Target must be separately migrated and empty; never the source. No command empties/replaces a live database.
Checkpoint files are encrypted with the existing public-key backup envelope and private-file protections.
Freeze stops application/worker writes and data access until an explicit thaw or promotion.
Promotion retires the source before opening the target. Drain API servers and all workers first.
No restore is possible without the current frozen authority. Changed/missing cases are excluded and their IDs retired.
This command never switches Railway, restores Auth, creates a service, changes billing or runs automatically.`;
type Action='status'|'freeze'|'thaw'|'checkpoint'|'prepare'|'promote';
export type RecoveryArguments={action:'help'}|{action:Action;project:string;publicKey?:string;privateKey?:string;checkpoint?:string;archive?:string};
function path(value:string|undefined,suffix:string){return typeof value==='string'&&isAbsolute(value)&&normalize(value)===value&&value.length<=4096&&!/[\u0000-\u001f\u007f]/.test(value)&&value.endsWith(suffix);}
export function parseRecoveryArguments(args:readonly string[]):RecoveryArguments{
 if(!args.length||args.length===1&&args[0]==='--help')return {action:'help'};
 const [action,...rest]=args;requireRecovery(['status','freeze','thaw','checkpoint','prepare','promote'].includes(action)&&rest.length%2===0);
 const flags=new Map<string,string>();for(let i=0;i<rest.length;i+=2){requireRecovery(!flags.has(rest[i])&&typeof rest[i+1]==='string');flags.set(rest[i],rest[i+1]);}
 const required=['--project',...(action==='checkpoint'?['--public-key','--checkpoint']:action==='prepare'?['--private-key','--archive','--checkpoint']:action==='promote'?['--private-key','--checkpoint','--acknowledge']:[])];
 requireRecovery(flags.size===required.length&&required.every(f=>flags.has(f))&&/^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(flags.get('--project')??''));
 for(const [flag,suffix] of [['--public-key','.pub'],['--private-key','.pem'],['--checkpoint','.sah-backup'],['--archive','.sah-backup']])if(flags.has(flag))requireRecovery(path(flags.get(flag),suffix));
 if(action==='promote')requireRecovery(flags.get('--acknowledge')==='exclude-changed-cases');
 const key=flags.get('--public-key')??flags.get('--private-key');
 if(key)requireRecovery(dirname(key)!==dirname(flags.get('--checkpoint')!));
 if(flags.has('--archive'))requireRecovery(flags.get('--archive')!==flags.get('--checkpoint')&&dirname(key!)!==dirname(flags.get('--archive')!));
 return {action:action as Action,project:flags.get('--project')!,publicKey:flags.get('--public-key'),privateKey:flags.get('--private-key'),checkpoint:flags.get('--checkpoint'),archive:flags.get('--archive')};
}
export async function runRecovery(args:RecoveryArguments,env:NodeJS.ProcessEnv=process.env){
 if(args.action==='help'){console.log(HELP);return;}
 const captured={...env},config=await databaseConfigurationFromEnvironment(captured,'migration');
 assertBackupSource(config.connectionString,captured.SAFEATHOME_SUPABASE_URL,args.project);
 const source=createPostgresPool(config);let target:ReturnType<typeof createPostgresPool>|undefined,key:Buffer|undefined,cp:Buffer|undefined,backup:Buffer|undefined;
 try{
  if(args.action==='status')return await recoveryTransaction(source,async client=>{const row=await lockRecoveryControl(client);return {mode:'status',state:row.state,prepared:row.staged!==null};});
  if(args.action==='freeze') {await freezeRepository(source);return {mode:'freeze',frozen:true};}
  if(args.action==='thaw')return await thawRepository(source);
  if(args.action==='checkpoint'){
   key=await readBackupRecipient(args.publicKey!);cp=await captureRecoveryCheckpoint(source,args.project);
   await writeRecipientBackup(args.checkpoint!,sealBackupToRecipient(cp,key));return {mode:'checkpoint',encrypted:true,created:true};
  }
  requireRecovery(Boolean(captured.SAFEATHOME_RECOVERY_DATABASE_URL));
  target=createPostgresPool({connectionString:captured.SAFEATHOME_RECOVERY_DATABASE_URL!,caCertificate:captured.SAFEATHOME_RECOVERY_DATABASE_CA_PEM});
  key=await readBackupRecipient(args.privateKey!,true);cp=openRecipientBackup(await readRecipientBackup(args.checkpoint!),key);
  if(args.action==='promote')return await promoteRecovery(source,target,cp,args.project);
  backup=openRecipientBackup(await readRecipientBackup(args.archive!),key);
  return await prepareRecovery(source,target,backup,cp,args.project);
 }finally{backup?.fill(0);cp?.fill(0);key?.fill(0);await target?.end();await source.end();}
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
 Promise.resolve().then(()=>runRecovery(parseRecoveryArguments(process.argv.slice(2)))).then(report=>{if(report)console.log(JSON.stringify(report));})
 .catch(()=>{console.error('Recovery stopped. Check current frozen authority, project, isolated target, private encrypted files and recovery state. Recovered data stays quarantined; no private details logged.');process.exitCode=1;});
}
