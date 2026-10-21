"""HS256 JWTs for the test PostgREST: the legacy-style anon and service_role keys.

Usage: python3 jwt.py anon|service_role     (prints the token)
"""
import base64, hashlib, hmac, json, sys, time

SECRET = b"lifeos-integration-tests-jwt-secret-0123456789"


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token(role: str) -> str:
    header = _b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    claims = _b64(json.dumps({"role": role, "iss": "supabase", "iat": int(time.time()),
                              "exp": int(time.time()) + 10 * 365 * 86400}).encode())
    sig = _b64(hmac.new(SECRET, f"{header}.{claims}".encode(), hashlib.sha256).digest())
    return f"{header}.{claims}.{sig}"


if __name__ == "__main__":
    print(token(sys.argv[1]))
