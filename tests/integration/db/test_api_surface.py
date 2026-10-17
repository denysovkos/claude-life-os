"""The public API of an installation, probed over HTTP the way an attacker would.

Supabase exposes the database through PostgREST. Anyone who learns the project URL can
call it with the publishable (anon) key, and a signed-in user would be `authenticated`.
Neither may read or write anything: this walks every table, view and function in the
schema, from the catalog, so a new object is covered without editing this file.

The bridge's key (service_role) is meant to work, but even it may not change what an
outbox mail says, only whether it was sent.
"""
import json
import os
import unittest
import urllib.error
import urllib.request

import psycopg

REST = os.environ["LIFEOS_REST_URL"]
KEYS = {"anon": os.environ["LIFEOS_ANON_KEY"], "service_role": os.environ["LIFEOS_SERVICE_KEY"]}


def jwt_for(role):
    import importlib.util, pathlib
    spec = importlib.util.spec_from_file_location("jwt", pathlib.Path(__file__).parents[1] / "lib" / "jwt.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.token(role)


def call(method, path, role, body=None, headers=None):
    req = urllib.request.Request(REST + path, method=method,
                                 data=None if body is None else json.dumps(body).encode())
    token = KEYS.get(role) or jwt_for(role)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("apikey", token)
    req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=10) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class PublicApi(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with psycopg.connect() as conn, conn.cursor() as cur:
            cur.execute("select c.relname, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                        "where n.nspname = 'public' and c.relkind in ('r','v','m') order by 1")
            cls.relations = cur.fetchall()
            cur.execute("select p.proname from pg_proc p where p.pronamespace = 'public'::regnamespace "
                        "and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') "
                        "and p.prorettype <> 'trigger'::regtype order by 1")
            cls.functions = sorted({r[0] for r in cur.fetchall()})
        assert len(cls.relations) > 70 and len(cls.functions) > 20, "catalog walk found too little"

    def test_anon_and_authenticated_read_nothing(self):
        for role in ("anon", "authenticated"):
            for name, kind in self.relations:
                with self.subTest(role=role, relation=name):
                    status, body = call("GET", f"/{name}?limit=1", role)
                    self.assertIn(status, (401, 403), f"{role} read {name}: {status} {body[:200]}")

    def test_anon_and_authenticated_write_nothing(self):
        for role in ("anon", "authenticated"):
            for name, kind in self.relations:
                if kind != "r":
                    continue
                with self.subTest(role=role, table=name):
                    status, body = call("POST", f"/{name}", role, {})
                    self.assertIn(status, (401, 403), f"{role} wrote {name}: {status} {body[:200]}")
                    status, body = call("PATCH", f"/{name}?id=eq.00000000-0000-0000-0000-000000000000", role, {})
                    self.assertIn(status, (400, 401, 403), f"{role} patched {name}: {status} {body[:200]}")

    def test_anon_and_authenticated_call_no_function(self):
        for role in ("anon", "authenticated"):
            for fn in self.functions:
                with self.subTest(role=role, function=fn):
                    status, body = call("POST", f"/rpc/{fn}", role, {})
                    # 401/403: denied. 404: PostgREST hides a function the role cannot execute.
                    self.assertIn(status, (401, 403, 404), f"{role} called {fn}: {status} {body[:200]}")
                    self.assertNotIn("emergency", body.lower() if status < 300 else "")

    def test_service_role_reaches_what_the_bridge_needs(self):
        for path in ("/life_settings?select=key&limit=1", "/v_bridge_queue?limit=1", "/v_bridge_heal?limit=1",
                     "/attachment_staging?limit=1", "/v_intake_watchdog?limit=1", "/v_outbox_pending?limit=1"):
            with self.subTest(path=path):
                status, body = call("GET", path, "service_role")
                self.assertEqual(status, 200, body[:200])
        status, body = call("POST", "/rpc/emergency_dossier", "service_role", {})
        self.assertEqual(status, 200, body[:200])

    def test_service_role_cannot_rewrite_or_redirect_outbox_mail(self):
        status, body = call("PATCH", "/outbox?id=eq.00000000-0000-0000-0000-000000000041", "service_role",
                            {"body": "rewritten"})
        self.assertIn(status, (401, 403), f"service_role rewrote an outbox body: {status} {body[:200]}")
        status, body = call("POST", "/outbox", "service_role",
                            {"kind": "notice", "subject": "x", "body": "y"})
        self.assertIn(status, (401, 403), f"service_role queued mail: {status} {body[:200]}")
        status, body = call("PATCH", "/outbox?id=eq.00000000-0000-0000-0000-000000000041", "service_role",
                            {"attempts": 0}, {"Prefer": "return=minimal"})
        self.assertIn(status, (200, 204), body[:200])


if __name__ == "__main__":
    unittest.main()
