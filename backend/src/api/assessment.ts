import { AccountClosedError } from '../lifecycle/types.ts';
import { exact, parseAssessmentSave, type AssessmentRepository } from '../assessment/metadata.ts';
import { parseAnnotationRequest, type AnnotationRead, type AnnotationSave, type AnnotationRepository } from '../assessment/annotations.ts';
import { evidenceIdentifier } from '../evidence/validation.ts';
import type { AuthenticatedUser } from './match-case.ts';
export type AssessmentRoute='read-assessment'|'save-assessment'|'read-evidence-annotations'|'save-evidence-annotations';
export interface AssessmentDependencies {authenticate(token:string):Promise<AuthenticatedUser|null>;cases:AssessmentRepository&AnnotationRepository;now():Date}
const errors={not_found:[404,'CASE_NOT_FOUND'],conflict:[409,'CASE_REVISION_MISMATCH'],evidence_conflict:[409,'EVIDENCE_CONFLICT'],
 assessment_conflict:[409,'ASSESSMENT_CONFLICT'],mutation_conflict:[409,'ASSESSMENT_MUTATION_CONFLICT'],history_limit:[507,'ASSESSMENT_HISTORY_LIMIT'],annotation_conflict:[409,'ANNOTATION_CONFLICT']} as const;
export async function handleAssessment(input:{body:unknown;bearerToken:string|null},deps:AssessmentDependencies,route:AssessmentRoute) {
 const failure=(status:number,code:string)=>({status,body:{schemaVersion:'2',error:{code,message:'Reload and review the current assessment before continuing.'}},headers:{'Cache-Control':'no-store'}});
 try {
  const token=input.bearerToken;if(!token||token.length>4096||/\s/.test(token))return failure(401,'UNAUTHENTICATED');
  let parsed:unknown;try {
   if(route==='read-assessment') {if(!exact(input.body,['schemaVersion','caseId'])||input.body.schemaVersion!=='2'||!evidenceIdentifier(input.body.caseId))throw Error();parsed=structuredClone(input.body);}
   else parsed=route==='save-assessment'?parseAssessmentSave(input.body):parseAnnotationRequest(input.body,route==='save-evidence-annotations');
  }catch{parsed=null;}
  let user;try{user=await deps.authenticate(token);}catch(e){return failure(e instanceof AccountClosedError?409:503,e instanceof AccountClosedError?'ACCOUNT_CLOSED':'SERVICE_UNAVAILABLE');}
  if(user===null)return failure(401,'UNAUTHENTICATED');if(!evidenceIdentifier(user.userId))return failure(500,'INTERNAL_ERROR');
  if(parsed===null)return failure(400,'INVALID_REQUEST');
  const now=deps.now().toISOString();
  const result=route==='read-assessment'?await deps.cases.readAssessmentForUser(user.userId,(parsed as {caseId:string}).caseId)
   :route==='save-assessment'?await deps.cases.saveAssessmentForUser(user.userId,parsed as ReturnType<typeof parseAssessmentSave>,now)
   :route==='read-evidence-annotations'?await deps.cases.readAnnotationsForUser(user.userId,parsed as AnnotationRead)
   :await deps.cases.saveAnnotationsForUser(user.userId,parsed as AnnotationSave,now);
  if(result.status==='found')return {status:200,body:result.state,headers:{'Cache-Control':'no-store'}};
  const [status,code]=errors[result.status];return failure(status,code);
 }catch(e){return failure(e instanceof AccountClosedError?409:503,e instanceof AccountClosedError?'ACCOUNT_CLOSED':'SERVICE_UNAVAILABLE');}
}
