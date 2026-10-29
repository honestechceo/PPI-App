"""Build index.html for GitHub Pages from app.html (the app page itself).

app.html is written without <html>/<head>/<body> tags. This wraps it in a full
document and adds the home-screen app links (icon, manifest, iPhone settings).

Run:  python3 build.py           (the website)
      python3 build.py --www     (also the iPhone app's files, in www/)
"""
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).parent
page = (ROOT / "app.html").read_text(encoding="utf-8")

head = (
    '<!doctype html><html lang="en"><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
    '<meta name="apple-mobile-web-app-capable" content="yes">'
    '<meta name="mobile-web-app-capable" content="yes">'
    '<meta name="apple-mobile-web-app-title" content="Honestech">'
    '<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">'
    '<meta name="theme-color" content="#15202b">'
    '<link rel="manifest" href="manifest.webmanifest">'
    '<link rel="apple-touch-icon" href="icons/apple-touch-icon.png">'
    '<link rel="icon" type="image/png" sizes="192x192" href="icons/icon-192.png">'
    "<style>:root{color-scheme:light;box-sizing:border-box;"
    "padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}"
    "html{scroll-padding-top:env(safe-area-inset-top,0px)}"
    "body{margin:0;padding:0;font:14px -apple-system,BlinkMacSystemFont,sans-serif;background:#0b1118;color:#000}"
    "img{max-width:100%}[hidden]:not([hidden=until-found i]){display:none!important}</style>"
    "</head><body>\n"
)
(ROOT / "index.html").write_text(head + page.rstrip() + "\n</body></html>\n", encoding="utf-8")
print("index.html built")

# ---- iPhone app (Capacitor): the same page, with its libraries kept inside the app so it works offline ----
VENDOR = {
    "https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js": "vendor/jspdf.umd.min.js",
    "https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js": "vendor/xlsx.full.min.js",
    "https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js": "vendor/qrcode.js",
    "https://cdn.jsdelivr.net/npm/@zxing/library@0.20.0/umd/index.min.js": "vendor/zxing.min.js",
}
if "--www" in sys.argv:
    www = ROOT / "www"
    if www.exists():
        shutil.rmtree(www)
    (www / "vendor").mkdir(parents=True)
    html = (ROOT / "index.html").read_text(encoding="utf-8")
    for url, local in VENDOR.items():
        html = html.replace(url, local)
    # Capacitor's runtime first, so the app can reach the iPhone's share sheet, notifications, etc.
    html = html.replace("<head>", '<head><script src="capacitor.js"></script>', 1)
    html = re.sub(r'<link rel="manifest"[^>]*>', "", html)
    (www / "index.html").write_text(html, encoding="utf-8")
    for f in ["privacy.html", "terms.html"]:
        shutil.copy(ROOT / f, www / f)
    shutil.copytree(ROOT / "icons", www / "icons")
    (www / "vendor" / "SOURCES.txt").write_text("\n".join(f"{u} -> {l}" for u, l in VENDOR.items()) + "\n", encoding="utf-8")
    print("www/ built (add capacitor.js and the vendor/ files, see .github/workflows/ios.yml)")
