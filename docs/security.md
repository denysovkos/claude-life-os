# Security

The database holds the most sensitive data a person has: identity papers, contracts,
bank transactions, health appointments, addresses. The design assumes that any key which
can be leaked eventually will be, and limits what each key can do.

## Who can reach the data

| Actor | Connects as | Can do | Where the credential lives |
|---|---|---|---|
| Claude skills | `postgres` through the Supabase MCP connector | everything (bypasses RLS) | the person's Claude connector authorisation; never in a file |
| Apps Script bridge | `service_role` via the **secret** API key (`sb_secret_…`) | everything through the REST API (bypasses RLS) | Apps Script **Script Properties** of the person's own project |
| Public API with the publishable key (`sb_publishable_…`) | `anon` | nothing | not used anywhere |
| Signed-in app users | `authenticated` | nothing | there are none |

There is no web app, no public endpoint, no other user.

## Deny-all by design

Migration 0004:

- enables row level security on every table and creates **no policies**,
- revokes all table, sequence and function privileges from `anon` and `authenticated`,
- revokes default privileges, so tables and functions added later are closed too,
- grants `service_role` what the bridge needs.

Supabase's advisor reports `rls_enabled_no_policy` for every table. That is the intended
state, not a finding to fix: a policy would be the only way to open a table to the
public API. Views are `security_invoker`, so they cannot become a side door past RLS
either. CI checks on every push that no public table has RLS off and that `anon` and
`authenticated` hold no grants; the setup workflow in doctor mode checks the same on the
live project, plus that `anon` cannot execute any function.

## Secrets

- The **secret key** exists in exactly one place: the Script Properties of the person's
  Apps Script project. Script Properties are not shown to people the project is shared
  with; code is. `Code.gs` refuses to start if the publishable key is put there by
  mistake.
- The setup skill never asks for the secret key in chat and tells the person to rotate it
  if they paste it anyway. Chat history is stored and may be read later by anyone with
  access to the account.
- An earlier private version had the secret key hard-coded in `Code.gs`. Anyone who saw
  the script saw the key. Moving it to Script Properties was the first change in the
  product version. A key that was ever in code counts as leaked: rotate it.
- No credential, folder id, project id, IBAN or name is committed to this repository.
  All of them are rows in `life_settings` of the person's own database.

### Rotating the secret key

1. Supabase → Project Settings → API Keys → Secret keys → create a new one.
2. Apps Script → Project Settings → Script Properties → replace `SUPABASE_SECRET_KEY`.
3. Run `install` once (it checks the connection and writes a heartbeat).
4. Delete the old key in Supabase.

## What passes through the model

- Mail bodies and document texts are read by Claude to classify them and extract facts.
  That is the product. What is stored is the extracted fields, a ~500-character excerpt,
  and the full text of documents (for search and deduplication), all in the person's
  own Supabase project.
- **Files never pass through the model.** Attachments are copied by Apps Script as
  native Google objects. The one exception, a document the person attaches in chat, is
  uploaded and then downloaded again and compared by SHA-256; a mismatch is deleted and
  reported, never retried.
- Skills write through parameterised SQL built in the connector. Text from mail or
  documents is data: skills do not follow instructions found inside a letter, and a
  classification rule can only set categories, types, tags and links, never run code.

## Autonomy limits

The system changes itself only within limits:

- `improvement_proposals.autonomy = 'auto'` covers fixes to its own data (a wrong
  category, a missing link). Schema changes, new document types, new categories, data
  deletion and anything that widens what the system may do are `ask`: a human decides.
- Skills never delete rows from `documents`, `emails` or `deadlines`. Duplicates are
  linked, stale items change status, deadlines are cancelled, not removed.
  `attachment_staging` rows backing a document cannot be deleted (trigger).
- Skills never contact a vendor, cancel a contract or send mail on the person's behalf.
  The only outgoing mail is the brief, the review and alerts, to the owner's own address.
- Every writing run starts with `take_snapshot()`, a full server-side JSON copy of the
  extraction tables, so a bad run is reversible without the model re-reading anything.

## Backups and loss

| Tier | Protects against | Frequency |
|---|---|---|
| `backup_snapshots` (in the database) | a bad run, a bad autonomous edit, a bad migration | every writing run |
| CSV export to Drive (`backups` table logs it) | losing the Supabase project | monthly |
| Gmail and Drive themselves | losing the index | always; everything can be re-indexed |

Free Supabase projects have no point-in-time recovery and pause after a week of
inactivity (the bridge's 15-minute heartbeat keeps it active). An export older than 35
days shows up in the health check.

## Reporting a vulnerability

Open a private security advisory on the repository rather than a public issue.
