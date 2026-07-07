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
const K = Contract.KnowledgeView, P = Contract.ProfileView, X = Contract.ExpectationView,
      EV = Contract.ExperienceView, ED = Contract.EvidenceView, S = Contract.SubjectView, EP = Contract.EpisodeView;

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

test('profileDec (real /profile aggregate)', () => {
  const v = decOk(Contract.profileDec, '{"subject":2,"activeKnowledge":3,"activeEpisodes":1,"eventCount":0}');
  eq(N(P.pvSubject(v)), 2); eq(N(P.pvActiveKnowledge(v)), 3); eq(N(P.pvActiveEpisodes(v)), 1);
});

test('expectationDec (status = met)', () => {
  const v = decOk(Contract.expectationDec,
    '{"id":10,"subject":6,"topic":"reply","source":"our_promise","level":700,"status":"met","createdAt":1783110055}');
  eq(N(X.xvLevel(v)), 700); eq(X.xvStatus(v), 'met'); eq(X.xvTopic(v), 'reply');
});

test('experienceDec (touch with isPeak=true)', () => {
  const v = decOk(Contract.experienceDec,
    '{"id":7,"subject":6,"counterpart":0,"channel":"internal","actor":"staff","type":"feature_use","timestamp":1783110055,"episode":0,"isPeak":true,"isEnd":false}');
  eq(EV.evChannel(v), 'internal'); eq(EV.evActor(v), 'staff'); eq(EV.evIsPeak(v), true); eq(EV.evIsEnd(v), false);
});

test('evidenceDec (chain row)', () => {
  const v = decOk(Contract.evidenceDec, '{"id":9,"knowledge":8,"event":7,"createdAt":1783110055}');
  eq(N(ED.edvKnowledge(v)), 8); eq(N(ED.edvEvent(v)), 7);
});

test('subjectDec (roster row)', () => {
  const v = decOk(Contract.subjectDec, '{"id":6,"name":"ClientX","email":"","tenant":2,"provisional":false}');
  eq(S.svName(v), 'ClientX'); eq(N(S.svTenant(v)), 2); eq(S.svProvisional(v), false);
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

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
