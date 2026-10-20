"""Contract tests for packs/lang/* and packs/region/*.

Run: python3 -m unittest discover -s tests -v

Every pack is checked for structure. A pack with status "stable" (for region packs also
"beta") is also run against its own synthetic examples: dates and amounts must parse to the expected values with the
pack's formats.json, every example email must score highest on its expected category
with the pack's keywords.json, and every region term rule must produce the expected
date. Skeleton packs only have to be well-formed.

The parser here is deliberately dumb. The skills read mail with judgement, not regexes;
this test only proves the hints in a pack are internally consistent and good enough
to break ties on the obvious cases.
"""

import calendar
import datetime as dt
import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANG = ROOT / "packs" / "lang"
REGION = ROOT / "packs" / "region"

CATEGORIES = {
    "purchases", "orders_delivery", "government", "bank_finance", "bills_payments",
    "legal_notary", "work", "health", "travel", "personal_social",
}

# Must match dossier_label() in supabase/migrations/0018_letters.sql.
DOSSIER_KEYS = {
    "title", "generated", "intro", "matters", "hard_deadlines", "loans", "insurance",
    "subscriptions", "notice", "months", "notice_unknown", "until", "total", "per_month",
    "identity", "valid_until", "original", "property", "contacts", "none",
    "overdue_since", "close_or_reschedule", "subject_unknown", "file_missing",
    "household", "rel_self", "rel_partner", "rel_child", "rel_parent", "rel_other", "born",
    "letter_ready", "letter_to", "letter_send_by", "letter_how", "letter_after_sending", "letter_not_advice",
}

# Letter kinds (letters_kind_check) and the fields compose_letter() fills (its `known` list,
# in supabase/migrations/0018_letters.sql).
LETTER_KINDS = {"cancellation", "objection_administrative", "objection_tax"}
LETTER_DATE_FORMATS = {"YYYY-MM-DD", "DD.MM.YYYY", "DD/MM/YYYY", "DD-MM-YYYY", "MM/DD/YYYY"}


def letter_fields():
    sql = (ROOT / "supabase" / "migrations" / "0018_letters.sql").read_text(encoding="utf-8")
    known = re.search(r"known constant text\[\] := array\[(.*?)\];", sql, re.S).group(1)
    return set(re.findall(r"'([a-z_]+)'", known))


def check_letters(case, letters, region=False):
    fields = letter_fields()
    case.assertIn(letters["date_format"], LETTER_DATE_FORMATS)
    case.assertIn("{{holder_name}}", letters.get("child_signature", "{{holder_name}}"))
    case.assertTrue(LANG.joinpath(letters["locale"]).is_dir(), "a letter language needs its language pack")
    case.assertLessEqual(set(letters["kinds"]), LETTER_KINDS, "unknown letter kind")
    if not region:
        case.assertIn("cancellation", letters["kinds"], "every language has a generic cancellation")
    for kind, t in letters["kinds"].items():
        with case.subTest(kind=kind):
            for key in ("required", "subject", "body", "delivery"):
                case.assertIn(key, t)
            case.assertLessEqual(set(t["required"]), fields)
            texts = [t["subject"], t["body"], t.get("effective_clause", ""), t.get("effective_clause_unknown", ""),
                     t.get("grounds", "")]
            used = set(re.findall(r"\{\{([a-z_]+)\}\}", " ".join(texts)))
            case.assertLessEqual(used, fields, "placeholder compose_letter does not fill")
            case.assertIn("{{sender_name}}", t["body"], "the letter must be signed")
            for r in t["required"]:
                if r not in ("sender_address", "recipient_name", "recipient_address"):   # those go in the header
                    case.assertIn("{{" + r + "}}", t["subject"] + t["body"], f"required {r} is never printed")
            if "{{decision_title}}" in t["body"]:
                case.assertTrue(t.get("decision_title"), "a default decision_title in the letter's language")
            if kind == "cancellation":
                case.assertIn("{{effective_clause}}", t["body"])
                case.assertIn("{{effective_date}}", t["effective_clause"])
                case.assertNotIn("{{", t["effective_clause_unknown"])
            for extra in ("reference_label", "delivery", "basis"):
                value = t.get(extra)
                if isinstance(value, dict) and extra != "basis":
                    case.assertIn("default", value, f"{extra} needs a default")
                for v in (value.values() if isinstance(value, dict) else [value] if value else []):
                    case.assertTrue(v.strip())
                    case.assertNotIn("{{", v)

