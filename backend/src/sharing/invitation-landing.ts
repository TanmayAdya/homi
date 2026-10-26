import type { IncomingMessage, ServerResponse } from 'node:http';

export const invitationPage = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>Safe at Home invitation</title><main><h1>Safe at Home invitation</h1><p>Open the installed Safe at Home test app, sign in with the email address invited by the owner, and review the permissions before accepting.</p><p id="notice">This invitation link is incomplete. Ask the owner for a new link.</p><p><a id="open" hidden>Open Safe at Home</a></p><p>If the app does not open, open it yourself and paste the full invitation link in Shared with me. If you do not have a compatible app, ask the owner for installation instructions.</p><p>Opening this page does not accept an invitation or share your information.</p></main><script src="/invite.js" defer></script></html>`;
export const invitationScript = `"use strict";(()=>{const match=/^#code=([A-Za-z0-9_-]{43})$/.exec(location.hash);if(!match||location.search)return;const link=document.getElementById("open");link.href="safeathome://invite#code="+match[1];link.hidden=false;document.getElementById("notice").textContent="Only the invited verified email account can use this one-use invitation. Do not forward it.";})();`;
export function invitationLanding(request: IncomingMessage, response: ServerResponse): boolean {
  if (!['/invite','/invite.js'].includes(request.url ?? '')) return false;
  const method = request.method;
  const script = request.url === '/invite.js';
  response.writeHead(method === 'GET' || method === 'HEAD' ? 200 : 405, {
    'Content-Type': script ? 'application/javascript; charset=utf-8' : 'text/html; charset=utf-8',
    'Cache-Control':'no-store', 'Referrer-Policy':'no-referrer', 'X-Content-Type-Options':'nosniff',
    'Content-Security-Policy':"default-src 'none'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'",
    'Permissions-Policy':'camera=(), microphone=(), geolocation=()',
    ...(method !== 'GET' && method !== 'HEAD' ? { Allow:'GET, HEAD' } : {}),
  });
  response.end(method === 'GET' ? script ? invitationScript : invitationPage : undefined);
  request.resume(); return true;
}
