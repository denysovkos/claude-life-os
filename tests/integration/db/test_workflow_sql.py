"""Every SQL statement the skill tells Claude to run, run against a real installation.

The workflows are instructions to a model, and most of what the model does is run the
SQL they contain. A renamed column or a dropped view breaks a night run silently. This
test extracts every ```sql block and every inline `select …` / `insert …` / `update …`
from SKILL.md, the workflows and docs/, binds its placeholders, and runs it in a
transaction that is rolled back, against the stack database with fixtures.

- `:id` binds to a real row of the table the statement names (update X … where id = :id).
- Other placeholders get a typed test value (PARAMS below). An unknown one fails the
  test: add it here, so a new placeholder is a decision, not a silent skip.
- A block that is a template (it has `...` or `…` outside quotes) cannot run. For those
  the test checks that every column the template names exists in its table, which is
  what drifts.

Run: tests/integration/db/run.sh  (or python3 -m unittest on this file with the stack up)
"""
import os
import pathlib
import re
import unittest

import psycopg

ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCES = [ROOT / "skills" / "life-os" / "SKILL.md",
           *sorted((ROOT / "skills" / "life-os" / "workflows").glob("*.md")),
           *sorted((ROOT / "docs").glob("*.md"))]

TEXT = "'integration test text'"
PARAMS = {
    "holder": "'it-holder'", "skill": "'email-intake'", "notes": TEXT, "text": TEXT,
    "body": TEXT, "subject": "'[Life OS] Daily brief test'", "value": "'stadtwerke-test.de'",
    "started_at": "now()", "errors": "'[]'", "skipped": "'[]'", "decisions": "'[]'",
    "category_counts": "'{}'", "capabilities": "'{}'",
    "doc": "'00000000-0000-0000-0000-0000000000a2'", "seq": "1", "method": "'local_text'",
    "pages": "1", "chunk_count": "1", "md5": "md5('...')", "md5_of_whole_body": "md5('...')",
    "sender_email": "'rechnung@stadtwerke-test.de'", "sender_name": "'Stadtwerke Test'",
    "file_name": "'Rechnung.pdf'", "issuer": "'Stadtwerke Test'", "area_name": "'Housing'",
    "name": "'Test Owner'", "email": "'owner@lifeos.test'", "tz": "'Europe/Berlin'",
    "out": "'en'", "region": "'de'", "tasks": "'none'", "notes_provider": "'none'",
    "address": "'Neue Strasse 1'", "system_id": "'proj-system'", "default_id": "'proj-default'",
    "member_name": "'Max Test'", "relation": "'child'", "birth_date": "'2017-03-02'",
    "aliases": "'{\"Maximilian Test\"}'", "alias": "'Maximilian Test'",
}
for folder in ("inbox", "emergency", "backups", "catch_all", "identity", "finance", "taxes",
               "housing", "insurance", "work", "legal", "health", "vehicle", "education"):
    PARAMS[f"{folder}_id"] = f"'fld-{folder}'"

INLINE = re.compile(r"`((?:select|insert|update|with)\s[^`]{10,})`", re.I)
BLOCK = re.compile(r"```sql\n(.*?)```", re.S)
PLACEHOLDER = re.compile(r"(?<![:\w]):([a-z_][a-z0-9_]*)")


def snippets():
    for path in SOURCES:
        text = path.read_text(encoding="utf-8")
        for m in BLOCK.finditer(text):
            yield path, text[:m.start()].count("\n") + 2, m.group(1)
        for m in INLINE.finditer(text):
            yield path, text[:m.start()].count("\n") + 1, m.group(1)


def outside_quotes(sql):
    sql = re.sub(r"\$([a-z]*)\$.*?\$\1\$", "''", sql, flags=re.S)   # dollar-quoted strings
    return re.sub(r"'(?:[^']|'')*'", "''", sql)


