/**
 * claude-life-os bridge: end-to-end test that runs INSIDE Google Apps Script.
 *
 * Pushed next to the unchanged Code.gs and appsscript.json into a dedicated test project
 * (never your real bridge) by tests/integration/gas-e2e/run.sh, and called through the
 * Apps Script API. It exercises the real Gmail, Drive, Docs, MailApp, triggers and
 * UrlFetchApp of a real Google account, under the manifest's real OAuth scopes, against
 * a dedicated Supabase test project. Nothing here ships to users.
 *
 * Every function returns a JSON report instead of throwing, so the runner sees every
 * check, not only the first failure.
 */

var E2E_ROOT_NAME = 'Life OS E2E (test, safe to delete)';

/** Creates (or finds) the test folders and returns their ids for life_settings.drive_folders. */
function lifeosE2ESetup() {
  var root = findOrCreateFolder_(DriveApp.getRootFolder(), E2E_ROOT_NAME);
  var ids = {};
  ['inbox', 'emergency', 'backups', 'catch_all'].forEach(function (k) {
    ids[k] = findOrCreateFolder_(root, k).getId();
  });
  return JSON.stringify({ ok: true, folders: ids, user: Session.getEffectiveUser().getEmail() });
}

function findOrCreateFolder_(parent, name) {
  var it = parent.getFoldersByName(name);
  return it.hasNext() ? it.next() : parent.createFolder(name);
}

