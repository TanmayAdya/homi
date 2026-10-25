import assert from 'node:assert/strict';
import { test } from 'node:test';
import { syntheticDiagnostic } from '../tool/linux-memory/protocol.ts';

test('synthetic setup diagnostics classify exact uncoded driver connection failures', t => {
  const diagnostics: unknown[][] = [];
  t.mock.method(console, 'error', (...args: unknown[]) => { diagnostics.push(args); });
  for (const [message, reason] of [
    ['Connection terminated due to connection timeout', 'connection_timeout'],
    ['timeout exceeded when trying to connect', 'connection_timeout'],
    ['Connection terminated unexpectedly', 'connection_terminated_unexpectedly'],
    ['Connection terminated', 'connection_terminated'],
    ['The server does not support SSL connections', 'server_ssl_unsupported'],
  ]) {
    syntheticDiagnostic('admin-connect', new Error(message));
    assert.deepEqual(diagnostics.pop(), [JSON.stringify({ kind: 'synthetic-diagnostic',
      phase: 'admin-connect', errorName: 'Error', reason })]);
  }
});

test('synthetic setup diagnostics expose finite network and certificate codes only', t => {
  const diagnostics: unknown[][] = [];
  t.mock.method(console, 'error', (...args: unknown[]) => { diagnostics.push(args); });
  for (const code of ['EAI_AGAIN', 'EHOSTUNREACH', 'ENETUNREACH', 'CERT_NOT_YET_VALID']) {
    syntheticDiagnostic('admin-connect', Object.assign(new Error('private-hostname-and-password'), { code }));
    assert.deepEqual(diagnostics.pop(), [JSON.stringify({ kind: 'synthetic-diagnostic',
      phase: 'admin-connect', errorName: 'Error', code })]);
  }
});

test('pacing diagnostics identify exact internal failures without leaking arbitrary error text', t => {
  const diagnostics: unknown[][] = [];
  t.mock.method(console, 'error', (...args: unknown[]) => { diagnostics.push(args); });
  for (const [message, reason] of [
    ['Invalid synthetic pacing clock.', 'pacing_clock_invalid'],
    ['Synthetic pacing timer did not reach its deadline.', 'pacing_deadline_unreached'],
    ['Invalid synthetic operation clock.', 'operation_clock_invalid'],
  ]) {
    syntheticDiagnostic('http-workload', new Error(message));
    assert.deepEqual(diagnostics.pop(), [JSON.stringify({ kind: 'synthetic-diagnostic', phase: 'http-workload', errorName: 'Error', reason })]);
    syntheticDiagnostic('http-workload', new Error(`${message} private-driver-detail`));
    assert.deepEqual(diagnostics.pop(), [JSON.stringify({ kind: 'synthetic-diagnostic', phase: 'http-workload', errorName: 'Error' })]);
  }
});

test('synthetic diagnostics never expose driver messages, causes, stacks or unrecognized codes', t => {
  const diagnostics: unknown[][] = [];
  t.mock.method(console, 'error', (...args: unknown[]) => { diagnostics.push(args); });
  const privateDetail = 'postgresql://owner:private-password@private-host/private-db SELECT private_column';
  for (const message of [privateDetail,
    `Connection terminated due to connection timeout ${privateDetail}`,
    `${privateDetail} timeout exceeded when trying to connect`,
    'The server does not support SSL connections\n']) {
    const error = Object.assign(new Error(message, { cause: new Error(privateDetail) }), { code: privateDetail });
    error.stack = privateDetail;
    syntheticDiagnostic('admin-connect', error);
    assert.deepEqual(diagnostics.pop(), [JSON.stringify({ kind: 'synthetic-diagnostic',
      phase: 'admin-connect', errorName: 'Error' })]);
  }
  syntheticDiagnostic('admin-connect', new Error('Connection terminated due to connection timeout',
    { cause: new Error(privateDetail) }));
  assert.deepEqual(diagnostics.pop(), [JSON.stringify({ kind: 'synthetic-diagnostic',
    phase: 'admin-connect', errorName: 'Error', reason: 'connection_timeout' })]);
});
