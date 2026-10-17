'use strict';
/**
 * Suite 2, local half: apps-script/Code.gs and appsscript.json, unchanged, in an Apps
 * Script runtime (gas_runtime.js) that talks to the real stack through PostgREST and
 * Supabase-style API keys. Every scenario is something the bridge must survive in a real
 * Google account. Run with the stack up: tests/integration/bridge/run.sh
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const acorn = require('acorn');
const { World, loadProject, SCOPES } = require('./gas_runtime');

const ROOT = path.resolve(__dirname, '../../..');
const CODE = path.join(ROOT, 'apps-script/Code.gs');
const MANIFEST = JSON.parse(fs.readFileSync(path.join(ROOT, 'apps-script/appsscript.json'), 'utf8'));
const LOGICAL = 'https://lifeos-it.supabase.co';
const SECRET = 'sb_secret_lifeos_integration_test';
const PUBLISHABLE = 'sb_publishable_lifeos_integration_test';
const OWNER = 'owner@lifeos.test';

function sql(q) {
  const r = spawnSync('psql', ['-tAX', '-v', 'ON_ERROR_STOP=1', '-c', q], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error('psql: ' + r.stderr);
  return r.stdout.trim();
}
const rows = (q) => JSON.parse(sql(`select coalesce(json_agg(t), '[]') from (${q}) t`));
const uid = () => Math.random().toString(36).slice(2, 10);

function world(opts = {}) {
  const w = new World({
    user: OWNER,
    manifest: opts.manifest === undefined ? MANIFEST : opts.manifest,
    properties: Object.assign({ SUPABASE_URL: LOGICAL, SUPABASE_SECRET_KEY: SECRET }, opts.properties || {}),
  });
  w.hostMap[LOGICAL + '/rest/v1'] = process.env.LIFEOS_REST_URL;
  w.gateway[SECRET] = process.env.LIFEOS_SERVICE_KEY;
  w.gateway[PUBLISHABLE] = process.env.LIFEOS_ANON_KEY;
  for (const f of ['fld-inbox', 'fld-emergency', 'fld-backups', 'fld-catch-all']) w.addFolder(f);
  return w;
}
const project = (w) => loadProject(w, [CODE]);

function pdf(text) { return Buffer.from('%PDF-1.4\n% ' + text + '\n%%EOF\n'); }

/** A mail the email intake has already filed in an in-scope category. */
function intakeMail(w, { category = 'bills_payments', attachments } = {}) {
  const id = 'it-' + uid();
  w.addMessage({ id, subject: 'Rechnung ' + id, from: 'rechnung@stadtwerke-test.de', attachments });
  sql(`insert into emails (gmail_message_id, category, subject, has_attachments, attachment_names, received_at, last_intake_at)
       values ('${id}', '${category}', 'Rechnung', true, array[${attachments.map((a) => `'${a.name}'`).join(',') || "''"}], now(), clock_timestamp())`);
  return id;
}

test.before(() => {
  // a quiet baseline: every night job ran recently, nothing waits in the outbox
  sql(`insert into email_processing_runs (skill_version, started_at, run_at, notes) values ('it', now(), now(), 'baseline');
       insert into processing_runs (skill_version, started_at, run_at, notes) values ('it', now(), now(), 'baseline');
       insert into briefings (briefing_date, payload, suppressed) values (current_date, '{}', true) on conflict do nothing;
       update outbox set sent_at = now() where sent_at is null;`);
});

// ---- static ------------------------------------------------------------------------------

