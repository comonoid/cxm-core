/**
 * CxmUI.Client envelope tests — the pure, node-testable core of the API client: decode the REAL
 * {"data":…}/{"error":…} envelope from cxm-server (fixtures/reads.json) through the Contract
 * decoders. Validates the whole client read path minus the fetch (which needs a browser/runtime).
 *
 * Run: agda --js ... CxmUI/Client.agda && node test/client.test.mjs
 */
import Client from '../_build/jAgda.CxmUI.Client.mjs';
import Contract from '../_build/jAgda.CxmUI.Contract.mjs';
import Widget from '../_build/jAgda.CxmUI.Widget.mjs';
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
test('envelope + evidenceListDec (/knowledge/evidence/by-knowledge — explainability)', () => {
  const ED = Contract.EvidenceView;
  const xs = envOk(Contract.evidenceListDec, fx['POST /knowledge/evidence/by-knowledge']);
  eq(xs.length, 1); eq(N(ED.edvEvent(xs[0])), 365); eq(N(ED.edvKnowledge(xs[0])), 366);
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

test('envelope + contentListDec (/v1/feed: open post + locked teaser + authorName)', () => {
  const xs = envOk(Contract.contentListDec, fx['POST /v1/feed']);
  eq(xs.length, 2);
  eq(N(CN.cnId(xs[0])), 21); eq(N(CN.cnAuthor(xs[0])), 19); eq(B(CN.cnLocked(xs[0])), false);
  eq(CN.cnAuthorName(xs[0]), '', 'v1-авторы auto-provisioned без имени');
  eq(CN.cnPayload(xs[0]), '{"text":"Привет, лента!"}');
  eq(B(CN.cnLocked(xs[1])), true); eq(CN.cnPayload(xs[1]), '', 'locked teaser must come stripped');
});

test('contentDec (authorName server-joined, непустой случай)', () => {
  const r = matchResult(JsonMod.decodeString(null)(Contract.contentDec)(
    '{"id":5,"author":9,"authorName":"Мария К.","createdAt":1,"locked":false,"payload":"{}"}'));
  if (r.tag !== 'ok') throw new Error('decode failed');
  eq(CN.cnAuthorName(r.value), 'Мария К.');
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

test('envelope + offeringListDec (/v1/offerings: paywall list)', () => {
  const OF = Contract.OfferingView;
  const xs = envOk(Contract.offeringListDec, fx['POST /v1/offerings']);
  eq(xs.length, 1);
  eq(N(OF.ofId(xs[0])), 94); eq(N(OF.ofPrice(xs[0])), 50000); eq(OF.ofCurrency(xs[0]), 'RUB');
  eq(OF.ofMetadata(xs[0]), '{"grants":[{"kind":"resource","id":92}]}');
});

test('envelope + idDec (/v1/purchase → payment id)', () => {
  eq(N(envOk(Contract.idDec, fx['POST /v1/purchase'])), 95);
});

// ── аудит-фиксы: errBody / escJson / showAmount ──────────────────────────────
test('errBody (4xx body with error envelope → serverErr, else httpErr)', () => {
  // runtime now hands the 4xx BODY to onErr; errBody recovers the server envelope
  const asTag = (ce) => ce({ httpErr: () => 'http', serverErr: (e) => 'server:' + Client.ApiErr.aeCode(e), decodeErr: () => 'decode' });
  eq(asTag(Client.errBody('{"error":{"code":"conflict","message":"conflict"}}')), 'server:conflict');
  eq(asTag(Client.errBody('HTTP 502')), 'http');
  eq(asTag(Client.errBody('<html>gateway</html>')), 'http');
});

test('escJson (quotes/backslash/newline/tab/CR)', () => {
  eq(Client.escJson('a"b'), 'a\\"b');
  eq(Client.escJson('a\\b'), 'a\\\\b');
  eq(Client.escJson('a\nb\tc\rd'), 'a\\nb\\tc\\rd');
  eq(Client.escJson('чистый текст'), 'чистый текст');
  // произвольный текст, встроенный в body, остаётся валидным JSON:
  eq(JSON.parse('{"d":"' + Client.escJson('он сказал: "нет"\n\\конец') + '"}').d,
     'он сказал: "нет"\n\\конец');
});

test('showAmount (minor units → two decimals)', () => {
  eq(Widget.showAmount(50000n), '500.00');
  eq(Widget.showAmount(5n), '0.05');
  eq(Widget.showAmount(50n), '0.50');
  eq(Widget.showAmount(12345n), '123.45');
});

// ── Body-билдеры (аудит-3 №9): чистая половина каждого биндинга — парсим как JSON и сверяем
// имена полей с серверными роутами; опечатка в имени больше не доживает до рантайма.
const jb = (s) => JSON.parse(s);
test('bodies: onboarding (register/verify/identity/login)', () => {
  let o = jb(Client.registerBody('a@b')('pw')('Имя "А"'));
  eq(o.login, 'a@b'); eq(o.password, 'pw'); eq(o.name, 'Имя "А"');
  o = jb(Client.verifyIdentityBody(7n)('hmac-tok'));
  eq(N(o.identity), 7); eq(o.token, 'hmac-tok');
  o = jb(Client.identityBody(4n)('email')('x@y'));
  eq(N(o.subject), 4); eq(o.channel, 'email'); eq(o.id, 'x@y');
  o = jb(Client.loginBody('l')('p')); eq(o.login, 'l'); eq(o.password, 'p');
});

test('bodies: cabinet creates', () => {
  eq(jb(Client.subjectBody('Мария')).name, 'Мария');
  let o = jb(Client.knowledgeBody(4n)('заметка\nс переводом'));
  eq(N(o.subject), 4); eq(o.detail, 'заметка\nс переводом');
  o = jb(Client.episodeBody(4n)(5n)('адаптация'));
  eq(N(o.protocol), 5); eq(o.jtbd, 'адаптация');
  o = jb(Client.episodeTransitionBody(6n)(200n));
  eq(N(o.episode), 6); eq(N(o.to), 200);
  o = jb(Client.protocolBody('CBT')(0n)); eq(o.name, 'CBT'); eq(N(o.initial), 0);
  o = jb(Client.protocolStateBody(5n)(100n)('в работе'));
  eq(N(o.protocol), 5); eq(N(o.code), 100); eq(o.name, 'в работе');
  o = jb(Client.protocolTransitionBody(5n)(0n)(100n)); eq(N(o.from), 0); eq(N(o.to), 100);
  o = jb(Client.expectationBody(4n)('ответ за 24ч')(800n));
  eq(o.topic, 'ответ за 24ч'); eq(N(o.level), 800);
  o = jb(Client.appointmentBody(4n)(2n)(5000n)(60n));
  eq(N(o.resource), 2); eq(N(o.start), 5000); eq(N(o.duration), 60);
  o = jb(Client.attachEvidenceBody(8n)(7n)); eq(N(o.knowledge), 8); eq(N(o.event), 7);
});

test('bodies: revises / link / tokens / offerings / promises / generic id', () => {
  let o = jb(Client.reviseBody(8n)('confirm')); eq(N(o.knowledge), 8); eq(o.kind, 'confirm');
  o = jb(Client.reviseByBody(8n)('strengthen')(50n)); eq(N(o.amount), 50);
  o = jb(Client.redetailBody(8n)('новый "текст"'));
  eq(o.kind, 'redetail'); eq(o.detail, 'новый "текст"');
  o = jb(Client.linkBody(60n)(21n)(2n)(0n));
  eq(N(o.from), 60); eq(N(o.to), 21); eq(N(o.rank), 2); eq(N(o.validTo), 0);
  eq(jb(Client.mintBody('site-a')).origin, 'site-a');
  o = jb(Client.offeringBody(1n)(50000n)('RUB')('{"grants":[{"kind":"resource","id":92}]}'));
  eq(N(o.price), 50000); eq(o.currency, 'RUB'); eq(o.metadata, '{"grants":[{"kind":"resource","id":92}]}');
  o = jb(Client.promiseBody(4n)('перезвонить')(1783500000n));
  eq(o.topic, 'перезвонить'); eq(N(o.deadline), 1783500000);
  o = jb(Client.promiseTransferBody(9n)(5n)(0n)); eq(N(o.holder), 5); eq(N(o.penalty_to), 0);
  o = jb(Client.promiseReferBody(9n)(1000n)); eq(N(o.stake), 1000);
  eq(N(jb(Client.idBody('link')(63n)).link), 63);
});

test('bodies: /v1 (identity-конверт + extras, опциональные поля опускаются)', () => {
  const cfg = Client.mkV1Cfg('https://x')('tok')('cookie')('s"1');
  let o = jb(Client.v1Body(cfg)(Client.purchaseExtra(94n)('e-1')));
  eq(o.identity_channel, 'cookie'); eq(o.identity_id, 's"1');
  eq(N(o.offering), 94); eq(o.ext_id, 'e-1');
  o = jb(Client.v1Body(cfg)(Client.publishExtra(0n)('')('')('{"text":"пост"}')));
  eq(o.parent, undefined); eq(o.visibility, undefined); eq(o.payload, '{"text":"пост"}');
  o = jb(Client.v1Body(cfg)(Client.commentExtra(21n)(21n)('private')('public')('{"text":"реплика"}')));
  eq(o.anchor_kind, 'resource'); eq(N(o.anchor_id), 21); eq(N(o.parent), 21);
  eq(o.visibility, 'private'); eq(o.listing, 'public');   // locked-реплика доступна биндингу
  o = jb(Client.v1Body(cfg)(Client.followExtra('user_id')('author-1')));
  eq(o.target_channel, 'user_id'); eq(o.target_id, 'author-1');
  o = jb(Client.v1Body(cfg)(Client.eventExtra('{"page":"/pricing"}')));   // аудит-4 №1
  eq(o.payload, '{"page":"/pricing"}'); eq(o.identity_channel, 'cookie');
});

test('mintedDec ({"data":{"id","token"}} — форма okJson-обёртки минта)', () => {
  const MT = Client.MintedToken;
  const v = envOk(Client.mintedDec, { data: { id: 18, token: 'SHK5=' } });
  eq(N(MT.mtId(v)), 18); eq(MT.mtToken(v), 'SHK5=');
});

test('envelope + intTokenListDec (GET /integration-tokens — форма listTokens-энкодера)', () => {
  const IT = Contract.IntTokenView;
  const xs = envOk(Contract.intTokenListDec, { data: [{ id: 18, scope: '/v1', revoked: false }] });
  eq(N(IT.itId(xs[0])), 18); eq(IT.itScope(xs[0]), '/v1'); eq(IT.itRevoked(xs[0]), false);
});

test('verifyIdentity-конверт ({"data":{"verified":true}})', () => {
  const dec = JsonMod['field′'](null)('verified')(JsonMod.bool);
  eq(envOk(dec, { data: { verified: true } }), true);
});

test('envelope + outboxListDec (GET /outbox — ops-вид доставки)', () => {
  const OV = Contract.OutboxView;
  const xs = envOk(Contract.outboxListDec, { data: [{ id: 3, to: 'x@y', status: 'sent' }] });
  eq(xs.length, 1); eq(OV.ovTo(xs[0]), 'x@y'); eq(OV.ovStatus(xs[0]), 'sent');
});

test('login envelope ({"data":{"token":…}} — REAL live shape, Ф4.1 drift find)', () => {
  // live /auth/login envelopes the token like every other response; Ф1.1 wrongly expected bare
  // {"token":…} — Client.login now goes through `envelope (field′ "token" string)`. Same decoder:
  const tokenDec = JsonMod['field′'](null)('token')(JsonMod.string);
  eq(envOk(tokenDec, { data: { token: 'ey.header.sig' } }), 'ey.header.sig');
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
