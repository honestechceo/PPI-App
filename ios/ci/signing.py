#!/usr/bin/env python3
"""App Store signing for the GitHub build, using the App Store Connect API key (no Mac or test iPhone needed).

Creates an Apple Distribution certificate and an App Store provisioning profile for the app,
installs them on the build Mac, and writes the names the build needs to $GITHUB_ENV.
Standard library + openssl only.

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC key file path in ASC_KEY_PATH, BUNDLE_ID, RUNNER_TEMP, GITHUB_ENV.
"""
import base64, json, os, subprocess, time, urllib.parse, urllib.request, urllib.error, uuid, pathlib

API = "https://api.appstoreconnect.apple.com/v1"
KEY_ID, ISSUER, KEY_PATH = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], os.environ["ASC_KEY_PATH"]
BUNDLE = os.environ.get("BUNDLE_ID", "com.honestechmobileapp.app")
TMP = pathlib.Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "signing"
PROFILE_NAME = "Honestech App Store (GitHub)"
OPENSSL = "/usr/bin/openssl" if os.path.exists("/usr/bin/openssl") else "openssl"  # macOS LibreSSL makes .p12 files the keychain accepts


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(sig: bytes) -> bytes:
    """ECDSA signature: DER SEQUENCE(r, s) -> 64-byte r||s (what JWT ES256 wants)."""
    assert sig[0] == 0x30
    i = 2 if sig[1] < 0x80 else 2 + (sig[1] & 0x7F)
    out = b""
    for _ in range(2):
        assert sig[i] == 0x02
        n = sig[i + 1]
        v = sig[i + 2 : i + 2 + n].lstrip(b"\x00")
        out += v.rjust(32, b"\x00")
        i += 2 + n
    return out


def jwt() -> str:
    head = b64u(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    now = int(time.time())
    body = b64u(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}).encode())
    msg = f"{head}.{body}".encode()
    sig = subprocess.run([OPENSSL, "dgst", "-sha256", "-sign", KEY_PATH], input=msg, capture_output=True, check=True).stdout
    return f"{head}.{body}.{b64u(der_to_raw(sig))}"


def api(method: str, path: str, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + jwt(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:900]
        print(f"::error::Apple API {method} {path.split('?')[0]} failed ({e.code}): {detail}")
        raise SystemExit(1)


def main():
    TMP.mkdir(parents=True, exist_ok=True)
    # 1. the app's ID
    ids = api("GET", f"/bundleIds?filter[identifier]={BUNDLE}&limit=5")["data"]
    ids = [d for d in ids if d["attributes"]["identifier"] == BUNDLE]
    if not ids:
        print(f"::error::The app ID {BUNDLE} isn't registered (developer.apple.com → Identifiers).")
        raise SystemExit(1)
    bundle_id = ids[0]["id"]

    # 2. a fresh Apple Distribution certificate (Apple allows only a few: retire the oldest when at the limit)
    certs = api("GET", "/certificates?filter[certificateType]=DISTRIBUTION&limit=50")["data"]
    certs.sort(key=lambda c: c["attributes"].get("expirationDate") or "")
    while len(certs) >= 2:
        old = certs.pop(0)
        print("Retiring old distribution certificate", old["id"])
        api("DELETE", f"/certificates/{old['id']}")
    key = TMP / "dist.key"
    csr = TMP / "dist.csr"
    subprocess.run([OPENSSL, "genrsa", "-out", str(key), "2048"], check=True, capture_output=True)
    subprocess.run([OPENSSL, "req", "-new", "-key", str(key), "-out", str(csr), "-subj", "/CN=Honestech GitHub/O=Honestech/C=US"], check=True, capture_output=True)
    made = api("POST", "/certificates", {"data": {"type": "certificates", "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr.read_text()}}})["data"]
    cert_id = made["id"]
    cer = TMP / "dist.cer"
    cer.write_bytes(base64.b64decode(made["attributes"]["certificateContent"]))
    pem = TMP / "dist.pem"
    subprocess.run([OPENSSL, "x509", "-inform", "DER", "-in", str(cer), "-out", str(pem)], check=True, capture_output=True)
    p12 = TMP / "dist.p12"
    p12pw = uuid.uuid4().hex
    subprocess.run([OPENSSL, "pkcs12", "-export", "-inkey", str(key), "-in", str(pem), "-out", str(p12), "-passout", f"pass:{p12pw}"], check=True, capture_output=True)

    # 3. a fresh App Store profile for the app with that certificate (replaces the last one)
    for p in api("GET", f"/profiles?filter[name]={urllib.parse.quote(PROFILE_NAME)}&limit=50")["data"]:
        api("DELETE", f"/profiles/{p['id']}")
    prof = api("POST", "/profiles", {"data": {"type": "profiles", "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_STORE"},
                                              "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                                                                "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}})["data"]
    uid = prof["attributes"]["uuid"]
    content = base64.b64decode(prof["attributes"]["profileContent"])
    for d in [pathlib.Path.home() / "Library/MobileDevice/Provisioning Profiles", pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"]:
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{uid}.mobileprovision").write_bytes(content)

    # 4. a private keychain on the build Mac holding the certificate
    kc = str(TMP / "build.keychain-db")
    kcpw = uuid.uuid4().hex
    sh = lambda *a: subprocess.run(list(a), check=True, capture_output=True)
    sh("security", "create-keychain", "-p", kcpw, kc)
    sh("security", "set-keychain-settings", "-lut", "3600", kc)
    sh("security", "unlock-keychain", "-p", kcpw, kc)
    sh("security", "import", str(p12), "-k", kc, "-P", p12pw, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    sh("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", kcpw, kc)
    existing = subprocess.run(["security", "list-keychains", "-d", "user"], capture_output=True, text=True).stdout.split()
    sh("security", "list-keychains", "-d", "user", "-s", kc, *[e.strip('"') for e in existing])
    ident = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning", kc], capture_output=True, text=True).stdout
    print(ident)
    if "Apple Distribution" not in ident:
        print("::error::The signing certificate didn't install on the build Mac.")
        raise SystemExit(1)

    with open(os.environ["GITHUB_ENV"], "a") as f:
        f.write(f"PROFILE_NAME={PROFILE_NAME}\nPROFILE_UUID={uid}\nSIGN_KEYCHAIN={kc}\n")
    print(f"Signing ready: certificate {cert_id}, profile {PROFILE_NAME} ({uid})")


if __name__ == "__main__":
    main()
