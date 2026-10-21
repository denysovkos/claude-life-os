#!/usr/bin/env python3
"""Composes real letters from the shipped templates in Postgres: a German Kündigung, a
Widerspruch and an Einspruch from the de region pack, and the generic cancellation of
every language pack. Then walks a letter through its life: missing values, the person's
values kept across composes, approval, the bridge's render call, sending, the deadline
closing, and the brief saying what is left to do.

letter_templates() below is how setup builds the setting `letter_templates` from the
packs (setup.md step 5 describes the same rule in words).

Needs a database with all migrations applied (PG* environment variables). Runs in one
transaction that is rolled back.

Usage: python3 tests/sql_letters_check.py
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANG = ROOT / "packs" / "lang"
REGION = ROOT / "packs" / "region"


def load(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def letter_templates(region, output_locale="en"):
    """The setting: the region's letters over the generic cancellation of its language."""
    region_letters = REGION / str(region) / "letters.json"
    if region and region_letters.exists():
        reg = load(region_letters)
        locale = reg["locale"]
    else:
        reg = None
        inputs = load(REGION / region / "pack.json").get("default_input_locales", []) if region else []
        locale = next((l for l in inputs if (LANG / l / "letters.json").exists()), output_locale)
        if not (LANG / locale / "letters.json").exists():
            locale = "en"
    base = load(LANG / locale / "letters.json")
    out = {"locale": locale, "region": region,
           "version": load((REGION / region / "pack.json") if reg else (LANG / locale / "pack.json"))["version"],
           "date_format": base["date_format"], "child_signature": base.get("child_signature"),
           "kinds": dict(base["kinds"])}
    if reg:
        out["date_format"] = reg.get("date_format", out["date_format"])
        out["child_signature"] = reg.get("child_signature", out["child_signature"])
        out["kinds"].update(reg["kinds"])
    return out


def lit(value):
    return "'" + str(value).replace("'", "''") + "'"


def jsonb(obj):
    return lit(json.dumps(obj, ensure_ascii=False)) + "::jsonb"


