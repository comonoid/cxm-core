/**
 * CxmUI.Contract decoder tests — decode REAL cxm-server JSON output (golden fixtures captured
 * from live-smoke runs) and assert the typed views come out field-for-field. This is the
 * contract-fidelity test: if a server encoder or a client decoder drifts, this fails.
 *
 * Run: cd ~/cxm-core/cxm-ui && agda --js ... CxmUI/Contract.agda && node test/contract.test.mjs
 */
import Contract from '../_build/jAgda.CxmUI.Contract.mjs';
import Json from '../_build/jAgda.Agdelte.Json.mjs';

const decodeString = Json.decodeString;                       // (typeSlot)(decoder)(str) after the fix
const matchResult = (r) => r({ ok: (v) => ({ tag: 'ok', value: v }), err: (e) => ({ tag: 'err', error: e }) });
const N = (x) => Number(x);                                   // nat → BigInt in --js; normalise
const B = (b) => b({ 'true': () => true, 'false': () => false });

// record field projections live under the record namespace (Contract.<Rec>.<field>)
const K = Contract.KnowledgeView, X = Contract.ExpectationView,
      ED = Contract.EvidenceView, EP = Contract.EpisodeView;

let passed = 0, failed = 0;
const test = (name, fn) => { try { fn(); console.log(`✓ ${name}`); passed++; } catch (e) { console.log(`✗ ${name}: ${e.message}`); failed++; } };
const eq = (a, b, m) => { if (a !== b) throw new Error(m || `expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); };
const decOk = (dec, s) => { const r = matchResult(decodeString(null)(dec)(s)); if (r.tag !== 'ok') throw new Error(`decode failed: ${JSON.stringify(r)}`); return r.value; };

// ── Fixtures: verbatim from live cxm-server smokes ──────────────────────────
test('knowledgeDec (trait, real /knowledge/by-subject row)', () => {
  const v = decOk(Contract.knowledgeDec,
    '{"id":3,"subject":2,"type":"trait","source":"inferred","confidence":720,"validFrom":1783099476,"validTo":0,"decay":0,"status":"active","detail":"convincer:hear/n-times/3","episode":0}');
  eq(N(K.kvId(v)), 3); eq(N(K.kvSubject(v)), 2);
  eq(K.kvType(v), 'trait'); eq(K.kvSource(v), 'inferred');
  eq(N(K.kvConfidence(v)), 720); eq(K.kvStatus(v), 'active');
  eq(K.kvDetail(v), 'convincer:hear/n-times/3');
});

test('knowledgeDec (FACT forced observed/1000)', () => {
  const v = decOk(Contract.knowledgeDec,
    '{"id":5,"subject":2,"type":"fact","source":"observed","confidence":1000,"validFrom":1783099476,"validTo":0,"decay":0,"status":"active","detail":"DOB verified","episode":0}');
  eq(K.kvType(v), 'fact'); eq(N(K.kvConfidence(v)), 1000); eq(K.kvSource(v), 'observed');
});

test('expectationDec (status = met)', () => {
  const v = decOk(Contract.expectationDec,
    '{"id":10,"subject":6,"topic":"reply","source":"our_promise","level":700,"status":"met","createdAt":1783110055}');
  eq(N(X.xvLevel(v)), 700); eq(X.xvStatus(v), 'met'); eq(X.xvTopic(v), 'reply');
});

test('evidenceDec (real /knowledge/evidence/by-knowledge row)', () => {
  const v = decOk(Contract.evidenceDec, '{"id":367,"knowledge":366,"event":365,"createdAt":1783442268}');
  eq(N(ED.edvKnowledge(v)), 366); eq(N(ED.edvEvent(v)), 365);
});

test('episodeDec (line of work)', () => {
  const v = decOk(Contract.episodeDec, '{"id":5,"subject":2,"protocol":4,"state":0,"jtbd":"reduce anxiety"}');
  eq(N(EP.epvProtocol(v)), 4); eq(EP.epvJtbd(v), 'reduce anxiety');
});

test('knowledgeListDec (array of rows → native JS array)', () => {
  const xs = decOk(Contract.knowledgeListDec,
    '[{"id":3,"subject":2,"type":"trait","source":"inferred","confidence":720,"validFrom":1,"validTo":0,"decay":0,"status":"active","detail":"d","episode":0},{"id":4,"subject":2,"type":"hypothesis","source":"stated","confidence":900,"validFrom":1,"validTo":0,"decay":0,"status":"active","detail":"e","episode":0}]');
  eq(xs.length, 2); eq(N(K.kvId(xs[0])), 3); eq(N(K.kvId(xs[1])), 4); eq(K.kvType(xs[1]), 'hypothesis');
});

// ── Work strategy (panel VIII.a, Ф2.5): parseWorkStrategy over opaque kDetail ────────────────
// kDetail is operator-authored and stored verbatim (no server encoder), so the convention
// {"kind":"work_strategy",…} is tested here at its typed edge. Maybe is Scott-encoded.
const W = Contract.WorkStrategyView;
const mb = (m) => m({ just: (v) => ({ has: true, value: v }), nothing: () => ({ has: false }) });
const parseWS = (s) => mb(Contract.parseWorkStrategy(s));

test('parseWorkStrategy (full convention form)', () => {
  const r = parseWS('{"kind":"work_strategy","sync":true,"detail_first":false,"handoff_complete_when":"тикет закрыт и есть резюме"}');
  if (!r.has) throw new Error('expected just');
  const w = r.value;
  const sy = mb(W.wsSync(w)), df = mb(W.wsDetailFirst(w)), ho = mb(W.wsHandoff(w));
  eq(sy.has, true); eq(sy.value, true);
  eq(df.has, true); eq(df.value, false);
  eq(ho.has, true); eq(ho.value, 'тикет закрыт и есть резюме');
});

test('parseWorkStrategy (bare {"kind":"work_strategy"} — the real fixture detail)', () => {
  // exact detail shape of the live row in test/fixtures/reads.json
  const r = parseWS('{"kind":"work_strategy"}');
  if (!r.has) throw new Error('expected just');
  const w = r.value;
  eq(mb(W.wsSync(w)).has, false); eq(mb(W.wsDetailFirst(w)).has, false); eq(mb(W.wsHandoff(w)).has, false);
});

test('parseWorkStrategy (alien kind → nothing)', () => {
  eq(parseWS('{"kind":"convincer","sync":true}').has, false);
});

test('parseWorkStrategy (non-JSON / plain-text detail → nothing)', () => {
  eq(parseWS('convincer:hear/n-times/3').has, false);
  eq(parseWS('').has, false);
});

test('parseWorkStrategy (kDetail of a decoded knowledge row, end-to-end)', () => {
  const v = decOk(Contract.knowledgeDec,
    '{"id":5,"subject":4,"type":"trait","source":"stated","confidence":500,"validFrom":1783429954,"validTo":0,"decay":0,"status":"active","detail":"{\\"kind\\":\\"work_strategy\\",\\"sync\\":false}","episode":0}');
  const r = parseWS(K.kvDetail(v));
  if (!r.has) throw new Error('expected just');
  const sy = mb(W.wsSync(r.value));
  eq(sy.has, true); eq(sy.value, false);
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
