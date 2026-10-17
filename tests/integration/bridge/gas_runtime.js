'use strict';
/**
 * An Apps Script runtime for tests: the services Code.gs uses, backed by an in-memory
 * Google account, with UrlFetchApp making real HTTP calls (to the test stack).
 *
 * What it enforces, because these are the ways the bridge fails in Google and not on a
 * laptop:
 *  - OAuth scopes. With `oauthScopes` in the manifest, every service call checks that
 *    one of the scopes Google documents for it was declared, and throws Google's
 *    "You do not have permission to call …" otherwise. Without `oauthScopes` Apps Script
 *    grants what the code uses, and so does this.
 *  - urlFetchWhitelist. A URL outside the allowlist throws, with Google's wildcard rules.
 *  - Synchronous fetch, muteHttpExceptions, the shape of HTTPResponse.
 *  - Google Docs body rules the code works around: a body always keeps one paragraph,
 *    the last paragraph of a section cannot be removed, clear() fails on a trailing
 *    list item.
 *  - "No item with the given ID could be found" for unknown or foreign Drive ids.
 *
 * SCOPES below is our reading of Google's reference pages. The real-Google suite
 * (tests/integration/gas-e2e) is what proves Google agrees.
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

const G = 'https://www.googleapis.com/auth/';
const GMAIL_READ = [G + 'gmail.readonly', G + 'gmail.modify', 'https://mail.google.com/'];
const SCOPES = {
  'GmailApp.getMessageById': GMAIL_READ,
  'GmailApp.search': GMAIL_READ,
  'GmailThread.getMessages': GMAIL_READ,
  'GmailMessage.getAttachments': GMAIL_READ,
  'GmailMessage.getId': GMAIL_READ,
  'GmailMessage.getSubject': GMAIL_READ,
  'GmailMessage.getFrom': GMAIL_READ,
  'GmailMessage.getDate': GMAIL_READ,
  'GmailMessage.getThread': GMAIL_READ,
  'GmailMessage.forward': ['https://mail.google.com/'],
  'GmailMessage.reply': ['https://mail.google.com/'],
  'GmailApp.sendEmail': ['https://mail.google.com/'],
  'GmailApp.createDraft': [G + 'gmail.compose', G + 'gmail.modify', 'https://mail.google.com/'],
  'DriveApp.getRootFolder': [G + 'drive', G + 'drive.readonly'],
  'DriveFolder.getFoldersByName': [G + 'drive', G + 'drive.readonly'],
  'DriveFolder.createFolder': [G + 'drive'],
  'DriveApp.getFolderById': [G + 'drive', G + 'drive.readonly'],
  'DriveApp.getFileById': [G + 'drive', G + 'drive.readonly'],
  'DriveFolder.createFile': [G + 'drive'],
  'DriveFolder.getName': [G + 'drive', G + 'drive.readonly'],
  'DriveFile.setName': [G + 'drive'],
  'DriveFile.setTrashed': [G + 'drive'],
  'DriveFile.isTrashed': [G + 'drive', G + 'drive.readonly'],
  'DriveFile.moveTo': [G + 'drive'],
  'DriveFile.getBlob': [G + 'drive', G + 'drive.readonly'],
  'DriveFile.addEditor': [G + 'drive'],
  'DriveFile.setSharing': [G + 'drive'],
  'DocumentApp.create': [G + 'documents'],
  'DocumentApp.openById': [G + 'documents'],
  'MailApp.sendEmail': [G + 'script.send_mail'],
  'MailApp.getRemainingDailyQuota': [G + 'script.send_mail'],
  'UrlFetchApp.fetch': [G + 'script.external_request'],
  'ScriptApp.getProjectTriggers': [G + 'script.scriptapp'],
  'ScriptApp.newTrigger': [G + 'script.scriptapp'],
  'ScriptApp.deleteTrigger': [G + 'script.scriptapp'],
  'Session.getEffectiveUser.getEmail': [G + 'userinfo.email'],
};

const NOT_FOUND = 'No item with the given ID could be found. Possibly because you have not edited this item or you do not have permission to access it.';

function newId(prefix) { return prefix + crypto.randomBytes(12).toString('hex'); }

/** The Google account the script runs in. */
class World {
  constructor({ user = 'owner@lifeos.test', properties = {}, manifest = null } = {}) {
    this.user = user;
    this.properties = Object.assign({}, properties);
    this.manifest = manifest;
    this.messages = new Map();   // id -> {id, threadId, subject, from, date, labels, attachments:[{name, contentType, bytes}]}
    this.files = new Map();      // id -> {id, name, mimeType, bytes, parents:Set, trashed, owner, doc?}
    this.sent = [];              // MailApp.sendEmail calls
    this.triggers = [];
    this.calls = [];             // every service call, for assertions
    this.faults = [];            // [{when(method, url, body) -> bool, status, body}]
    this.hostMap = {};           // logical url prefix (https://x.supabase.co/rest/v1) -> real base url
    this.gateway = {};           // Supabase API keys -> JWT, as Supabase's API gateway maps them
    this.lockHeld = false;
  }

