import assert from 'node:assert/strict';
import test from 'node:test';
import {runInNewContext} from 'node:vm';
import {createSupabaseAuthenticator} from '../src/auth/supabase-auth.ts';
import {invitationEmail,invitationEmailHash} from '../src/auth/invitation-email.ts';
import {invitationScript} from '../src/sharing/invitation-landing.ts';
import {createMatchingServer} from '../src/api/http-server.ts';
import {MemoryCaseRepository} from '../src/api/memory-case-repository.ts';
test('mailbox matching preserves aliases and never trusts metadata or unconfirmed email',async()=>{
 assert.equal(invitationEmail(' Helper+test@Fictional.Example '),'helper+test@fictional.example');
 assert.notEqual(invitationEmailHash('helper+test@fictional.example'),invitationEmailHash('helper@fictional.example'));
 for(const v of ['x@y','x..y@fictional.example','x@-fictional.example','bad\nmail@example.test'])assert.equal(invitationEmail(v),null);
 const config={projectUrl:'https://fictional.supabase.co',publishableKey:'sb_publishable_fictional'};
 const base={id:'33333333-3333-4333-8333-333333333333',role:'authenticated',email:' Helper@Fictional.Example ',phone_confirmed_at:'2026-10-25T00:00:00Z',user_metadata:{email_verified:true,email:'forged@fictional.example'}};
 let provider:any={...base};let calls=0;
 const transport:typeof fetch=async()=>{calls++;return Response.json(provider);};
 const auth=createSupabaseAuthenticator(config,transport,true,true);
 assert.deepEqual(await auth('token'),{userId:base.id});
 provider={...base,email_confirmed_at:'invalid'};assert.deepEqual(await auth('token'),{userId:base.id});
 provider={...base,email_confirmed_at:'2026-10-25T00:00:00Z'};assert.deepEqual(await auth('token'),{userId:base.id,verifiedEmail:'helper@fictional.example'});
 assert.equal(calls,3,'identity is fetched on every operation');
 assert.deepEqual(await createSupabaseAuthenticator(config,transport,true)('token'),{userId:base.id},'legacy verifier shape stays unchanged');
 provider.is_anonymous=true;assert.equal(await auth('token'),null);
});
test('landing script validates the fragment, never auto-accepts or fetches data, and handles no arbitrary URL',()=>{
 for(const [hash,search,valid] of [['#code='+'a'.repeat(43),'',true],['#code='+'a'.repeat(43),'?email=someone',false],['#code=javascript:alert(1)','',false],['#code='+'a'.repeat(43)+'&next=evil','',false]]){
  const link:any={hidden:true},notice:any={textContent:'incomplete'};
  runInNewContext(invitationScript,{location:{hash,search},document:{getElementById:(id:string)=>id==='open'?link:notice}});
  assert.equal(!link.hidden,valid);
  if(valid)assert.equal(link.href,'safeathome://invite#code='+'a'.repeat(43));else assert.equal(link.href,undefined);
 }
});
test('public invitation landing assets contain no invitation data and enforce no-store/CSP/referrer protections without Auth or storage',async()=>{
 let authenticated=0;
 const deps={authenticate:async()=>{authenticated++;throw Error('must not authenticate');},cases:new MemoryCaseRepository([]),loadRegistry:async()=>[],now:()=>new Date()};
 const server=createMatchingServer(deps,undefined,undefined,undefined,undefined,undefined,{sharingDependencies:{...deps,simpleInvitationsEnabled:true,sharing:{execute:async()=>{throw Error('must not touch storage');}}}});
 await new Promise<void>(r=>server.listen(0,'127.0.0.1',r));const address=server.address();if(!address||typeof address==='string')throw Error();const origin='http://127.0.0.1:'+address.port;
 try{
  const page=await fetch(origin+'/invite#code='+'a'.repeat(43));assert.equal(page.status,200);assert.equal(page.headers.get('cache-control'),'no-store');assert.equal(page.headers.get('referrer-policy'),'no-referrer');assert.ok(page.headers.get('content-security-policy')?.includes("default-src 'none'"));
  assert.ok(!(await page.text()).includes('a'.repeat(43)));
  assert.equal((await fetch(origin+'/invite.js')).status,200);
  assert.equal((await fetch(origin+'/invite',{method:'POST'})).status,405);assert.equal(authenticated,0);
 }finally{server.closeAllConnections();await new Promise<void>(r=>server.close(()=>r()));}
});
