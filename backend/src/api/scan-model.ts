import { parseHomeRequest, type HomeSave } from '../assessment/home-model.ts';
import type { AuthenticatedUser } from './match-case.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';
import { AccountClosedError } from '../lifecycle/types.ts';
import { parseScanRequest, type ScanSave, type ScanModelRepository } from '../assessment/scan-model.ts';
export type ScanModelRoute='read-scan-model'|'save-scan-model'|'read-home-model'|'save-home-model';
export interface ScanModelDependencies {authenticate(token:string):Promise<AuthenticatedUser|null>;cases:ScanModelRepository;now():Date}
export async function handleScanModel(input:{body:unknown;bearerToken:string|null},deps:ScanModelDependencies,route:ScanModelRoute) {
 const fail=(status:number,code:string)=>({status,body:{schemaVersion:'3',error:{code,message:'The private model could not be synchronized. Review the saved copies and try again.'}},headers:{'Cache-Control':'no-store'}});
 try {
  if(!input.bearerToken || input.bearerToken.length>4096 || !/^[A-Za-z0-9._~+\/-]+=*$/.test(input.bearerToken))return fail(401,'UNAUTHENTICATED');
  let request;try{request=route.endsWith('home-model')?parseHomeRequest(input.body,route==='save-home-model'):parseScanRequest(input.body,route==='save-scan-model');}catch{request=null;}
  const user=await deps.authenticate(input.bearerToken);if(!user)return fail(401,'UNAUTHENTICATED');
  if(!evidenceIdentifier(user.userId))return fail(500,'INTERNAL_ERROR');if(!request)return fail(400,'INVALID_REQUEST');
  const result=route==='read-home-model'?await deps.cases.readHomeModelForUser(user.userId,request.caseId):route==='save-home-model'?await deps.cases.saveHomeModelForUser(user.userId,request as HomeSave,deps.now().toISOString()):route==='read-scan-model'?await deps.cases.readScanModelForUser(user.userId,request.caseId,(request as import('../assessment/scan-model.ts').ScanRead).roomId):await deps.cases.saveScanModelForUser(user.userId,request as ScanSave,deps.now().toISOString());
  if(result.status==='found')return {status:200,body:result.state,headers:{'Cache-Control':'no-store'}};
  const errors={not_found:[404,'CASE_NOT_FOUND'],conflict:[409,'CASE_REVISION_MISMATCH'],model_conflict:[409,'SCAN_MODEL_CONFLICT'],mutation_conflict:[409,'SCAN_MODEL_MUTATION_CONFLICT'],limit:[507,'SCAN_MODEL_LIMIT']} as const;
  const [status,code]=errors[result.status];return fail(status,code);
 }catch(e){return fail(e instanceof AccountClosedError?409:503,e instanceof AccountClosedError?'ACCOUNT_CLOSED':'SERVICE_UNAVAILABLE');}
}
