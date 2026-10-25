import { DisposablePostgres } from '../../tool/disposable-postgres.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { createMatchingServer } from '../../src/api/http-server.ts';
import { seedSensitive, OWNER, HELPER, VIEWER, OTHER } from './sensitive-fixture.ts';
const cluster = await DisposablePostgres.start();
try {
  const admin = cluster.pool(); await applyMigrations(admin);
  await admin.query('CREATE ROLE sensitive_http_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app');
  const pool = cluster.pool('sensitive_http_runtime'), fixture = await seedSensitive(pool);
  const tokens: Record<string,string> = { 'fictional-owner-token': OWNER, 'fictional-helper-token': HELPER, 'fictional-viewer-token': VIEWER, 'fictional-other-token': OTHER };
  const emailInvitations=process.argv.includes('--email-invitations');
  const emails:Record<string,string>={'fictional-owner-token':'owner@fictional.example','fictional-helper-token':'helper@fictional.example','fictional-other-token':'other@fictional.example'};
  const authenticate = async (token:string) => tokens[token] ? {userId:tokens[token],...(emailInvitations && emails[token]?{verifiedEmail:emails[token]}:{})} : null;
  const deps = {authenticate,cases:fixture.cases,loadRegistry:async()=>[],now:()=>new Date()};
  const server = createMatchingServer(deps,undefined,undefined,undefined,undefined,undefined,{sharingDependencies:{authenticate,reauthenticate:authenticate,sharing:fixture.shares,sensitiveEnabled:true,simpleInvitationsEnabled:emailInvitations}});
  await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const address=server.address();if(!address||typeof address==='string')throw Error();
  process.stdout.write(JSON.stringify({origin:'http://127.0.0.1:'+address.port,caseId:fixture.caseId,membershipId:fixture.membershipId,owner:OWNER,helper:HELPER})+'\n');
  await new Promise<void>(resolve=>{const stop=()=>{server.closeAllConnections();server.close(()=>resolve());};process.once('SIGTERM',stop);process.once('SIGINT',stop);});
}finally{await cluster.close();}
