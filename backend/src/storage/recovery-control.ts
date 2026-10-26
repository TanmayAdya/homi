import type { Pool, PoolClient } from 'pg';
import { assertMigrationsCurrent } from './migrate.ts';

export class RecoveryError extends Error {
  constructor() { super('Recovery safety checks failed. Keep the recovered database quarantined.'); this.name='RecoveryError'; }
}
export function requireRecovery(value:unknown):asserts value {if(!value)throw new RecoveryError();}
export async function repositoryIsOpen(pool:Pick<Pool,'query'>):Promise<boolean>{
  try{return (await pool.query('SELECT safeathome_recovery.is_open() AS open')).rows[0]?.open===true;}
  catch{return false;}
}
export async function lockRecoveryControl(client:PoolClient){
  await assertMigrationsCurrent(client);
  await client.query('SELECT singleton FROM safeathome_private.repository_quota WHERE singleton FOR UPDATE');
  const row=(await client.query('SELECT * FROM safeathome_recovery.control WHERE singleton FOR UPDATE')).rows[0];
  requireRecovery(row && ['open','frozen','quarantine','retired'].includes(row.state));return row;
}
export async function recoveryTransaction<T>(pool:Pool,action:(client:PoolClient)=>Promise<T>):Promise<T>{
 const client=await pool.connect();let broken=false;
 try{await client.query('BEGIN');await client.query("SET LOCAL lock_timeout='3s'; SET LOCAL statement_timeout='10s'; SET LOCAL idle_in_transaction_session_timeout='30s'");
  const value=await action(client);await client.query('COMMIT');return value;
 }catch{try{await client.query('ROLLBACK');}catch{broken=true;}throw new RecoveryError();}
 finally{client.release(broken);}
}
export async function freezeRepository(pool:Pool){
 return recoveryTransaction(pool,async client=>{const row=await lockRecoveryControl(client);
  requireRecovery(['open','frozen'].includes(row.state));
  await client.query("UPDATE safeathome_recovery.control SET state='frozen',staged=NULL,checkpoint_hash=NULL WHERE singleton");
  await client.query('REVOKE USAGE ON SCHEMA safeathome_private FROM safeathome_app');
  return {state:'frozen' as const,databaseId:row.database_id,generation:row.generation};
 });
}
export async function thawRepository(pool:Pool){
 return recoveryTransaction(pool,async client=>{const row=await lockRecoveryControl(client);requireRecovery(row.state==='frozen');
  await client.query("UPDATE safeathome_recovery.control SET state='open',generation=gen_random_uuid(),staged=NULL,checkpoint_hash=NULL WHERE singleton");
  await client.query('GRANT USAGE ON SCHEMA safeathome_private TO safeathome_app');return {state:'open' as const};
 });
}