FOLDER_KEYS = {
    "root", "inbox", "emergency", "backups", "catch_all", "identity", "finance", "taxes",
    "housing", "insurance", "work", "legal", "health", "vehicle", "education",
}

# Must match recurring_payments_tax_relevance_check in 0001_tables.sql.
TAX_RELEVANCE = {
    "vorsorge_basisrente", "vorsorge_sonstige", "werbungskosten_candidate", "35a_candidate",
}

# stable: reviewed against the law and used in practice. beta: written from the statutes,
# arithmetic tested, not yet confirmed by someone who lives there. skeleton: structure only.
REGION_STATUS = {"stable", "beta", "skeleton"}

DEADLINE_TYPES = {
    "document_expiry", "payment_due", "legal_response", "notice_period", "appointment",
    "contract_milestone", "other",
}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def lang_packs():
    return sorted(p for p in LANG.iterdir() if p.is_dir() and not p.name.startswith("_"))


def region_packs():
    return sorted(p for p in REGION.iterdir() if p.is_dir() and not p.name.startswith("_"))


# ---------------------------------------------------------------------------------------
# Reference parsing, driven only by the pack's own data
# ---------------------------------------------------------------------------------------

def parse_date(text, formats):
    months = {k.lower(): v for k, v in formats.get("month_names", {}).items()}
    for pattern in formats["date_patterns"]:
        m = re.search(pattern, text, re.IGNORECASE)
        if not m:
            continue
        g = m.groupdict()
        if g.get("mon"):
            month = months.get(g["mon"].lower().rstrip("."))
            if month is None:
                continue
        else:
            month = int(g["m"])
        year = int(g["y"])
        if year < 100:
            year += 2000
        return dt.date(year, month, int(g["d"])).isoformat()
    return None


def parse_amount(text, formats):
    m = re.search(formats["amount_pattern"], text)
    if not m:
        return None
    raw = m.group("amount")
    raw = raw.replace(formats["thousands_separator"], "").replace(" ", "").replace(" ", "")
    raw = raw.replace(formats["decimal_separator"], ".")
    return f"{float(raw):.2f}"


def score(text, keywords):
    text = text.lower()
    return {cat: sum(1 for kw in kws if kw.lower() in text) for cat, kws in keywords.items()}


def add_months(d, n):
    y, m = divmod(d.month - 1 + n, 12)
    y, m = d.year + y, m + 1
    return dt.date(y, m, min(d.day, calendar.monthrange(y, m)[1]))


def apply_rule(rule, start, actual_receipt=False):
    """Same semantics as apply_term_rule() in migration 0007; tests/sql_rules_check.py
    proves the two agree."""
    d = dt.date.fromisoformat(start)
    if not actual_receipt:
        d += dt.timedelta(days=rule.get("notification_offset_days", 0))
    for step in rule["steps"]:
        if "add_days" in step:
            d += dt.timedelta(days=step["add_days"])
        elif "add_months" in step:
            d = add_months(d, step["add_months"])
        elif "term_months" in step:
            # A term that starts on a day ends with the day before the corresponding day
            # n months later, or on the last day of that month if it has no such day
            # (§ 188 Abs. 2 and 3 BGB, and the same rule in most civil-law countries).
            target = add_months(d, step["term_months"])
            d = target if target.day < d.day else target - dt.timedelta(days=1)
        elif "add_business_days" in step:
            # Monday to Friday; public holidays are regional and left to the rule's notes.
            left = step["add_business_days"]
            while left > 0:
                d += dt.timedelta(days=1)
                if d.weekday() < 5:
                    left -= 1
        elif "end_of_month" in step:
            d = d.replace(day=calendar.monthrange(d.year, d.month)[1])
        else:
            raise ValueError(f"unknown step {step}")
    if rule.get("roll_to_business_day"):
        while d.weekday() >= 5:
            d += dt.timedelta(days=1)
    return d.isoformat()