  addFolder(id, name, owner) {
    this.files.set(id, { id, name: name || id, mimeType: 'application/vnd.google-apps.folder', bytes: Buffer.alloc(0),
      parents: new Set(), trashed: false, owner: owner || this.user });
    return id;
  }

  addMessage(m) {
    const id = m.id || newId('msg');
    this.messages.set(id, Object.assign({ threadId: 'thr-' + id, subject: '', from: 'sender@example.test',
      date: new Date(), labels: ['INBOX'], attachments: [] }, m, { id }));
    return id;
  }

  filesIn(folderId) {
    return [...this.files.values()].filter((f) => f.parents.has(folderId));
  }
}

function makeServices(world) {
  const declared = world.manifest && world.manifest.oauthScopes;
  function need(api) {
    world.calls.push(api);
    if (!declared) return;                                     // Apps Script auto-detects scopes
    const anyOf = SCOPES[api];
    if (!anyOf) throw new Error('gas_runtime: no scope entry for ' + api + ' (add it to SCOPES)');
    if (!anyOf.some((s) => declared.includes(s))) {
      throw new Error('You do not have permission to call ' + api + '. Required permissions: ' + anyOf[0]);
    }
  }

  // ---- Blobs -------------------------------------------------------------------------
  function Blob(bytes, contentType, name) {
    this._bytes = Buffer.from(bytes); this._type = contentType; this._name = name;
  }
  Blob.prototype.getBytes = function () { return [...this._bytes].map((b) => (b > 127 ? b - 256 : b)); };
  Blob.prototype.getContentType = function () { return this._type; };
  Blob.prototype.getName = function () { return this._name; };
  Blob.prototype.setName = function (n) { this._name = n; return this; };
  Blob.prototype.getDataAsString = function () { return this._bytes.toString('utf8'); };
  Blob.prototype.copyBlob = function () { return new Blob(this._bytes, this._type, this._name); };

  // ---- Gmail -------------------------------------------------------------------------
  function Attachment(a) { this._a = a; }
  Attachment.prototype.getName = function () { return this._a.name; };
  Attachment.prototype.getContentType = function () { return this._a.contentType; };
  Attachment.prototype.getSize = function () { return this._a.size != null ? this._a.size : this._a.bytes.length; };
  Attachment.prototype.copyBlob = function () { return new Blob(this._a.bytes, this._a.contentType, this._a.name); };
  Attachment.prototype.getBytes = function () { return this.copyBlob().getBytes(); };

  function Message(m) { this._m = m; }
  Message.prototype.getId = function () { need('GmailMessage.getId'); return this._m.id; };
  Message.prototype.getSubject = function () { need('GmailMessage.getSubject'); return this._m.subject; };
  Message.prototype.getFrom = function () { need('GmailMessage.getFrom'); return this._m.from; };
  Message.prototype.getDate = function () { need('GmailMessage.getDate'); return this._m.date; };
  Message.prototype.getAttachments = function (opts) {
    need('GmailMessage.getAttachments');
    return this._m.attachments.filter((a) => !(a.inline && !(opts && opts.includeInlineImages)))
      .map((a) => new Attachment(a));
  };
  Message.prototype.forward = function () { need('GmailMessage.forward'); throw new Error('test: forward must never be called'); };
  Message.prototype.reply = function () { need('GmailMessage.reply'); throw new Error('test: reply must never be called'); };

  function Thread(msgs) { this._msgs = msgs; }
  Thread.prototype.getMessages = function () { need('GmailThread.getMessages'); return this._msgs.map((m) => new Message(m)); };

  const GmailApp = {
    getMessageById(id) {
      need('GmailApp.getMessageById');
      const m = world.messages.get(id);
      if (!m) throw new Error('Invalid argument: id');
      return new Message(m);
    },
    search(query, start, max) {
      need('GmailApp.search');
      let msgs = [...world.messages.values()];
      if (/has:attachment/.test(query)) msgs = msgs.filter((m) => m.attachments.length);
      if (/in:sent/.test(query)) msgs = msgs.filter((m) => m.labels.includes('SENT'));
      const subj = /subject:"([^"]+)"/.exec(query);
      if (subj) msgs = msgs.filter((m) => m.subject.includes(subj[1]));
      const threads = new Map();
      msgs.forEach((m) => { if (!threads.has(m.threadId)) threads.set(m.threadId, []); threads.get(m.threadId).push(m); });
      return [...threads.values()].slice(start || 0, (start || 0) + (max || 500)).map((t) => new Thread(t));
    },
    sendEmail() { need('GmailApp.sendEmail'); throw new Error('test: GmailApp.sendEmail must never be called'); },
    createDraft() { need('GmailApp.createDraft'); throw new Error('test: GmailApp.createDraft must never be called'); },
  };

  // ---- Drive -------------------------------------------------------------------------
  function getEntry(id, wantFolder) {
    const f = world.files.get(id);
    if (!f || f.owner !== world.user && !f.sharedWithUser) throw new Error(NOT_FOUND);
    if (wantFolder !== undefined && (f.mimeType === 'application/vnd.google-apps.folder') !== wantFolder) throw new Error(NOT_FOUND);
    return f;
  }
  function File(f) { this._f = f; }
  File.prototype.getId = function () { return this._f.id; };
  File.prototype.getName = function () { return this._f.name; };
  File.prototype.getUrl = function () { return 'https://drive.google.com/file/d/' + this._f.id + '/view'; };
  File.prototype.getMimeType = function () { return this._f.mimeType; };
  File.prototype.getSize = function () { return this._f.bytes.length; };
  File.prototype.setName = function (n) { need('DriveFile.setName'); this._f.name = n; return this; };
  File.prototype.setTrashed = function (t) { need('DriveFile.setTrashed'); this._f.trashed = !!t; return this; };
  File.prototype.isTrashed = function () { need('DriveFile.isTrashed'); return this._f.trashed; };
  File.prototype.getBlob = function () { need('DriveFile.getBlob'); return new Blob(this._f.bytes, this._f.mimeType, this._f.name); };
  File.prototype.moveTo = function (folder) {
    need('DriveFile.moveTo'); getEntry(folder.getId(), true);
    this._f.parents = new Set([folder.getId()]); return this;
  };
  File.prototype.addEditor = function () { need('DriveFile.addEditor'); throw new Error('test: sharing must never happen'); };
  File.prototype.setSharing = function () { need('DriveFile.setSharing'); throw new Error('test: sharing must never happen'); };

  function Folder(f) { File.call(this, f); }
  Folder.prototype = Object.create(File.prototype);
  Folder.prototype.getName = function () { need('DriveFolder.getName'); return this._f.name; };
  Folder.prototype.getFoldersByName = function (name) {
    need('DriveFolder.getFoldersByName');
    const found = [...world.files.values()].filter((f) => f.parents.has(this._f.id) && f.name === name
      && f.mimeType === 'application/vnd.google-apps.folder' && !f.trashed);
    let i = 0;
    return { hasNext: () => i < found.length, next: () => new Folder(found[i++]) };
  };
  Folder.prototype.createFolder = function (name) {
    need('DriveFolder.createFolder');
    const id = world.addFolder(newId('fld'), name);
    world.files.get(id).parents.add(this._f.id);
    return new Folder(world.files.get(id));
  };
  Folder.prototype.createFile = function (blob) {
    need('DriveFolder.createFile');
    if (this._f.trashed) throw new Error('test: creating a file in a trashed folder');
    const id = newId('file');
    world.files.set(id, { id, name: blob.getName(), mimeType: blob.getContentType(), bytes: Buffer.from(blob._bytes),
      parents: new Set([this._f.id]), trashed: false, owner: world.user });
    return new File(world.files.get(id));
  };

  const DriveApp = {
    getRootFolder() {
      need('DriveApp.getRootFolder');
      if (!world.files.has('root')) world.addFolder('root', 'My Drive');
      return new Folder(world.files.get('root'));
    },
    getFolderById(id) { need('DriveApp.getFolderById'); return new Folder(getEntry(id, true)); },
    getFileById(id) { need('DriveApp.getFileById'); return new File(getEntry(id)); },
  };

  // ---- Docs --------------------------------------------------------------------------
  const ParagraphHeading = { NORMAL: 'NORMAL', HEADING1: 'HEADING1', HEADING2: 'HEADING2' };
  const GlyphType = { BULLET: 'BULLET', NUMBER: 'NUMBER' };
  function Element(body, node) { this._body = body; this._n = node; }
  Element.prototype.setHeading = function (h) { this._n.heading = h; return this; };
  Element.prototype.setGlyphType = function (g) { this._n.glyph = g; return this; };
  Element.prototype.asText = function () { const n = this._n; return { getText: () => n.text }; };
  Element.prototype.getType = function () { return this._n.type; };
  Element.prototype.removeFromParent = function () {
    const kids = this._body._kids;
    const i = kids.indexOf(this._n);
    if (i === kids.length - 1 && this._n.type === 'PARAGRAPH') {
      throw new Error("Can't remove the last paragraph in a document section.");
    }
    kids.splice(i, 1);
    return this;
  };
  function Body(doc) { this._doc = doc; this._kids = doc.kids; }
  Body.prototype.appendParagraph = function (t) {
    const n = { type: 'PARAGRAPH', text: String(t), heading: 'NORMAL' }; this._kids.push(n); return new Element(this, n);
  };
  Body.prototype.appendListItem = function (t) {
    const n = { type: 'LIST_ITEM', text: String(t), glyph: 'BULLET' }; this._kids.push(n); return new Element(this, n);
  };
  Body.prototype.clear = function () {
    if (this._kids.length && this._kids[this._kids.length - 1].type === 'LIST_ITEM') {
      throw new Error("Can't remove the last paragraph in a document section.");
    }
    this._kids.splice(0, this._kids.length, { type: 'PARAGRAPH', text: '', heading: 'NORMAL' });
    return this;
  };
  Body.prototype.getNumChildren = function () { return this._kids.length; };
  Body.prototype.getChild = function (i) { return new Element(this, this._kids[i]); };
  Body.prototype.getText = function () { return this._kids.map((k) => k.text).join('\n'); };
  function Doc(entry) { this._e = entry; }
  Doc.prototype.getId = function () { return this._e.id; };
  Doc.prototype.getBody = function () { return new Body(this._e.doc); };
  Doc.prototype.saveAndClose = function () { this._e.doc.saves = (this._e.doc.saves || 0) + 1; };
  const DocumentApp = {
    ParagraphHeading, GlyphType,
    create(name) {
      need('DocumentApp.create');
      const id = newId('doc');
      world.files.set(id, { id, name, mimeType: 'application/vnd.google-apps.document', bytes: Buffer.alloc(0),
        parents: new Set(['root']), trashed: false, owner: world.user,
        doc: { kids: [{ type: 'PARAGRAPH', text: '', heading: 'NORMAL' }], saves: 0 } });
      return new Doc(world.files.get(id));
    },
    openById(id) {
      need('DocumentApp.openById');
      const e = getEntry(id);
      if (!e.doc) throw new Error('Document is missing (perhaps it was deleted, or you don\'t have read access?)');
      return new Doc(e);
    },
  };

  // ---- Mail, session, properties, locks, triggers ------------------------------------
  const MailApp = {
    sendEmail(arg) {
      need('MailApp.sendEmail');
      const m = typeof arg === 'object' ? arg : { to: arguments[0], subject: arguments[1], body: arguments[2] };
      if (!m.to || !m.subject) throw new Error('Invalid argument: recipient or subject');
      world.sent.push({ to: m.to, subject: m.subject, body: m.body, attachments: m.attachments || [] });
      if (world.user === m.to) {
        world.addMessage({ subject: m.subject, from: world.user, labels: ['INBOX', 'SENT'],
          attachments: (m.attachments || []).map((b) => ({ name: b.getName(), contentType: b.getContentType(), bytes: b._bytes })) });
      }
    },
    getRemainingDailyQuota() { need('MailApp.getRemainingDailyQuota'); return 100 - world.sent.length; },
  };
  const Session = {
    getEffectiveUser() { return { getEmail() { need('Session.getEffectiveUser.getEmail'); return world.user; } }; },
    getScriptTimeZone() { return (world.manifest && world.manifest.timeZone) || 'Etc/UTC'; },
  };
  const PropertiesService = {
    getScriptProperties() {
      return {
        getProperty: (k) => (Object.prototype.hasOwnProperty.call(world.properties, k) ? world.properties[k] : null),
        setProperty: (k, v) => { world.properties[k] = String(v); },
        deleteProperty: (k) => { delete world.properties[k]; },
        getProperties: () => Object.assign({}, world.properties),
      };
    },
  };
  const LockService = {
    getScriptLock() {
      let mine = false;
      return {
        tryLock() { if (world.lockHeld) return false; world.lockHeld = true; mine = true; return true; },
        releaseLock() { if (mine) { world.lockHeld = false; mine = false; } },
      };
    },
  };
  const ScriptApp = {
    getProjectTriggers() { need('ScriptApp.getProjectTriggers'); return world.triggers.slice(); },
    deleteTrigger(t) { need('ScriptApp.deleteTrigger'); world.triggers = world.triggers.filter((x) => x !== t); },
    newTrigger(fn) {
      need('ScriptApp.newTrigger');
      const t = { fn, getHandlerFunction: () => fn, getUniqueId: () => 'trg-' + fn };
      return { timeBased: () => ({ everyMinutes: (n) => ({ create: () => { t.every = n; world.triggers.push(t); return t; } }) }) };
    },
  };

  // ---- Utilities ---------------------------------------------------------------------
  const Utilities = {
    DigestAlgorithm: { MD5: 'md5', SHA_256: 'sha256' },
    Charset: { UTF_8: 'utf8' },
    computeDigest(alg, value, charset) {
      const buf = Array.isArray(value) ? Buffer.from(value.map((b) => b & 255)) : Buffer.from(String(value), charset || 'utf8');
      return [...crypto.createHash(alg).update(buf).digest()].map((b) => (b > 127 ? b - 256 : b));
    },
    base64Encode(v) {
      return (Array.isArray(v) ? Buffer.from(v.map((b) => b & 255)) : Buffer.from(String(v), 'utf8')).toString('base64');
    },
    formatDate(date, tz, pattern) {
      if (pattern !== 'yyyy-MM-dd') throw new Error('gas_runtime: formatDate pattern not emulated: ' + pattern);
      return new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit' }).format(date);
    },
    newBlob(data, contentType, name) { return new Blob(typeof data === 'string' ? Buffer.from(data) : Buffer.from(data.map((b) => b & 255)), contentType, name); },
    sleep(ms) { const end = Date.now() + Math.min(ms, 50); while (Date.now() < end) { /* bounded */ } },
  };
  const Logger = { log(...a) { world.log = world.log || []; world.log.push(a.join(' ')); } };

  // ---- UrlFetchApp: real HTTP, synchronous, with the manifest allowlist ---------------
  function allowed(url) {
    const list = world.manifest && world.manifest.urlFetchWhitelist;
    if (!list) return true;
    return list.some((prefix) => {
      const m = /^https:\/\/\*\.(.+)$/.exec(prefix);
      if (m) {
        const rest = m[1];
        const slash = rest.indexOf('/');
        const host = rest.slice(0, slash), pathPrefix = rest.slice(slash);
        const u = /^https:\/\/([^/]+)(\/.*)?$/.exec(url);
        return !!u && u[1].endsWith('.' + host) && (u[2] || '/').startsWith(pathPrefix);
      }
      return url.startsWith(prefix);
    });
  }
  const UrlFetchApp = {
    fetch(url, opts) {
      need('UrlFetchApp.fetch');
      opts = opts || {};
      if (!allowed(url)) throw new Error('Exception: URL not allowed by urlFetchWhitelist: ' + url);
      const method = (opts.method || 'get').toUpperCase();
      const payload = opts.payload == null ? undefined : String(opts.payload);
      world.calls.push('HTTP ' + method + ' ' + url.replace(/^https:\/\/[^/]+/, ''));
      const fault = world.faults.find((f) => f.when(method, url, payload));
      let status, text;
      if (fault) {
        status = fault.status; text = fault.body || '';
      } else {
        let real = url;
        for (const [prefix, base] of Object.entries(world.hostMap)) real = real.replace(prefix, base);
        const headers = Object.assign({}, opts.headers || {});
        // Supabase's gateway: an sb_secret_/sb_publishable_ apikey becomes the role's JWT;
        // an unknown key is refused before it reaches the database.
        if (headers.apikey && /^sb_(secret|publishable)_/.test(headers.apikey) && !headers.Authorization) {
          const jwt = world.gateway[headers.apikey];
          if (!jwt) return { getResponseCode: () => 401, getContentText: () => '{"message":"Invalid API key"}', getHeaders: () => ({}) };
          headers.Authorization = 'Bearer ' + jwt;
        }
        const args = ['-sS', '--noproxy', '*', '-X', method, '-o', '-', '-w', '\n%{http_code}'];
        for (const [k, v] of Object.entries(headers)) args.push('-H', k + ': ' + v);
        if (opts.contentType) args.push('-H', 'Content-Type: ' + opts.contentType);
        if (payload !== undefined) args.push('--data-binary', '@-');
        args.push(real);
        const r = spawnSync('curl', args, { input: payload, encoding: 'utf8', timeout: 30000 });
        if (r.status !== 0) throw new Error('Exception: Address unavailable: ' + url + ' (' + r.stderr.trim() + ')');
        const cut = r.stdout.lastIndexOf('\n');
        text = r.stdout.slice(0, cut); status = Number(r.stdout.slice(cut + 1));
      }
      if (status >= 400 && !opts.muteHttpExceptions) {
        throw new Error('Exception: Request failed for ' + url + ' returned code ' + status + '. Truncated server response: ' + text.slice(0, 100));
      }
      return { getResponseCode: () => status, getContentText: () => text, getHeaders: () => ({}) };
    },
  };

  return { GmailApp, DriveApp, DocumentApp, MailApp, Session, PropertiesService, LockService, ScriptApp,
    Utilities, Logger, UrlFetchApp };
}

/** Loads .gs files into one global scope, as Apps Script does, and returns that scope. */
function loadProject(world, files) {
  const ctx = vm.createContext(Object.assign(makeServices(world), { console }));
  for (const f of files) vm.runInContext(fs.readFileSync(f, 'utf8'), ctx, { filename: path.basename(f) });
  return ctx;
}

module.exports = { World, loadProject, SCOPES, NOT_FOUND };
