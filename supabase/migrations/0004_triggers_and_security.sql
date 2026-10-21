-- Triggers, row level security and grants.
-- Exported from the reference deployment. Do not edit by hand; add a new migration instead.

drop trigger if exists attachment_staging_guard_delete on public.attachment_staging;
CREATE TRIGGER attachment_staging_guard_delete BEFORE DELETE ON public.attachment_staging FOR EACH ROW EXECUTE FUNCTION guard_staging_delete();
drop trigger if exists bundles_set_updated_at on public.bundles;
CREATE TRIGGER bundles_set_updated_at BEFORE UPDATE ON public.bundles FOR EACH ROW EXECUTE FUNCTION set_updated_at();
drop trigger if exists deadlines_set_updated_at on public.deadlines;
CREATE TRIGGER deadlines_set_updated_at BEFORE UPDATE ON public.deadlines FOR EACH ROW EXECUTE FUNCTION set_updated_at();
drop trigger if exists document_texts_body_fingerprint on public.document_texts;
CREATE TRIGGER document_texts_body_fingerprint AFTER INSERT OR UPDATE OF body ON public.document_texts FOR EACH ROW EXECUTE FUNCTION sync_body_fingerprint();
drop trigger if exists documents_log_correction on public.documents;
CREATE TRIGGER documents_log_correction AFTER UPDATE ON public.documents FOR EACH ROW EXECUTE FUNCTION log_correction();
drop trigger if exists documents_resolve_type on public.documents;
CREATE TRIGGER documents_resolve_type BEFORE INSERT OR UPDATE ON public.documents FOR EACH ROW EXECUTE FUNCTION resolve_document_type();
drop trigger if exists documents_set_updated_at on public.documents;
CREATE TRIGGER documents_set_updated_at BEFORE UPDATE ON public.documents FOR EACH ROW EXECUTE FUNCTION set_updated_at();
drop trigger if exists documents_sync_staging_flags on public.documents;
CREATE TRIGGER documents_sync_staging_flags AFTER INSERT OR UPDATE OF drive_file_id ON public.documents FOR EACH ROW EXECUTE FUNCTION sync_staging_flags();
drop trigger if exists emails_log_correction on public.emails;
CREATE TRIGGER emails_log_correction AFTER UPDATE ON public.emails FOR EACH ROW EXECUTE FUNCTION log_correction();
drop trigger if exists emails_set_updated_at on public.emails;
CREATE TRIGGER emails_set_updated_at BEFORE UPDATE ON public.emails FOR EACH ROW EXECUTE FUNCTION set_emails_updated_at();
drop trigger if exists entities_set_updated_at on public.entities;
CREATE TRIGGER entities_set_updated_at BEFORE UPDATE ON public.entities FOR EACH ROW EXECUTE FUNCTION set_updated_at();
drop trigger if exists matters_set_updated_at on public.matters;
CREATE TRIGGER matters_set_updated_at BEFORE UPDATE ON public.matters FOR EACH ROW EXECUTE FUNCTION set_updated_at();
drop trigger if exists notes_set_updated_at on public.notes;
CREATE TRIGGER notes_set_updated_at BEFORE UPDATE ON public.notes FOR EACH ROW EXECUTE FUNCTION set_updated_at();
drop trigger if exists recurring_payments_set_updated_at on public.recurring_payments;
CREATE TRIGGER recurring_payments_set_updated_at BEFORE UPDATE ON public.recurring_payments FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Deny-all for the public API. The skills connect as postgres through the Supabase MCP,
-- the Apps Script bridge uses the secret (service_role) key. anon and authenticated get nothing.
-- RLS on with zero policies is intentional. Do not "fix" the rls_enabled_no_policy lint.
alter table public.attachment_staging enable row level security;
alter table public.backup_snapshots enable row level security;
alter table public.backups enable row level security;
alter table public.bank_statement_imports enable row level security;
alter table public.bank_transactions enable row level security;
alter table public.bridge_messages enable row level security;
alter table public.bridge_runs enable row level security;
alter table public.briefings enable row level security;
alter table public.bundle_requirements enable row level security;
alter table public.bundles enable row level security;
alter table public.classification_rules enable row level security;
alter table public.corrections enable row level security;
alter table public.deadlines enable row level security;
alter table public.derivation_runs enable row level security;
alter table public.document_texts enable row level security;
alter table public.document_type_aliases enable row level security;
alter table public.document_types enable row level security;
alter table public.documents enable row level security;
alter table public.drive_folder_areas enable row level security;
alter table public.email_processing_runs enable row level security;
alter table public.emails enable row level security;
alter table public.entities enable row level security;
alter table public.entity_aliases enable row level security;
alter table public.improvement_proposals enable row level security;
alter table public.life_review_runs enable row level security;
alter table public.life_settings enable row level security;
alter table public.matter_links enable row level security;
alter table public.matters enable row level security;
alter table public.notes enable row level security;
alter table public.processing_runs enable row level security;
alter table public.recall_samples enable row level security;
alter table public.recurring_payments enable row level security;
alter table public.run_locks enable row level security;
alter table public.skill_revisions enable row level security;
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from anon, authenticated, public;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated, public;
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant execute on all functions in schema public to service_role;

