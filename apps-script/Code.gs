/**
 * claude-life-os: the Google side of the system.  bridge-3.0
 *
 * Runs inside your own Google account every 15 minutes, with or without Claude:
 *   1. Copies email attachments that matter (bills, contracts, letters from authorities)
 *      from Gmail into Drive/Inbox, so the document intake can index them.
 *   2. Re-copies any of those files that vanished from Drive before they were indexed.
 *   3. Emails you when one of the Claude jobs has not run for too long.
 *   4. Once a day, rewrites the "Emergency binder" Google Doc from the index.
 *
 * It moves files as native Google objects. No file ever passes through an AI model,
 * so nothing can get corrupted on the way.
 *
 * SETUP (the setup skill walks you through this, about 5 minutes):
 *   1. script.google.com  >  New project  >  paste this whole file over Code.gs
 *   2. Project Settings (gear icon)  >  Script Properties  >  add two properties:
 *        SUPABASE_URL          https://<your-project>.supabase.co
 *        SUPABASE_SECRET_KEY   sb_secret_...   (Supabase > Project Settings > API Keys)
 *   3. Choose the function `install` in the toolbar and press Run. Google asks for
 *      permission: Review permissions > your account > "Google hasn't verified this app"
 *      > Advanced > Go to Life OS bridge (unsafe) > tick "Select all" if checkboxes are
 *      shown > Allow. It is your own script in your own account; docs/apps-script.md
 *      explains every permission.
 *   4. Done. `install` checks the connection, creates the 15-minute trigger and writes a
 *      first heartbeat, which is how the setup skill knows this part works.
 *
 * Never paste the secret key into the code itself. Script Properties are not shown to
 * anyone you share the project with, the code is.
 *
 * Everything else (which folder is the Inbox, time zone, which mail categories to copy)
 * is read from the `life_settings` table in Supabase, so there is nothing to edit here.
 */

const SCRIPT_VERSION = 'bridge-3.0';
const QUEUE_BATCH = 20;                        // messages per run, the next run takes the rest
const HEAL_BATCH = 50;                         // staged files re-verified per run
const WATCHDOG_MAIL_EVERY_HOURS = 12;          // at most one alert per job per 12 hours
const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;

const ALLOWED_MIME_TYPES = [
  'application/pdf',
  'image/jpeg',
  'image/png',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
];

// Some senders (telecoms, utilities) declare PDFs as application/octet-stream.
// Trust the file extension when the declared type is generic.
const EXTENSION_MIME = {
  pdf: 'application/pdf', jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
};

// ------------------------------------------------------------------------------------
// One-time setup
// ------------------------------------------------------------------------------------

/** Run this once by hand. Safe to run again: it never creates a second trigger. */
function install() {
  const settings = loadSettings_();                       // proves URL + key work
  const inbox = settings.drive_folders && settings.drive_folders.inbox;
  if (!inbox) throw new Error('life_settings.drive_folders.inbox is empty. Run the setup skill in Claude first.');
  DriveApp.getFolderById(inbox);                          // proves Drive access and the id

  ScriptApp.getProjectTriggers()
    .filter(function (t) { return t.getHandlerFunction() === 'run'; })
    .forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('run').timeBased().everyMinutes(15).create();

  run();                                                  // first heartbeat
  Logger.log('Installed. The bridge now runs every 15 minutes. Go back to Claude and say "done".');
}

/** Removes the trigger. The data in Supabase and Drive stays untouched. */
function uninstall() {
  ScriptApp.getProjectTriggers()
    .filter(function (t) { return t.getHandlerFunction() === 'run'; })
    .forEach(function (t) { ScriptApp.deleteTrigger(t); });
  Logger.log('Trigger removed.');
}

// ------------------------------------------------------------------------------------
// The 15-minute run
// ------------------------------------------------------------------------------------

