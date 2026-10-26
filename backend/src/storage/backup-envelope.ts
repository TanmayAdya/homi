import { constants, createCipheriv, createDecipheriv, createHash, createPrivateKey, createPublicKey,
  generateKeyPair, privateDecrypt, publicEncrypt, randomBytes, type KeyObject } from 'node:crypto';
import { promisify } from 'node:util';
import { dirname } from 'node:path';
import { MAX_BACKUP_PLAINTEXT_BYTES, readPrivateBackupFile, writePrivateBackupFile } from './backup-archive.ts';

const MAGIC = Buffer.from('SAHBACKUP');
const VERSION = 2, WRAPPED_BYTES = 384, NONCE_BYTES = 12, TAG_BYTES = 16;
const HEADER_BYTES = MAGIC.length + 1 + 32 + WRAPPED_BYTES + NONCE_BYTES;
export const MAX_ENVELOPE_BYTES = MAX_BACKUP_PLAINTEXT_BYTES + HEADER_BYTES + TAG_BYTES;
export const MAX_SCHEDULED_ENVELOPE_BYTES = 96 * 1024 * 1024;
const FAIL = 'Public-key backup operation failed.';
const fail = (): never => { throw new Error(FAIL); };
function key(value: Buffer | string, secret: boolean): KeyObject {
  try {
    if (!(typeof value === 'string' || Buffer.isBuffer(value)) || Buffer.byteLength(value) > 8192) fail();
    const text = value.toString();
    if (!text.startsWith(secret ? '-----BEGIN PRIVATE KEY-----\n' : '-----BEGIN PUBLIC KEY-----\n')) fail();
    const parsed = secret ? createPrivateKey(value) : createPublicKey(value);
    const details = parsed.asymmetricKeyDetails;
    const canonical = parsed.export({ format:'pem', type:secret?'pkcs8':'spki' }).toString();
    if (text !== canonical) fail();
    if (parsed.asymmetricKeyType !== 'rsa' || details?.modulusLength !== 3072 || details.publicExponent !== 65537n) fail();
    return parsed;
  } catch { return fail(); }
}
function identity(value: KeyObject) {
  const publicKey = value.type === 'private' ? createPublicKey(value) : value;
  return createHash('sha256').update(publicKey.export({ format:'der', type:'spki' })).digest();
}
export function backupRecipientFingerprint(publicPem: Buffer | string): string { return identity(key(publicPem, false)).toString('hex'); }
export async function createBackupRecipient(privatePath: string, publicPath: string): Promise<string> {
  if (privatePath === publicPath || dirname(privatePath) === dirname(publicPath)) fail();
  const pair = await promisify(generateKeyPair)('rsa', { modulusLength:3072, publicExponent:65537 });
  const privatePem = Buffer.from(pair.privateKey.export({ format:'pem', type:'pkcs8' }));
  const publicPem = Buffer.from(pair.publicKey.export({ format:'pem', type:'spki' }));
  try {
    await writePrivateBackupFile(privatePath, privatePem);
    await writePrivateBackupFile(publicPath, publicPem);
    return backupRecipientFingerprint(publicPem);
  } finally { privatePem.fill(0); }
}
export async function readBackupRecipient(path:string, secret=false):Promise<Buffer> {
  const value=await readPrivateBackupFile(path,64,8192);
  try { key(value,secret); return value; } catch { value.fill(0); return fail(); }
}
export function sealBackupToRecipient(plaintext:Buffer, publicPem:Buffer|string):Buffer {
  const symmetric = randomBytes(32);
  try {
    if (!Buffer.isBuffer(plaintext) || plaintext.length > MAX_BACKUP_PLAINTEXT_BYTES) fail();
    const recipient=key(publicPem,false),nonce=randomBytes(NONCE_BYTES);
    const wrapped=publicEncrypt({ key:recipient, padding:constants.RSA_PKCS1_OAEP_PADDING, oaepHash:'sha256' },symmetric);
    if(wrapped.length!==WRAPPED_BYTES)fail();
    const header=Buffer.concat([MAGIC,Buffer.from([VERSION]),identity(recipient),wrapped,nonce]);
    const cipher=createCipheriv('aes-256-gcm',symmetric,nonce,{authTagLength:TAG_BYTES});cipher.setAAD(header);
    return Buffer.concat([header,cipher.update(plaintext),cipher.final(),cipher.getAuthTag()]);
  } catch { return fail(); } finally { symmetric.fill(0); }
}
function validateEnvelope(value:Buffer) {
  if(!Buffer.isBuffer(value)||value.length<HEADER_BYTES+TAG_BYTES||value.length>MAX_ENVELOPE_BYTES
    ||!value.subarray(0,MAGIC.length).equals(MAGIC)||value[MAGIC.length]!==VERSION)fail();
}
export function openRecipientBackup(envelope:Buffer, privatePem:Buffer|string):Buffer {
  let symmetric:Buffer|undefined,provisional:Buffer|undefined;
  try {
    validateEnvelope(envelope);const recipient=key(privatePem,true);
    if(!identity(recipient).equals(envelope.subarray(MAGIC.length+1,MAGIC.length+33)))fail();
    symmetric=privateDecrypt({key:recipient,padding:constants.RSA_PKCS1_OAEP_PADDING,oaepHash:'sha256'},envelope.subarray(MAGIC.length+33,HEADER_BYTES-NONCE_BYTES));
    if(symmetric.length!==32)fail();
    const decipher=createDecipheriv('aes-256-gcm',symmetric,envelope.subarray(HEADER_BYTES-NONCE_BYTES,HEADER_BYTES),{authTagLength:TAG_BYTES});
    decipher.setAAD(envelope.subarray(0,HEADER_BYTES));decipher.setAuthTag(envelope.subarray(-TAG_BYTES));
    provisional=decipher.update(envelope.subarray(HEADER_BYTES,-TAG_BYTES));const final=decipher.final();
    return Buffer.concat([provisional,final]);
  }catch{return fail();}finally{symmetric?.fill(0);provisional?.fill(0);}
}
export async function writeRecipientBackup(path:string,value:Buffer){validateEnvelope(value);await writePrivateBackupFile(path,Buffer.from(value));}
export async function readRecipientBackup(path:string){const value=await readPrivateBackupFile(path,HEADER_BYTES+TAG_BYTES,MAX_ENVELOPE_BYTES);validateEnvelope(value);return value;}