# ---------------------------------------------------------------------------------------
# Language packs
# ---------------------------------------------------------------------------------------

class LangPackTest(unittest.TestCase):

    def test_there_are_stable_packs(self):
        stable = [p.name for p in lang_packs() if load(p / "pack.json")["status"] == "stable"]
        for locale in ("en", "de", "uk"):
            self.assertIn(locale, stable)

    def test_structure(self):
        for pack in lang_packs():
            with self.subTest(pack=pack.name):
                meta = load(pack / "pack.json")
                self.assertEqual(meta["locale"], pack.name)
                self.assertIn(meta["status"], {"stable", "skeleton"})
                for name in ("dossier.json", "folders.json", "keywords.json", "letters.json"):
                    self.assertTrue((pack / name).exists(), name)

                dossier = load(pack / "dossier.json")
                self.assertLessEqual(set(dossier), DOSSIER_KEYS, "unknown dossier keys")
                folders = load(pack / "folders.json")
                self.assertLessEqual(set(folders), FOLDER_KEYS, "unknown folder keys")
                keywords = load(pack / "keywords.json")
                self.assertLessEqual(set(keywords["categories"]), CATEGORIES, "unknown category")

                if meta["status"] == "stable":
                    self.assertEqual(set(dossier), DOSSIER_KEYS, "stable pack needs every label")
                    self.assertEqual(set(folders), FOLDER_KEYS, "stable pack needs every folder")
                    self.assertEqual(set(keywords["categories"]), CATEGORIES)
                    for cat, kws in keywords["categories"].items():
                        self.assertGreaterEqual(len(kws), 4, cat)
                    self.assertTrue((pack / "formats.json").exists())
                    self.assertTrue((pack / "examples.json").exists())
                for value in list(dossier.values()) + list(folders.values()):
                    self.assertTrue(value.strip(), "empty label")
                letters = load(pack / "letters.json")
                self.assertEqual(letters["locale"], pack.name)
                check_letters(self, letters)

    def test_folder_names_are_drive_safe(self):
        for pack in lang_packs():
            for key, name in load(pack / "folders.json").items():
                with self.subTest(pack=pack.name, key=key):
                    self.assertNotRegex(name, r"[/\\]")

    def test_examples(self):
        for pack in lang_packs():
            if load(pack / "pack.json")["status"] != "stable":
                continue
            formats = load(pack / "formats.json")
            keywords = load(pack / "keywords.json")["categories"]
            examples = load(pack / "examples.json")
            self.assertGreaterEqual(len(examples["emails"]), len(CATEGORIES))
            self.assertEqual({e["expect_category"] for e in examples["emails"]}, CATEGORIES,
                             f"{pack.name}: need at least one example per category")

            for ex in examples["dates"]:
                with self.subTest(pack=pack.name, date=ex["text"]):
                    self.assertEqual(parse_date(ex["text"], formats), ex["expect"])
            for ex in examples["amounts"]:
                with self.subTest(pack=pack.name, amount=ex["text"]):
                    self.assertEqual(parse_amount(ex["text"], formats), ex["expect"])
            for ex in examples["emails"]:
                with self.subTest(pack=pack.name, email=ex["subject"]):
                    s = score(ex["subject"] + "\n" + ex["body"], keywords)
                    best = max(s.values())
                    winners = [c for c, v in s.items() if v == best]
                    self.assertGreater(best, 0, "no keyword matched")
                    self.assertEqual(winners, [ex["expect_category"]], s)