function run() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) return;                        // previous run still going

  const stats = { queued: 0, copied: 0, healed: 0, verified: 0, errors: [] };
  let runId = null;
  try {
    runId = sb_('POST', '/rest/v1/bridge_runs', { script_version: SCRIPT_VERSION }, 'return=representation')[0].id;
    const settings = loadSettings_();
    const folder = DriveApp.getFolderById(settings.drive_folders.inbox);

    // 1. Queue: mail the email intake put into an in-scope category that was never copied.
    const queue = sb_('GET', '/rest/v1/v_bridge_queue?select=gmail_message_id&limit=' + QUEUE_BATCH);
    stats.queued = queue.length;
    queue.forEach(function (row) {
      try { bridgeMessage_(row.gmail_message_id, folder, stats); }
      catch (e) { stats.errors.push(row.gmail_message_id + ': ' + e.message); }
    });

    // 2. Heal: every staged-but-unindexed file must still exist in Drive.
    const heal = sb_('GET', '/rest/v1/v_bridge_heal?select=id,gmail_message_id,filename,drive_file_id&limit=' + HEAL_BATCH);
    heal.forEach(function (row) {
      try { healRow_(row, folder, stats); }
      catch (e) { stats.errors.push('heal ' + row.gmail_message_id + '/' + row.filename + ': ' + e.message); }
    });

    // 3. External watchdog for the Claude jobs.
    try { watchdog_(); } catch (e) { stats.errors.push('watchdog: ' + e.message); }

    // 4. Once a day: the emergency binder.
    try { dailyDossier_(settings); } catch (e) { stats.errors.push('dossier: ' + e.message); }
  } catch (e) {
    stats.errors.push('fatal: ' + e.message);
  } finally {
    if (runId) {
      try {
        sb_('PATCH', '/rest/v1/bridge_runs?id=eq.' + runId, {
          finished_at: new Date().toISOString(),
          queued: stats.queued, copied: stats.copied, healed: stats.healed,
          verified: stats.verified, errors: stats.errors,
        });
      } catch (e) { stats.errors.push('heartbeat: ' + e.message); }
    }
    Logger.log(JSON.stringify(stats));
    if (stats.errors.length > 0) {
      notify_('attachment-bridge: ' + stats.errors.length + ' error(s)', stats.errors.join('\n'));
    }
    lock.releaseLock();
  }
}

/** Kept for installations that still have a trigger pointing at the old entry point. */
function moveAttachments() { run(); }

// ------------------------------------------------------------------------------------
// Copying
// ------------------------------------------------------------------------------------

function bridgeMessage_(gmailMessageId, folder, stats) {
  let message = null;
  try { message = GmailApp.getMessageById(gmailMessageId); } catch (e) { message = null; }
  if (!message) {
    recordMessage_(gmailMessageId, 0, [{ reason: 'message_not_found' }]);
    return;
  }

  let copied = 0;
  const skipped = [];
  message.getAttachments({ includeInlineImages: false }).forEach(function (attachment) {
    const filename = attachment.getName();
    const mimeType = effectiveMime_(attachment);
    const size = attachment.getSize();
    if (ALLOWED_MIME_TYPES.indexOf(mimeType) === -1) { skipped.push({ filename: filename, reason: 'mime ' + mimeType }); return; }
    if (size > MAX_ATTACHMENT_BYTES) { skipped.push({ filename: filename, reason: 'size ' + size }); return; }

    // Fails CLOSED: if the lookup errors, nothing is copied. A failed-open check is what
    // produced five copies of every attachment in bridge-1.x.
    const existing = alreadyStaged_(gmailMessageId, filename);
    if (existing && !existing.resolved_at && fileAlive_(existing.drive_file_id)) return;
    copyAndStage_(gmailMessageId, attachment, folder, existing);
    copied++;
  });
  stats.copied += copied;
  recordMessage_(gmailMessageId, copied, skipped);
}

