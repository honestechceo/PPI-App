# Honestech PPI

Pre-purchase inspection app for mobile mechanics: job schedule, a 70-point inspection checklist in field order, per-wheel tread and brake pad readings, buyer report, invoice with travel fees, PDF export, and backup/restore.

Live: https://honestechceo.github.io/PPI-App/

## Install on iPhone

1. Open the link above in **Safari**.
2. Tap the Share button, then **Add to Home Screen**.
3. Open it from the home screen icon. It runs full screen and works offline after the first load.

Data is stored on the phone, inside the installed app. Use **Settings → Backup & restore → Save backup file** and save to iCloud Drive regularly.

## Files

| File | What it is |
| --- | --- |
| `app.html` | The app itself (edit this one) |
| `build.py` | Wraps `app.html` into `index.html` with the home-screen icon and app settings |
| `index.html` | What GitHub Pages serves (generated, don't edit by hand) |
| `manifest.webmanifest`, `icons/` | Home-screen name and icons |
| `sw.js` | Offline support |

## Updating

Edit `app.html`, run `python3 build.py`, and commit both files. When you change `sw.js`, bump `VERSION` so phones pick up the new cache.
