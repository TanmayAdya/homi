import { pathToFileURL } from 'node:url';
import { createPostgresPool, databaseConfigurationFromEnvironment } from '../src/storage/postgres-pool.ts';
import { assertCompleteOperatorVisibility } from '../src/storage/capacity-report.ts';
import { assertMigrationsCurrent } from '../src/storage/migrate.ts';
import { assertBackupSource } from './backup.ts';
import { completeAccountDeletionsFromEnvironment } from './complete-account-deletions.ts';
import { readOperationsHealth } from './operations.ts';
import { repositoryIsOpen, RecoveryError } from '../src/storage/recovery-control.ts';

export async function runPrivateOperations(env:NodeJS.ProcessEnv){
 const captured={...env},config=await databaseConfigurationFromEnvironment(captured,'migration');
 assertBackupSource(config.connectionString,captured.SAFEATHOME_SUPABASE_URL,captured.SAFEATHOME_SUPABASE_URL??'');
 const pool=createPostgresPool(config);
 try{
  await assertMigrationsCurrent(pool);const visibility=await pool.connect();
  try{await assertCompleteOperatorVisibility(visibility);}finally{visibility.release();}
  if(!await repositoryIsOpen(pool))throw new RecoveryError();
  const deletion=await completeAccountDeletionsFromEnvironment(captured,{apply:true,limit:1});
  const operations=await readOperationsHealth(pool);
  return {schemaVersion:'1',mode:'bounded_hourly',deletion,operations,exitCode:deletion.databaseFailure||deletion.failed>0?1:operations.exitCode};
 }finally{await pool.end();}
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
 if(process.argv.length!==2){console.error('This bounded operations command accepts no arguments.');process.exitCode=1;}
 else runPrivateOperations(process.env).then(report=>{console.log(JSON.stringify(report));process.exitCode=report.exitCode;}).catch(()=>{
  console.error('Private operations failed. Verify project-bound operator access, current migrations and complete visibility. No private details logged.');process.exitCode=1;
 });
}