function healRow_(row, folder, stats) {
  if (fileAlive_(row.drive_file_id)) {
    sb_('PATCH', '/rest/v1/attachment_staging?id=eq.' + row.id, { last_verified_at: new Date().toISOString() });
    stats.verified++;
    return;
  }
  let message = null;
  try { message = GmailApp.getMessageById(row.gmail_message_id); } catch (e) { message = null; }
  const attachment = message
    ? message.getAttachments({ includeInlineImages: false })
        .filter(function (a) { return a.getName() === row.filename; })[0]
    : null;
  if (!attachment) {
    sb_('PATCH', '/rest/v1/attachment_staging?id=eq.' + row.id, {
      resolved_at: new Date().toISOString(), resolution: 'drive_file_missing',
      last_verified_at: new Date().toISOString(),
    });
    throw new Error('Drive copy gone and Gmail original not found, marked drive_file_missing');
  }
  copyAndStage_(row.gmail_message_id, attachment, folder, alreadyStaged_(row.gmail_message_id, row.filename));
  stats.healed++;
}

function copyAndStage_(gmailMessageId, attachment, folder, existing) {
  const file = folder.createFile(attachment.copyBlob());
  file.setName(gmailMessageId + '_' + attachment.getName());
  const now = new Date().toISOString();
  const payload = {
    drive_file_id: file.getId(),
    drive_url: file.getUrl(),
    mime_type: effectiveMime_(attachment),
    size_bytes: attachment.getSize(),
    saved_at: now, last_verified_at: now,
    claimed: false, claimed_at: null, resolved_at: null, resolution: null,
  };
  try {
    if (existing) {
      payload.heal_count = (existing.heal_count || 0) + 1;
      sb_('PATCH', '/rest/v1/attachment_staging?id=eq.' + existing.id, payload);
    } else {
      payload.gmail_message_id = gmailMessageId;
      payload.filename = attachment.getName();
      sb_('POST', '/rest/v1/attachment_staging', payload, 'return=minimal');
    }
  } catch (e) {
    file.setTrashed(true);            // never leave a Drive copy the database does not know about
    throw e;
  }
}

function alreadyStaged_(gmailMessageId, filename) {
  const rows = sb_('GET', '/rest/v1/attachment_staging'
    + '?gmail_message_id=eq.' + encodeURIComponent(gmailMessageId)
    + '&filename=eq.' + encodeURIComponent(filename)
    + '&select=id,drive_file_id,resolved_at,heal_count');
  return rows.length ? rows[0] : null;
}

function recordMessage_(gmailMessageId, copied, skipped) {
  sb_('POST', '/rest/v1/bridge_messages?on_conflict=gmail_message_id', {
    gmail_message_id: gmailMessageId,
    processed_at: new Date().toISOString(),
    copied: copied,
    skipped: skipped,
  }, 'resolution=merge-duplicates,return=minimal');
}

function effectiveMime_(attachment) {
  const declared = (attachment.getContentType() || '').toLowerCase();
  if (ALLOWED_MIME_TYPES.indexOf(declared) !== -1) return declared;
  if (declared === 'application/octet-stream' || declared === 'binary/octet-stream' || declared === '') {
    const ext = (attachment.getName().split('.').pop() || '').toLowerCase();
    if (EXTENSION_MIME[ext]) return EXTENSION_MIME[ext];
  }
  return declared;
}

function fileAlive_(driveFileId) {
  if (!driveFileId) return false;
  try { return !DriveApp.getFileById(driveFileId).isTrashed(); } catch (e) { return false; }
}

// ------------------------------------------------------------------------------------
// Watchdog: the Claude jobs cannot start themselves, so something outside them must notice.
// ------------------------------------------------------------------------------------

function watchdog_() {
  const rows = sb_('GET', '/rest/v1/v_intake_watchdog?select=skill,hours_since,sla_hours,overdue&overdue=is.true');
  const props = PropertiesService.getScriptProperties();
  rows.forEach(function (r) {
    if (r.skill === 'attachment-bridge') return;
    const key = 'watchdog_mail_' + r.skill;
    if (Date.now() - Number(props.getProperty(key) || 0) < WATCHDOG_MAIL_EVERY_HOURS * 3600000) return;
    notify_(r.skill + ' has not run for ' + r.hours_since + 'h (SLA ' + r.sla_hours + 'h)',
      'The scheduled Claude task for ' + r.skill + ' did not fire.\n'
      + 'Open Claude, check the scheduled task, or just say "run ' + r.skill + '".');
    props.setProperty(key, String(Date.now()));
  });
}