/** The whole bridge, for real. `nonce` ties this run's mail and rows together. */
function lifeosE2E(nonce) {
  var checks = [];
  function check(name, fn) {
    try {
      var detail = fn();
      checks.push({ name: name, ok: true, detail: detail === undefined ? null : detail });
      return detail;
    } catch (e) {
      checks.push({ name: name, ok: false, detail: String(e && e.stack || e) });
      return null;
    }
  }
  var subject = 'lifeos-e2e ' + nonce;
  var pdfText = '%PDF-1.4\n% Life OS end-to-end test ' + nonce + '\n%%EOF\n';
  var pdf = Utilities.newBlob(pdfText, 'application/pdf', 'E2E_Rechnung_' + nonce + '.pdf');
  var expectedMd5 = Utilities.base64Encode(Utilities.computeDigest(Utilities.DigestAlgorithm.MD5, pdf.getBytes()));

  check('install(): settings, inbox folder, read-only Gmail, one trigger, heartbeat', function () {
    install();
    install();
    var triggers = ScriptApp.getProjectTriggers().filter(function (t) { return t.getHandlerFunction() === 'run'; });
    if (triggers.length !== 1) throw new Error('expected 1 trigger, found ' + triggers.length);
    return 'trigger ' + triggers[0].getUniqueId();
  });

  var messageId = check('a mail with a PDF arrives in Gmail', function () {
    MailApp.sendEmail({ to: Session.getEffectiveUser().getEmail(), subject: subject,
      body: 'Life OS end-to-end test. Safe to delete.', attachments: [pdf] });
    for (var i = 0; i < 30; i++) {
      var threads = GmailApp.search('subject:"' + subject + '" has:attachment', 0, 1);
      if (threads.length) return threads[0].getMessages()[0].getId();
      Utilities.sleep(3000);
    }
    throw new Error('the test mail did not arrive within 90 s');
  });

  check('the intake filing is written through the REST API', function () {
    if (!messageId) throw new Error('no message');
    sb_('POST', '/rest/v1/emails', {
      gmail_message_id: messageId, category: 'bills_payments', subject: subject,
      sender_email: Session.getEffectiveUser().getEmail(), has_attachments: true,
      attachment_names: [pdf.getName()], received_at: new Date().toISOString(),
      last_intake_at: new Date().toISOString(),
    }, 'return=minimal');
    return messageId;
  });

  check('run(): copies the attachment into the Drive inbox, byte for byte', function () {
    PropertiesService.getScriptProperties().deleteProperty('dossier_date');
    PropertiesService.getScriptProperties().deleteProperty('drivecheck_date');
    run();
    var staged = sb_('GET', '/rest/v1/attachment_staging?select=drive_file_id,mime_type&gmail_message_id=eq.' + encodeURIComponent(messageId));
    if (staged.length !== 1) throw new Error('expected 1 staging row, found ' + staged.length);
    var file = DriveApp.getFileById(staged[0].drive_file_id);
    var md5 = Utilities.base64Encode(Utilities.computeDigest(Utilities.DigestAlgorithm.MD5, file.getBlob().getBytes()));
    if (md5 !== expectedMd5) throw new Error('bytes changed: ' + md5 + ' vs ' + expectedMd5);
    if (staged[0].mime_type !== 'application/pdf') throw new Error('mime ' + staged[0].mime_type);
    return file.getName();
  });

  check('a second run copies nothing twice', function () {
    run();
    var staged = sb_('GET', '/rest/v1/attachment_staging?select=id&gmail_message_id=eq.' + encodeURIComponent(messageId));
    if (staged.length !== 1) throw new Error('staging rows: ' + staged.length);
  });

  check('the heartbeat has no errors and the current version', function () {
    var r = sb_('GET', '/rest/v1/bridge_runs?select=script_version,errors,finished_at&order=started_at.desc&limit=1')[0];
    if (r.script_version !== SCRIPT_VERSION) throw new Error('version ' + r.script_version);
    if (!r.finished_at) throw new Error('not finished');
    if (r.errors.length) throw new Error(JSON.stringify(r.errors));
    return r;
  });

  check('the outbox row queued by the runner was delivered to this account', function () {
    var rows = sb_('GET', '/rest/v1/outbox?select=sent_at,attempts,last_error&source=eq.e2e-' + encodeURIComponent(nonce));
    if (rows.length !== 1) throw new Error('outbox rows: ' + rows.length);
    if (!rows[0].sent_at) throw new Error('not sent: ' + rows[0].last_error);
    for (var i = 0; i < 20; i++) {
      if (GmailApp.search('in:sent subject:"[Life OS] e2e outbox ' + nonce + '"', 0, 1).length) return 'in Sent';
      Utilities.sleep(3000);
    }
    throw new Error('the outbox mail is not in Sent');
  });

  check('the emergency binder exists as a Google Doc in the emergency folder', function () {
    var id = PropertiesService.getScriptProperties().getProperty('dossier_doc_id');
    if (!id) throw new Error('no dossier_doc_id');
    var text = DocumentApp.openById(id).getBody().getText();
    if (text.length < 20) throw new Error('binder is empty');
    return text.split('\n')[0];
  });

  check('the bridge cannot write mail: no Gmail send scope', function () {
    try {
      GmailApp.createDraft(Session.getEffectiveUser().getEmail(), 'must fail ' + nonce, 'x');
    } catch (e) {
      return 'refused: ' + String(e.message).slice(0, 80);
    }
    throw new Error('GmailApp.createDraft succeeded: the manifest is not narrowing Gmail');
  });

  check('outgoing requests outside the allowlist are refused', function () {
    try {
      UrlFetchApp.fetch('https://example.com/', { muteHttpExceptions: true });
    } catch (e) {
      return 'refused: ' + String(e.message).slice(0, 80);
    }
    throw new Error('example.com was reachable: urlFetchWhitelist is not enforced');
  });

  check('cleanup: remove the trigger and the test files', function () {
    uninstall();
    // the test mail stays in the test account: the bridge cannot delete mail, by design
    var staged = sb_('GET', '/rest/v1/attachment_staging?select=drive_file_id&gmail_message_id=eq.' + encodeURIComponent(messageId));
    staged.forEach(function (s) { DriveApp.getFileById(s.drive_file_id).setTrashed(true); });
    return ScriptApp.getProjectTriggers().length + ' triggers left';
  });

  var ok = checks.every(function (c) { return c.ok; });
  return JSON.stringify({ ok: ok, nonce: nonce, checks: checks });
}