def main():
    steps = []

    def run(sql):
        steps.append((sql, None))

    def check(name, sql, expected):
        steps.append((sql, (name, expected)))

    def setting(key, value):
        run(f"insert into life_settings (key, value) values ({lit(key)}, {jsonb(value)}) "
            "on conflict (key) do update set value = excluded.value")

    def letter(source_sql, where="true"):
        return f"(select l from letters l where coalesce(l.recurring_payment_id, l.document_id) = ({source_sql}) and {where} order by l.created_at desc limit 1)"

    run("select set_config('app.actor', 'test', true)")
    run("""create function pg_temp.err(q text) returns text language plpgsql as $$
           begin execute q; return 'no error'; exception when others then return sqlerrm; end $$""")
    de_rules = load(REGION / "de" / "rules.json")
    de_rules.update(region="de", version=load(REGION / "de" / "pack.json")["version"])
    setting("region", "de")
    setting("region_rules", de_rules)
    setting("owner_name", "Anna Beispiel")
    setting("current_address", "Neue Straße 1\n10115 Berlin")
    setting("timezone", "Europe/Berlin")
    setting("dossier_labels", {})

    setting("letter_templates", {})                  # as before setup or the doctor wrote them
    check("no templates: a clear error",
          "select pg_temp.err($q$select compose_letter('cancellation', gen_random_uuid())$q$) like 'letter_templates is not set%'", "true")
    setting("letter_templates", letter_templates("de"))

    # 1. A Kündigung with everything in the index
    run("""insert into entities (id, kind, name, legal_name, address) values
           ('00000000-0000-0000-0000-00000000e101', 'organization', 'Mobilfunk Test', 'Mobilfunk Test GmbH',
            'Kundenservice' || chr(10) || 'Postfach 1' || chr(10) || '20000 Hamburg')""")
    run("""insert into documents (id, drive_file_id, name, drive_url, document_type_key, status, drive_parent_id, last_intake_at)
           values ('00000000-0000-0000-0000-00000000d101', 'lc-telecom', 'Vertrag.pdf', 'https://drive.example/lc',
                   'telecom_contract', 'current', 'fld-housing', clock_timestamp())""")
    run("""insert into deadlines (id, title, deadline_type, due_on, hard, status, source_kind, source_id)
           values ('00000000-0000-0000-0000-00000000dd01', 'Kündigen bis', 'notice_period', current_date + 7, true,
                   'open', 'document', '00000000-0000-0000-0000-00000000d101')""")
    run("""insert into recurring_payments (id, name, vendor, vendor_entity_id, category, amount, period, contract_end,
             notice_period_months, auto_renews, status, reference, document_id, deadline_id)
           values ('00000000-0000-0000-0000-00000000a101', 'Mobilfunk', 'Mobilfunk Test', '00000000-0000-0000-0000-00000000e101',
                   'telecom', 20, 'monthly', date '2027-08-23', 1, true, 'active', 'K-123',
                   '00000000-0000-0000-0000-00000000d101', '00000000-0000-0000-0000-00000000dd01')""")
    rp = "'00000000-0000-0000-0000-00000000a101'::uuid"
    run(f"select compose_letter('cancellation', {rp})")
    l = letter(rp)
    check("Kündigung: nothing missing", f"select array_to_string(({l}).missing, ',')", "")
    check("Kündigung: subject", f"select ({l}).subject", "Kündigung Mobilfunk, Kundennummer K-123")
    check("Kündigung: exit date in German format", f"select position('fristgerecht zum 23.08.2027' in ({l}).body) > 0", "true")
    check("Kündigung: legal basis for telecom", f"select position('§ 56 Abs. 3 TKG' in ({l}).body) > 0", "true")
    check("Kündigung: no placeholder left", f"select (({l}).subject || ({l}).body || ({l}).header) !~ '\\[\\[|\\{{\\{{'", "true")
    check("Kündigung: header has both addresses",
          f"select ({l}).header like 'Anna Beispiel' || chr(10) || 'Neue Straße 1%' || 'Mobilfunk Test GmbH' || chr(10) || 'Kundenservice%'", "true")
    check("Kündigung: arrives by the deadline", f"select (({l}).send_by - current_date)::text", "7")
    check("Kündigung: answers the deadline", f"select ({l}).deadline_id::text", "00000000-0000-0000-0000-00000000dd01")
    check("Kündigung: delivery advice", f"select position('312k BGB' in ({l}).delivery_advice) > 0", "true")
    check("Kündigung: saved next to the contract", f"select ({l}).target_folder_id", "fld-housing")
    check("brief marks the deadline: draft", "select position('[letter: draft]' in briefing_text()) > 0", "true")

    # 2. Approval, rendering, sending
    run(f"select approve_letter(({l}).id)")
    check("approved: the bridge sees it", f"select count(*)::text from letters_to_render() where id = ({l}).id", "1")
    check("approved: the bridge gets the folder", f"select folder_id from letters_to_render() where id = ({l}).id", "fld-housing")
    check("rendered: note for the owner",
          f"select (letter_rendered(({l}).id, 'pdf-1', 'https://drive.example/pdf-1') ->> 'subject') like 'Letter ready: Kündigung%'", "true")
    check("rendered: status ready", f"select ({l}).status", "ready")
    check("rendered: the bridge no longer sees it", f"select count(*)::text from letters_to_render() where id = ({l}).id", "0")
    check("ready and due in 7 days: the brief says send it",
          "select position('letters to send: 1' in briefing_text()) > 0 and position('[letter ready, not sent]' in briefing_text()) > 0", "true")
    check("rendering twice is refused",
          f"select pg_temp.err(format('select letter_rendered(%L, %L, %L)', ({l}).id, 'pdf-2', 'x')) like 'letter_rendered: no approved letter%'", "true")
    run(f"select mark_letter_sent(({l}).id, current_date, 'registered_mail')")
    check("sent: the deadline is done", "select status from deadlines where id = '00000000-0000-0000-0000-00000000dd01'", "done")
    check("sent: a second letter is refused",
          f"select pg_temp.err($q$select compose_letter('cancellation', {rp})$q$) like '%already sent on%'", "true")
    run(f"update letters set sent_on = current_date - 30 where id = ({l}).id")
    check("sent a month ago, no confirmation: reported",
          f"select issue from v_letters_followup where id = ({l}).id", "unconfirmed")
    run(f"select mark_letter_confirmed(({l}).id)")
    check("confirmed: nothing to follow up", f"select count(*)::text from v_letters_followup where id = ({l}).id", "0")

    # 3. What the index does not know is asked for, and kept
    run("""insert into recurring_payments (id, name, vendor, category, amount, period, notice_period_months, auto_renews, status)
           values ('00000000-0000-0000-0000-00000000a102', 'Fitnessstudio', 'Fit Test', 'subscription', 30, 'monthly', 1, true, 'active')""")
    gym = "'00000000-0000-0000-0000-00000000a102'::uuid"
    run(f"select compose_letter('cancellation', {gym})")
    g = letter(gym)
    check("unknown address and number: listed", f"select array_to_string(({g}).missing, ',')", "recipient_address,reference")
    check("unknown values stay visible", f"select position('[[reference]]' in ({g}).body) > 0 and position('[[recipient_address]]' in ({g}).header) > 0", "true")
    check("no fixed end: the next possible date", f"select position('fristgerecht zum ' in ({g}).body) > 0", "true")
    check("an incomplete letter cannot be approved",
          f"select pg_temp.err(format('select approve_letter(%L)', ({g}).id)) like 'approve_letter: still missing%'", "true")
    check("unknown field names are refused",
          f"select pg_temp.err($q$select compose_letter('cancellation', {gym}, '{{\"adress\": \"x\"}}')$q$) like '%unknown field%'", "true")
    run(f"select compose_letter('cancellation', {gym}, '{{\"recipient_address\": \"Sportweg 2\\n10000 Berlin\"}}')")
    run(f"select compose_letter('cancellation', {gym}, '{{\"reference\": \"M-77\"}}')")
    check("the person's values are kept across composes", f"select array_to_string(({g}).missing, ',')", "")
    check("one open letter per contract", f"select count(*)::text from letters where recurring_payment_id = {gym}", "1")
    run(f"select approve_letter(({g}).id)")
    run(f"select letter_rendered(({g}).id, 'pdf-g', 'https://drive.example/pdf-g')")
    run(f"select compose_letter('cancellation', {gym}, '{{\"grounds\": \"x\"}}')")
    check("composing a ready letter again replaces it",
          f"select string_agg(status, ',' order by status) from letters where recurring_payment_id = {gym}", "draft,withdrawn")

    # 4. A child's contract is signed by the owner as their representative
    run("insert into household_members (id, name, relation) values ('00000000-0000-0000-0000-00000000b101', 'Max Beispiel', 'child')")
    run("""insert into recurring_payments (id, name, vendor, category, amount, period, notice_period_months, auto_renews,
             status, reference, subject_person)
           values ('00000000-0000-0000-0000-00000000a103', 'Musikschule', 'Musik Test', 'subscription', 40, 'monthly', 3,
                   true, 'active', 'S-1', 'Max Beispiel')""")
    kid = "'00000000-0000-0000-0000-00000000a103'::uuid"
    run(f"select compose_letter('cancellation', {kid}, '{{\"recipient_address\": \"Notenweg 3\"}}')")
    k = letter(kid)
    check("child: holder is the child", f"select ({k}).fields ->> 'holder_name'", "Max Beispiel")
    check("child: signed by the owner as representative",
          f"select position('Anna Beispiel' || chr(10) || 'als gesetzliche Vertretung für Max Beispiel' in ({k}).body) > 0", "true")

    # 5. Einspruch and Widerspruch from decisions
    run("""insert into entities (id, kind, name, address) values
           ('00000000-0000-0000-0000-00000000e102', 'authority', 'Finanzamt Test', 'Steuerstraße 1' || chr(10) || '10000 Berlin')""")
    run("""insert into documents (id, drive_file_id, name, drive_url, document_type_key, issuer_entity_id, issued_on, status, last_intake_at)
           values ('00000000-0000-0000-0000-00000000d102', 'lc-tax', 'Steuerbescheid.pdf', 'https://drive.example/tax',
                   'tax_assessment', '00000000-0000-0000-0000-00000000e102', current_date - 5, 'current', clock_timestamp()),
                  ('00000000-0000-0000-0000-00000000d103', 'lc-dec', 'Bescheid.pdf', 'https://drive.example/dec',
                   'official_decision', '00000000-0000-0000-0000-00000000e102', current_date - 5, 'current', clock_timestamp())""")
    run("select derive_deadlines()")
    tax = "'00000000-0000-0000-0000-00000000d102'::uuid"
    dec = "'00000000-0000-0000-0000-00000000d103'::uuid"
    run(f"select compose_letter('objection', {tax}, '{{\"reference\": \"12/345/67890\"}}')")
    t = letter(tax)
    check("Einspruch: kind from the document type", f"select ({t}).kind", "objection_tax")
    check("Einspruch: complete", f"select array_to_string(({t}).missing, ',')", "")
    check("Einspruch: cites § 347 AO and the decision date",
          f"select position('§ 347 AO' in ({t}).body) > 0 and position(to_char(current_date - 5, 'DD.MM.YYYY') in ({t}).subject) > 0", "true")
    check("Einspruch: names the decision in German", f"select position('(Steuerbescheid)' in ({t}).body) > 0", "true")
    check("Einspruch: due when the objection period ends",
          f"select (({t}).send_by = (select due_on from deadlines where source_id = {tax} and deadline_type = 'legal_response'))::text", "true")
    check("Einspruch: the legal basis comes from the region rule", f"select ({t}).legal_basis like '§ 355 Abs. 1 AO%'", "true")
    run(f"select compose_letter('objection', {dec})")
    w = letter(dec)
    check("Widerspruch: kind", f"select ({w}).kind", "objection_administrative")
    check("Widerspruch: asks for the file number", f"select array_to_string(({w}).missing, ',')", "reference")
    check("a contract is no decision",
          "select pg_temp.err($q$select compose_letter('objection', '00000000-0000-0000-0000-00000000d101')$q$) like '%not a decision%'", "true")

    # 6. Every language pack's generic cancellation renders completely
    for lang in sorted(p.name for p in LANG.iterdir() if (p / "letters.json").exists()):
        tpl = letter_templates(None, lang)
        setting("letter_templates", tpl)
        rid = f"'00000000-0000-0000-0000-0000000{abs(hash(lang)) % 100000:05d}'::uuid"
        run(f"""insert into recurring_payments (id, name, vendor, category, amount, period, notice_period_months, auto_renews, status, reference)
                values ({rid}, 'Contract {lang}', 'Vendor {lang}', 'utilities', 10, 'monthly', 1, true, 'active', 'R-{lang}')""")
        run(f"select compose_letter('cancellation', {rid}, '{{\"recipient_address\": \"Street 1\"}}')")
        c = letter(rid)
        check(f"{lang}: generic cancellation complete", f"select array_to_string(({c}).missing, ',')", "")
        check(f"{lang}: nothing left unfilled", f"select (({c}).subject || ({c}).body) !~ '\\[\\[|\\{{\\{{'", "true")
        check(f"{lang}: letter language", f"select ({c}).locale", lang)
        check(f"{lang}: no objection template without a region pack for it",
              f"select pg_temp.err($q$select compose_letter('objection', {tax})$q$) like '%no objection_tax template%'", "true")

    # 7. A region without letters writes in its own language
    check("fr region without letters: French letters", f"select {lit(letter_templates('fr')['locale'])}", "fr")

    script = ["begin;"]
    for sql, spec in steps:
        script.append(sql + ";" if spec is None else
                      f"select 'CHECK|' || {lit(spec[0])} || '|' || coalesce(({sql})::text, 'NULL');")
    script.append("rollback;")
    res = subprocess.run(["psql", "-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1"],
                         input="\n".join(script) + "\n", capture_output=True, text=True)
    if res.returncode:
        print(res.stdout, res.stderr, sep="\n")
        return 1
    got = [line.split("|", 2)[1:] for line in res.stdout.splitlines() if line.startswith("CHECK|")]
    expected = [spec for _, spec in steps if spec is not None]
    failed = 0
    for (name, want), (_, value) in zip(expected, got):
        ok = value == want
        failed += not ok
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {value!r}, expected {want!r}"))
    if len(got) != len(expected):
        print(f"FAIL expected {len(expected)} checks, got {len(got)}")
        return 1
    print(f"letter checks: {len(got) - failed}/{len(got)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