// ------------------------------------------------------------------------------------
// Emergency binder: text is built in Supabase (emergency_dossier()), written here.
// ------------------------------------------------------------------------------------

function dailyDossier_(settings) {
  const folderId = settings.drive_folders && settings.drive_folders.emergency;
  if (!folderId) return;                                  // feature not set up, nothing to do
  const tz = settings.timezone || 'UTC';
  const props = PropertiesService.getScriptProperties();
  const today = Utilities.formatDate(new Date(), tz, 'yyyy-MM-dd');
  if (props.getProperty('dossier_date') === today) return;

  const text = sb_('POST', '/rest/v1/rpc/emergency_dossier', {});
  let doc = null;
  const docId = props.getProperty('dossier_doc_id');
  if (docId) { try { doc = DocumentApp.openById(docId); } catch (e) { doc = null; } }
  if (!doc) {
    doc = DocumentApp.create('Emergency binder');
    DriveApp.getFileById(doc.getId()).moveTo(DriveApp.getFolderById(folderId));
    props.setProperty('dossier_doc_id', doc.getId());
  }

  const body = doc.getBody();
  // Google Docs refuses to remove the last paragraph of a section, and body.clear() throws
  // when the body ends in a list item. End on a plain paragraph first, then clear.
  body.appendParagraph('');
  body.clear();
  String(text).split('\n').forEach(function (line) {
    if (line.indexOf('# ') === 0) body.appendParagraph(line.slice(2)).setHeading(DocumentApp.ParagraphHeading.HEADING1);
    else if (line.indexOf('## ') === 0) body.appendParagraph(line.slice(3)).setHeading(DocumentApp.ParagraphHeading.HEADING2);
    else if (line.indexOf('- ') === 0) body.appendListItem(line.slice(2)).setGlyphType(DocumentApp.GlyphType.BULLET);
    else body.appendParagraph(line);
  });
  body.appendParagraph('');                                 // always end on a paragraph
  if (body.getNumChildren() > 1 && body.getChild(0).asText().getText() === '') {
    body.getChild(0).removeFromParent();
  }
  doc.saveAndClose();
  props.setProperty('dossier_date', today);
}

// ------------------------------------------------------------------------------------
// Plumbing
// ------------------------------------------------------------------------------------

function loadSettings_() {
  const rows = sb_('GET', '/rest/v1/life_settings?select=key,value&key=in.(drive_folders,timezone,owner_email)');
  const s = {};
  rows.forEach(function (r) { s[r.key] = r.value; });
  return s;
}

function notify_(subject, body) {
  MailApp.sendEmail({ to: Session.getEffectiveUser().getEmail(), subject: '\u26A0\uFE0F ' + subject, body: body });
}

function config_() {
  const props = PropertiesService.getScriptProperties();
  const url = (props.getProperty('SUPABASE_URL') || '').replace(/\/+$/, '');
  const key = props.getProperty('SUPABASE_SECRET_KEY') || '';
  if (!url) throw new Error('Script Property SUPABASE_URL is missing (Project Settings > Script Properties)');
  if (!key) throw new Error('Script Property SUPABASE_SECRET_KEY is missing (Project Settings > Script Properties)');
  if (key.indexOf('sb_publishable_') === 0) throw new Error('That is the publishable key. The bridge needs the SECRET key (sb_secret_...).');
  return { url: url, key: key };
}

function sb_(method, path, body, prefer) {
  const cfg = config_();
  const headers = { apikey: cfg.key };
  if (cfg.key.indexOf('eyJ') === 0) headers.Authorization = 'Bearer ' + cfg.key;   // legacy JWT service_role key
  if (prefer) headers.Prefer = prefer;
  const options = { method: method.toLowerCase(), headers: headers, muteHttpExceptions: true };
  if (body !== undefined) { options.contentType = 'application/json'; options.payload = JSON.stringify(body); }
  const response = UrlFetchApp.fetch(cfg.url + path, options);
  const code = response.getResponseCode();
  const text = response.getContentText();
  if (code >= 300) throw new Error(method + ' ' + path.split('?')[0] + ' -> ' + code + ' ' + text.slice(0, 200));
  return text ? JSON.parse(text) : null;
}
