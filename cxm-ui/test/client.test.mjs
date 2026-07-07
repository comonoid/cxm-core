/**
 * CxmUI.Client envelope tests — the pure, node-testable core of the API client: decode the REAL
 * {"data":…}/{"error":…} envelope from cxm-server (fixtures/reads.json) through the Contract
 * decoders. Validates the whole client read path minus the fetch (which needs a browser/runtime).
 *
 * Run: agda --js ... CxmUI/Client.agda && node test/client.test.mjs
 */
import Client from '../_build/jAgda.CxmUI.Client.mjs';
import Contract from '../_build/jAgda.CxmUI.Contract.mjs';
import JsonMod from '../_build/jAgda.Agdelte.Json.mjs';
import { readFileSync } from 'node:fs';

const matchResult = (r) => r({ ok: (v) => ({ tag: 'ok', value: v }), err: (e) => ({ tag: 'err', error: e }) });
const N = (x) => Number(x);
const fx = JSON.parse(readFileSync(new URL('./fixtures/reads.json', import.meta.url)));

const K = Contract.KnowledgeView, EP = Contract.EpisodeView, X = Contract.ExpectationView,
      AV = Contract.AppointmentView, R = Contract.RosterView;

let passed = 0, failed = 0;
const test = (name, fn) => { try { fn(); console.log(`✓ ${name}`); passed++; } catch (e) { console.log(`✗ ${name}: ${e.message}`); failed++; } };
const eq = (a, b, m) => { if (a !== b) throw new Error(m || `expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };

// envelope(typeSlot)(decoder)(enveloped-response-string) → Result CallErr A
const envOk = (dec, obj) => {
  const r = matchResult(Client.envelope(null)(dec)(JSON.stringify(obj)));
  if (r.tag !== 'ok') throw new Error(`envelope not ok: ${JSON.stringify(r)}`);
  return r.value;
};

test('envelope + rosterListDec (GET /subjects)', () => {
  const xs = envOk(Contract.rosterListDec, fx['GET /subjects']);
  eq(xs.length, 1); eq(R.rvName(xs[0]), 'Клиент Анна 😀'); eq(N(R.rvId(xs[0])), 4);
});
test('envelope + knowledgeListDec (full KnowledgeView, /knowledge/by-subject)', () => {
  const xs = envOk(Contract.knowledgeListDec, fx['POST /knowledge/by-subject']);
  eq(xs.length, 1); eq(K.kvType(xs[0]), 'state'); eq(N(K.kvConfidence(xs[0])), 500); eq(K.kvStatus(xs[0]), 'active');
});
test('envelope + episodeListDec (/episodes/by-subject)', () => {
  const xs = envOk(Contract.episodeListDec, fx['POST /episodes/by-subject']);
  eq(N(EP.epvState(xs[0])), 100); eq(EP.epvJtbd(xs[0]), 'адаптация');
});
test('envelope + expectationListDec (/expectations/by-subject)', () => {
  const xs = envOk(Contract.expectationListDec, fx['POST /expectations/by-subject']);
  eq(X.xvStatus(xs[0]), 'unknown'); eq(N(X.xvLevel(xs[0])), 800); eq(X.xvSource(xs[0]), 'our_promise');
});
test('envelope + appointmentListDec (/appointments/by-subject)', () => {
  const xs = envOk(Contract.appointmentListDec, fx['POST /appointments/by-subject']);
  eq(AV.avStatus(xs[0]), 'scheduled'); eq(N(AV.avDuration(xs[0])), 60);
});
test('envelope error path ({"error":…} → serverErr)', () => {
  const r = matchResult(Client.envelope(null)(Contract.rosterListDec)(JSON.stringify({ error: { code: 'conflict', message: 'conflict' } })));
  if (r.tag !== 'err') throw new Error(`expected err, got ${JSON.stringify(r)}`);
  const tag = r.error({ httpErr: () => 'http', serverErr: () => 'server', decodeErr: () => 'decode' });
  eq(tag, 'server');
});
test('envelopeUnit ok ({"data":{"ok":true}}) — REAL write-response shape', () => {
  const r = matchResult(Client.envelopeUnit(JSON.stringify({ data: { ok: true } })));
  if (r.tag !== 'ok') throw new Error(`expected ok, got ${JSON.stringify(r)}`);
});
test('envelopeUnit error ({"error":…} → serverErr)', () => {
  const r = matchResult(Client.envelopeUnit(JSON.stringify({ error: { code: 'forbidden', message: 'x' } })));
  if (r.tag !== 'err') throw new Error('expected err');
  eq(r.error({ httpErr: () => 'http', serverErr: () => 'server', decodeErr: () => 'decode' }), 'server');
});

// ── /v1 social reads (Ф1.3) — fixtures captured off the live /v1 gate ────────
const CN = Contract.ContentView, TN = Contract.ThreadNodeView;
const B = (b) => b; // Bool → native JS bool under --js

test('envelope + contentListDec (/v1/feed: open post + locked teaser)', () => {
  const xs = envOk(Contract.contentListDec, fx['POST /v1/feed']);
  eq(xs.length, 2);
  eq(N(CN.cnId(xs[0])), 21); eq(N(CN.cnAuthor(xs[0])), 19); eq(B(CN.cnLocked(xs[0])), false);
  eq(CN.cnPayload(xs[0]), '{"text":"Привет, лента!"}');
  eq(B(CN.cnLocked(xs[1])), true); eq(CN.cnPayload(xs[1]), '', 'locked teaser must come stripped');
});

test('envelope + threadListDec (/v1/thread: root + reply at depth 1)', () => {
  const xs = envOk(Contract.threadListDec, fx['POST /v1/thread']);
  eq(xs.length, 2);
  eq(N(TN.tnDepth(xs[0])), 0); eq(N(TN.tnDepth(xs[1])), 1);
  eq(CN.cnPayload(TN.tnContent(xs[1])), '{"text":"ответ в тред 🧵"}');
  eq(N(CN.cnAuthor(TN.tnContent(xs[1]))), 25);
});

test('envelope + contentListDec (/v1/showcase: rank-asc, locked slot first)', () => {
  const xs = envOk(Contract.contentListDec, fx['POST /v1/showcase']);
  eq(xs.length, 2);
  eq(N(CN.cnId(xs[0])), 23); eq(B(CN.cnLocked(xs[0])), true);
  eq(N(CN.cnId(xs[1])), 21); eq(CN.cnPayload(xs[1]), '{"text":"Привет, лента!"}');
});

test('login envelope ({"data":{"token":…}} — REAL live shape, Ф4.1 drift find)', () => {
  // live /auth/login envelopes the token like every other response; Ф1.1 wrongly expected bare
  // {"token":…} — Client.login now goes through `envelope (field′ "token" string)`. Same decoder:
  const tokenDec = JsonMod['field′'](null)('token')(JsonMod.string);
  eq(envOk(tokenDec, { data: { token: 'ey.header.sig' } }), 'ey.header.sig');
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