def is_template(sql):
    """A shape to fill in, not a statement: `...` in the SQL itself or inside JSON."""
    bare = outside_quotes(sql)
    if "..." in bare or "…" in bare:
        return True
    return any("..." in m.group(2) or "…" in m.group(2)
               for m in re.finditer(r"\$(j)\$(.*?)\$j\$", sql, re.S))


def table_of(sql):
    m = re.search(r"\b(?:update|into|from)\s+(?:public\.)?([a-z_]+)", sql, re.I)
    return m.group(1) if m else None


def id_source(sql, has_id):
    """A real row id for `:id`: of the write-back target, the statement's table, or a document."""
    m = re.search(r"'([a-z_]+)'\s*,\s*:id\b", sql)
    table = m.group(1) if m else table_of(sql)
    if not table or not has_id(table):
        table = "documents"
    return f"(select id from {table} order by id limit 1)"


def bind(sql, has_id=lambda table: True):
    unknown = []
    # docs write `where id = '…'` for "the row you mean"
    sql = re.sub(r"'…'", ":id", sql)

    def sub(m):
        name = m.group(1)
        if name == "id":
            return id_source(sql, has_id)
        if name in PARAMS:
            return PARAMS[name]
        unknown.append(name)
        return m.group(0)

    # placeholders never occur inside string literals in these files, but '::type' casts
    # do, so only bind outside quotes
    out, pos = [], 0
    for q in re.finditer(r"\$([a-z]*)\$.*?\$\1\$|'(?:[^']|'')*'", sql, re.S):
        out.append(PLACEHOLDER.sub(sub, sql[pos:q.start()]))
        out.append(q.group(0))
        pos = q.end()
    out.append(PLACEHOLDER.sub(sub, sql[pos:]))
    return "".join(out), unknown


def columns_named(sql):
    """(table, [columns]) pairs a template insert/upsert names."""
    found = []
    for m in re.finditer(r"insert\s+into\s+(?:public\.)?([a-z_]+)\s*\(([^)]*)\)", sql, re.I):
        cols = [c.strip() for c in m.group(2).split(",") if re.fullmatch(r"\s*[a-z_]+\s*", c)]
        found.append((m.group(1), cols))
        tail = sql[m.end():]
        for c in re.findall(r"\b([a-z_]+)\s*=\s*excluded\.", tail):
            found.append((m.group(1), [c]))
    return found


class WorkflowSQL(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = psycopg.connect(autocommit=False)

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def columns(self, table):
        with self.conn.cursor() as cur:
            cur.execute("select column_name from information_schema.columns "
                        "where table_schema = 'public' and table_name = %s", (table,))
            return {r[0] for r in cur.fetchall()}

    def test_every_statement_runs(self):
        ran = templates = 0
        for path, line, sql in snippets():
            where = f"{path.relative_to(ROOT)}:{line}"
            with self.subTest(where=where):
                if is_template(sql):
                    templates += 1
                    for table, cols in columns_named(sql):
                        missing = [c for c in cols if c not in self.columns(table)]
                        self.assertFalse(missing, f"{where}: {table} has no column(s) {missing}")
                    continue
                bound, unknown = bind(sql, lambda t: "id" in self.columns(t))
                self.assertFalse(unknown, f"{where}: unbound placeholder(s) {unknown}; add them to PARAMS")
                try:
                    with self.conn.cursor() as cur:
                        cur.execute("select set_config('app.actor', 'skill', true)")
                        cur.execute(bound.encode())
                    ran += 1
                except psycopg.Error as e:
                    self.fail(f"{where}: {e.diag.message_primary or e}\n--- statement ---\n{bound.strip()[:800]}")
                finally:
                    self.conn.rollback()
        print(f"\nworkflow SQL: {ran} statements ran, {templates} templates checked for columns")
        self.assertGreater(ran, 60, "far fewer statements than the workflows contain: extraction broke")


if __name__ == "__main__":
    unittest.main()