# ---------------------------------------------------------------------------------------
# Region packs
# ---------------------------------------------------------------------------------------

class RegionPackTest(unittest.TestCase):

    def test_structure(self):
        seed = (ROOT / "supabase" / "seed" / "document_types.sql").read_text(encoding="utf-8")
        known_types = set(re.findall(r'"key":"([a-z_]+)"', seed))
        for pack in region_packs():
            with self.subTest(pack=pack.name):
                meta = load(pack / "pack.json")
                self.assertEqual(meta["region"], pack.name)
                self.assertIn(meta["status"], REGION_STATUS)
                rules = load(pack / "rules.json")
                keys = set()
                for rule in rules["term_rules"]:
                    self.assertNotIn(rule["key"], keys, "duplicate rule key")
                    keys.add(rule["key"])
                    self.assertIn(rule["deadline_type"], DEADLINE_TYPES)
                    self.assertIn(rule["start"], {"issued_on", "received_on", "contract_start",
                                                  "contract_end", "delivered_on", "event_date",
                                                  "expiry_date"})
                    self.assertTrue(rule["basis"])
                    for t in rule.get("applies_to", []):
                        self.assertIn(t, known_types, f"{rule['key']}: unknown document type {t}")
                    if rule["hard"]:
                        self.assertTrue(rule.get("lead_days"), f"{rule['key']}: hard rule needs a ladder")
                    self.assertIsInstance(rule.get("notification_offset_days", 0), int)
                    for step in rule["steps"]:
                        self.assertEqual(len(step), 1)
                        self.assertIn(next(iter(step)), {"add_days", "add_months", "term_months", "add_business_days", "end_of_month"})
                self.assertIsInstance(rules.get("purchase_rights_min_amount", 0), (int, float))
                self.assertIsInstance(rules.get("purchase_rights_ignore", []), list)
                labels = rules.get("tax_relevance_labels", {})
                self.assertLessEqual(set(labels), TAX_RELEVANCE, "unknown tax_relevance value")
                for a in rules.get("authorities", []):
                    self.assertIn(a["kind"], {"authority", "organization", "court"})
                    self.assertIn(a["category"], CATEGORIES)
                if (pack / "letters.json").exists():
                    letters = load(pack / "letters.json")
                    self.assertEqual(letters["region"], pack.name)
                    check_letters(self, letters, region=True)
                    # an objection letter answers the deadline a term rule makes
                    rule_keys = {r["key"] for r in rules["term_rules"]}
                    for kind in set(letters["kinds"]) - {"cancellation"}:
                        self.assertIn(kind, rule_keys, f"{kind} letter without a term rule of that key")

    def test_rule_examples(self):
        for pack in region_packs():
            if load(pack / "pack.json")["status"] == "skeleton":
                continue
            rules = {r["key"]: r for r in load(pack / "rules.json")["term_rules"]}
            examples = load(pack / "examples.json")["term_rules"]
            self.assertTrue(set(rules) <= {e["rule"] for e in examples},
                            f"{pack.name}: every rule needs an example")
            for ex in examples:
                with self.subTest(pack=pack.name, rule=ex["rule"], start=ex["start"]):
                    self.assertEqual(apply_rule(rules[ex["rule"]], ex["start"]), ex["expect"])

    def test_classification_rules_reference_authorities(self):
        for pack in region_packs():
            sql = pack / "classification_rules.sql"
            if not sql.exists():
                continue
            text = sql.read_text(encoding="utf-8")
            for cat in re.findall(r"'(?:domain|contains|equals|prefix)',\s*'[^']*',\s*'([a-z_]+)'", text):
                with self.subTest(pack=pack.name, category=cat):
                    self.assertIn(cat, CATEGORIES | {"none"})


if __name__ == "__main__":
    unittest.main()