test('Code.gs is plain Apps Script V8 (ES2020 script, no modules or Node globals)', () => {
  const src = fs.readFileSync(CODE, 'utf8');
  acorn.parse(src, { ecmaVersion: 2020, sourceType: 'script' });
  assert.doesNotMatch(src, /\brequire\(|\bimport\s|\bprocess\.|\bmodule\.exports/);
});

test('the manifest declares a scope for every Google service the code calls', () => {
  const src = fs.readFileSync(CODE, 'utf8');
  const services = new Set(src.match(/\b(GmailApp|DriveApp|DocumentApp|MailApp|UrlFetchApp|ScriptApp|Session)\.[a-z]\w*/g));
  for (const call of services) {
    const keys = Object.keys(SCOPES).filter((k) => k.startsWith(call));
    assert.ok(keys.length, `no scope entry for ${call}`);
    for (const k of keys) {
      assert.ok(SCOPES[k].some((s) => MANIFEST.oauthScopes.includes(s)), `${k} needs one of ${SCOPES[k]}`);
    }
  }
  assert.ok(!MANIFEST.oauthScopes.includes('https://mail.google.com/'), 'full Gmail scope is back');
});

// ---- install --------------------------------------------------------------------------------

test('install refuses a missing URL and the publishable key, with the message setup documents', () => {
  let w = world({ properties: { SUPABASE_URL: '' } });
  assert.throws(() => project(w).install(), /SUPABASE_URL is missing/);
  w = world({ properties: { SUPABASE_SECRET_KEY: PUBLISHABLE } });
  assert.throws(() => project(w).install(), /publishable key/);
  w = world({ properties: { SUPABASE_SECRET_KEY: 'sb_secret_wrong' } });
  assert.throws(() => project(w).install(), /-> 401/);
});

test('install checks access, creates exactly one 15-minute trigger, and writes a heartbeat', () => {
  const w = world();
  const p = project(w);
  p.install();
  p.install();
  assert.equal(w.triggers.length, 1);
  assert.equal(w.triggers[0].fn, 'run');
  assert.equal(w.triggers[0].every, 15);
  const [hb] = rows(`select script_version, finished_at is not null as finished, errors from bridge_runs order by started_at desc limit 1`);
  assert.deepEqual(hb, { script_version: 'bridge-3.2', finished: true, errors: [] });
});

test('a URL outside the allowlist is refused by Apps Script itself', () => {
  const w = world({ properties: { SUPABASE_URL: 'https://example.com' } });
  assert.throws(() => project(w).install(), /not allowed by urlFetchWhitelist/);
});

test('without the read-only Gmail scope install fails early with the documented fix', () => {
  const manifest = Object.assign({}, MANIFEST, { oauthScopes: MANIFEST.oauthScopes.filter((s) => !/gmail/.test(s)) });
  const w = world({ manifest });
  w.addMessage({ subject: 'x', attachments: [{ name: 'a.pdf', contentType: 'application/pdf', bytes: pdf('a') }] });
  assert.throws(() => project(w).install(), /Gmail read check failed.*mail\.google\.com/);
});

// ---- copying --------------------------------------------------------------------------------

test('copies in-scope attachments by type and size, names them by message, records the rest', () => {
  const w = world();
  const id = intakeMail(w, { attachments: [
    { name: 'Rechnung.pdf', contentType: 'application/pdf', bytes: pdf('invoice') },
    { name: 'Scan.png', contentType: 'image/png', bytes: Buffer.from([0x89, 0x50, 0x4e, 0x47]) },
    { name: 'Vertrag.pdf', contentType: 'application/octet-stream', bytes: pdf('contract') },
    { name: 'tracking.zip', contentType: 'application/zip', bytes: Buffer.from('PK') },
    { name: 'huge.pdf', contentType: 'application/pdf', bytes: Buffer.alloc(10), size: 30 * 1024 * 1024 },
    { name: 'logo.png', contentType: 'image/png', bytes: Buffer.from([1]), inline: true },
  ] });
  project(w).run();
  const inbox = w.filesIn('fld-inbox').map((f) => f.name).sort();
  assert.deepEqual(inbox, [`${id}_Rechnung.pdf`, `${id}_Scan.png`, `${id}_Vertrag.pdf`]);
  const copied = w.filesIn('fld-inbox').find((f) => f.name.endsWith('Rechnung.pdf'));
  assert.equal(copied.bytes.toString(), pdf('invoice').toString(), 'bytes changed on the way');
  const staged = rows(`select filename, mime_type from attachment_staging where gmail_message_id = '${id}' order by filename`);
  assert.deepEqual(staged.map((r) => [r.filename, r.mime_type]), [
    ['Rechnung.pdf', 'application/pdf'], ['Scan.png', 'image/png'], ['Vertrag.pdf', 'application/pdf']]);
  const [msg] = rows(`select copied, skipped from bridge_messages where gmail_message_id = '${id}'`);
  assert.equal(msg.copied, 3);
  assert.deepEqual(msg.skipped.map((s) => s.filename).sort(), ['huge.pdf', 'tracking.zip']);
});

test('a message processed again copies nothing twice', () => {
  const w = world();
  const id = intakeMail(w, { attachments: [{ name: 'Bescheid.pdf', contentType: 'application/pdf', bytes: pdf('b') }] });
  const p = project(w);
  p.run(); p.run();
  // the queue view re-offers a message when a file was skipped as octet-stream; the copy
  // step itself must still refuse to copy what is already staged and alive
  const stats = { copied: 0, errors: [] };
  p.bridgeMessage_(id, p.DriveApp.getFolderById('fld-inbox'), stats);
  assert.equal(stats.copied, 0);
  assert.equal(w.filesIn('fld-inbox').filter((f) => f.name.startsWith(id)).length, 1);
  assert.equal(Number(sql(`select count(*) from attachment_staging where gmail_message_id = '${id}'`)), 1);
});

test('out-of-scope categories are never copied', () => {
  const w = world();
  const id = intakeMail(w, { category: 'personal_social', attachments: [{ name: 'Foto.jpg', contentType: 'image/jpeg', bytes: Buffer.from([1, 2]) }] });
  project(w).run();
  assert.equal(w.filesIn('fld-inbox').filter((f) => f.name.startsWith(id)).length, 0);
});

test('a copy that vanished from Drive is copied again; one whose original is gone too is marked', () => {
  const w = world();
  const id = intakeMail(w, { attachments: [{ name: 'Police.pdf', contentType: 'application/pdf', bytes: pdf('p') }] });
  const p = project(w);
  p.run();
  const first = w.filesIn('fld-inbox').find((f) => f.name.startsWith(id));
  first.trashed = true;
  sql(`update attachment_staging set last_verified_at = now() - interval '2 hours' where gmail_message_id = '${id}'`);
  p.run();
  const [row] = rows(`select heal_count, drive_file_id from attachment_staging where gmail_message_id = '${id}'`);
  assert.equal(row.heal_count, 1);
  assert.notEqual(row.drive_file_id, first.id);

  w.files.get(row.drive_file_id).trashed = true;
  w.messages.delete(id);
  sql(`update attachment_staging set last_verified_at = now() - interval '2 hours' where gmail_message_id = '${id}'`);
  p.run();
  const [gone] = rows(`select resolution from attachment_staging where gmail_message_id = '${id}'`);
  assert.equal(gone.resolution, 'drive_file_missing');
  assert.ok(w.sent.some((m) => /attachment-bridge: \d+ error/.test(m.subject)), 'the owner was not told');
});

test('a message that no longer exists is recorded, not retried forever', () => {
  const w = world();
  const id = intakeMail(w, { attachments: [{ name: 'x.pdf', contentType: 'application/pdf', bytes: pdf('x') }] });
  w.messages.delete(id);
  project(w).run();
  const [m] = rows(`select copied, skipped from bridge_messages where gmail_message_id = '${id}'`);
  assert.equal(m.copied, 0);
  assert.equal(m.skipped[0].reason, 'message_not_found');
});

test('when the database refuses the staging row, the Drive copy is trashed (no orphan files)', () => {
  const w = world();
  const id = intakeMail(w, { attachments: [{ name: 'orphan.pdf', contentType: 'application/pdf', bytes: pdf('o') }] });
  w.faults.push({ when: (m, u) => m === 'POST' && u.includes('/attachment_staging'), status: 500, body: '{"message":"boom"}' });
  project(w).run();
  const created = w.filesIn('fld-inbox').filter((f) => f.name.startsWith(id));
  assert.equal(created.length, 1);
  assert.equal(created[0].trashed, true);
});

// ---- outbox ----------------------------------------------------------------------------------

test('outbox mail goes to this account only, prefixed, one line subject, and is marked sent', () => {
  sql(`insert into outbox (kind, subject, body, source) values
       ('brief', 'Daily brief 2026-10-18: pay rent', 'line 1' || chr(10) || 'line 2', 'it'),
       ('review', '[Life OS] Review' || chr(10) || '2026-09', 'decisions', 'it')`);
  const w = world();
  project(w).run();
  const mine = w.sent.filter((m) => /Daily brief 2026-10-18|Review 2026-09/.test(m.subject));
  assert.equal(mine.length, 2);
  for (const m of mine) {
    assert.equal(m.to, OWNER);
    assert.match(m.subject, /^\[Life OS\] /);
    assert.doesNotMatch(m.subject, /\n/);
  }
  assert.equal(Number(sql(`select count(*) from outbox where source = 'it' and sent_at is null`)), 0);
  assert.ok(w.messages.size > 0 && [...w.messages.values()].some((m) => m.labels.includes('SENT') && /Daily brief/.test(m.subject)),
    'the brief must arrive as the owner\'s own SENT mail, which is how the intake recognises it');
});

test('a failed send counts an attempt and is retried, then given up after five', () => {
  const src = 'it-retry-' + uid();
  sql(`insert into outbox (kind, subject, body, source) values ('failure', 'retry me', 'x', '${src}')`);
  const w = world();
  w.faults.push({ when: () => false });
  const p = project(w);
  const realSend = p.MailApp.sendEmail;
  p.MailApp.sendEmail = (o) => { if (o.subject.includes('retry me')) throw new Error('Service invoked too many times'); return realSend(o); };
  for (let i = 0; i < 6; i++) p.run();
  const [r] = rows(`select attempts, sent_at, last_error from outbox where source = '${src}'`);
  assert.equal(r.attempts, 5);
  assert.equal(r.sent_at, null);
  assert.match(r.last_error, /too many times/);
});

// ---- watchdog, binder, drive check ------------------------------------------------------------

test('an overdue night job is reported once per 12 hours', () => {
  sql(`insert into email_processing_runs (skill_version, started_at, run_at, notes) values ('it', now() - interval '3 days', now() - interval '3 days', 'old');
       update email_processing_runs set run_at = now() - interval '40 hours' where notes = 'baseline'`);
  const w = world();
  const p = project(w);
  p.run(); p.run();
  const alerts = w.sent.filter((m) => /email-intake has not run for/.test(m.subject));
  assert.equal(alerts.length, 1);
  assert.match(alerts[0].subject, /^\[Life OS\] /);
  sql(`update email_processing_runs set run_at = now() where notes = 'baseline'`);
});

test('the emergency binder is written once a day and only when its content changed', () => {
  sql(`select set_config('app.actor','test',false); update life_settings set value = '[{"name":"Test Contact","role":"sibling","contact":"+49 30 000000"}]' where key = 'emergency_contacts'`);
  const w = world();
  const p = project(w);
  p.run();
  const docs = w.filesIn('fld-emergency').filter((f) => f.doc);
  assert.equal(docs.length, 1);
  const doc = docs[0];
  assert.equal(w.properties.dossier_doc_id, doc.id);
  const text = doc.doc.kids.map((k) => k.text).join('\n');
  assert.match(text, /Test Contact/);
  assert.equal(doc.doc.kids[doc.doc.kids.length - 1].type, 'PARAGRAPH', 'the body must end on a paragraph');
  const saves = doc.doc.saves;

  w.properties.dossier_date = '2000-01-01';          // a new day, same content: no rewrite
  p.run();
  assert.equal(doc.doc.saves, saves);

  w.properties.dossier_date = '2000-01-01';          // a new day, new content: rewrite in place
  sql(`select set_config('app.actor','test',false); update life_settings set value = '[{"name":"Second Contact","role":"friend","contact":"+49 1"}]' where key = 'emergency_contacts'`);
  p.run();
  assert.equal(doc.doc.saves, saves + 1);
  assert.match(doc.doc.kids.map((k) => k.text).join('\n'), /Second Contact/);
  assert.equal(w.filesIn('fld-emergency').filter((f) => f.doc).length, 1, 'a second binder was created');
});

test('indexed documents whose Drive file is gone are marked once a day', () => {
  const live = 'it-live-' + uid(), gone = 'it-gone-' + uid();
  sql(`insert into documents (drive_file_id, name, drive_url, status, last_intake_at) values
       ('${live}', 'live.pdf', 'https://drive.test/${live}', 'current', clock_timestamp()),
       ('${gone}', 'gone.pdf', 'https://drive.test/${gone}', 'current', clock_timestamp())`);
  const w = world();
  w.files.set(live, { id: live, name: 'live.pdf', mimeType: 'application/pdf', bytes: pdf('l'), parents: new Set(['fld-inbox']), trashed: false, owner: OWNER });
  project(w).run();
  const r = rows(`select drive_file_id, drive_missing_since is not null as missing from documents where drive_file_id in ('${live}', '${gone}') order by drive_file_id`);
  assert.deepEqual(Object.fromEntries(r.map((x) => [x.drive_file_id, x.missing])), { [gone]: true, [live]: false });
});

// ---- what the bridge must never do ------------------------------------------------------------

test('across every scenario: no Gmail write, no sharing, mail only to the owner', () => {
  const w = world();
  intakeMail(w, { attachments: [{ name: 'final.pdf', contentType: 'application/pdf', bytes: pdf('f') }] });
  project(w).run();
  assert.ok(!w.calls.some((c) => /GmailApp\.sendEmail|GmailMessage\.(forward|reply)|DriveFile\.(addEditor|setSharing)/.test(c)));
  assert.ok(w.sent.every((m) => m.to === OWNER));
});

// ---- the in-Google test, dry-run here first ---------------------------------------------------

test('gas-e2e/E2E.gs passes in this runtime (so a red real-Google run means Google differs)', () => {
  const E2E = path.join(ROOT, 'tests/integration/gas-e2e/E2E.gs');
  acorn.parse(fs.readFileSync(E2E, 'utf8'), { ecmaVersion: 2020, sourceType: 'script' });
  const before = sql(`select value from life_settings where key = 'drive_folders'`);
  const w = world();
  const p = loadProject(w, [CODE, E2E]);
  try {
    const setup = JSON.parse(p.lifeosE2ESetup());
    assert.equal(setup.user, OWNER);
    sql(`select set_config('app.actor','test',false); update life_settings set value = '${JSON.stringify(setup.folders)}' where key = 'drive_folders'`);
    const nonce = 'n' + uid();
    sql(`insert into outbox (kind, subject, body, source) values ('notice', 'e2e outbox ${nonce}', 'x', 'e2e-${nonce}')`);
    const report = JSON.parse(p.lifeosE2E(nonce));
    const failed = report.checks.filter((c) => !c.ok);
    assert.deepEqual(failed, [], JSON.stringify(failed, null, 2));
    assert.ok(report.checks.length >= 9);
    assert.equal(w.triggers.length, 0, 'cleanup left a trigger');
  } finally {
    sql(`select set_config('app.actor','test',false); update life_settings set value = '${before}' where key = 'drive_folders'`);
  }
});
