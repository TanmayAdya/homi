import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { MAX_TEMPLATE_BYTES, verifyTemplateBytes } from '../src/forms/template-artifact.ts';

const bytes = Buffer.from('%PDF-1.7\nsynthetic content pin test\n%%EOF\n');
const digest = createHash('sha256').update(bytes).digest('hex');

test('template byte verification returns the exact content digest without modifying input', () => {
  const copy = Buffer.from(bytes);
  assert.equal(verifyTemplateBytes(bytes, digest), digest);
  assert.deepEqual(bytes, copy);
});

test('one changed byte, malformed digests, non-PDF and oversized inputs fail closed', () => {
  const changed = Buffer.from(bytes); changed[10] ^= 1;
  assert.throws(() => verifyTemplateBytes(changed, digest));
  for (const invalid of ['', digest.toUpperCase(), `${digest}\n`, 'x'.repeat(64)]) {
    assert.throws(() => verifyTemplateBytes(bytes, invalid));
  }
  const html = Buffer.from('<html>not a PDF</html>');
  assert.throws(() => verifyTemplateBytes(html, createHash('sha256').update(html).digest('hex')));
  assert.throws(() => verifyTemplateBytes(Buffer.alloc(MAX_TEMPLATE_BYTES + 1), digest));
  assert.throws(() => verifyTemplateBytes(Buffer.alloc(0), digest));
});
