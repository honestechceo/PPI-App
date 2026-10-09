"""Build index.html for GitHub Pages from app.html (the app page itself).

app.html is written without <html>/<head>/<body> tags. This wraps it in a full
document and adds the home-screen app links (icon, manifest, iPhone settings).

Run:  python3 build.py
"""
from pathlib import Path

ROOT = Path(__file__).parent
page = (ROOT / "app.html").read_text(encoding="utf-8")

head = (
    '<!doctype html><html lang="en"><head><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
    '<meta name="apple-mobile-web-app-capable" content="yes">'
    '<meta name="mobile-web-app-capable" content="yes">'
    '<meta name="apple-mobile-web-app-title" content="Honestech PPI">'
    '<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">'
    '<meta name="theme-color" content="#15202b">'
    '<link rel="manifest" href="manifest.webmanifest">'
    '<link rel="apple-touch-icon" href="icons/apple-touch-icon.png">'
    '<link rel="icon" type="image/png" sizes="192x192" href="icons/icon-192.png">'
    "<style>:root{color-scheme:light;box-sizing:border-box;"
    "padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}"
    "html{scroll-padding-top:env(safe-area-inset-top,0px)}"
    "body{margin:0;padding:0;font:14px -apple-system,BlinkMacSystemFont,sans-serif;background:#fff;color:#000}"
    "img{max-width:100%}[hidden]:not([hidden=until-found i]){display:none!important}</style>"
    "</head><body>\n"
)
(ROOT / "index.html").write_text(head + page.rstrip() + "\n</body></html>\n", encoding="utf-8")
print("index.html built")
