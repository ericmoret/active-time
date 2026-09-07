# active-time — setup & reference

*(This is the technical reference. For the plain-English version, see [`README.md`](README.md).)*

## Requirements

- macOS — this monitors macOS's own `pmset` power log, plus `launchd` and Keychain for the scheduled sync, so none of it runs on other platforms. Tested on macOS 26.6.2.
- Python 3 (the system one at `/usr/bin/python3` is fine — no third-party packages needed for local-only use).
- For the Google Sheet sync **only**: a Google Cloud service account, plus the `gspread` and `google-auth` Python packages — `install.sh` installs both automatically when you opt in, no manual `pip install` needed. Skip [that section](#set-up-google-sheet-sync-optional) entirely if you just want a local CSV.

## Set up Google Sheet sync (optional)

Skip this section entirely if you just want a local CSV — continue straight to [Installing](#installing) below.

1. Go to the [Google Cloud Console](https://console.cloud.google.com/) and create a project (or pick an existing one).
2. **APIs & Services → Library** → search for **Google Sheets API** → Enable.
3. **APIs & Services → Credentials → Create Credentials → Service account**. Give it any name (e.g. `active-time-sync`) and finish the wizard — it doesn't need any project-level IAM role.
4. Open the new service account → **Keys** tab → **Add Key → Create new key → JSON**. This downloads a `.json` file — that's your credential.
5. Get your own copy of the [timesheet template](https://docs.google.com/spreadsheets/d/1TxOuZzwroCcdWhjEDlEd0j9zz5ZdOZaGnGrjRopAHdY/edit?gid=75883665#gid=75883665) — open it and **File → Make a copy** (the shared link itself isn't yours to write to). It already has a `CSV` tab laid out for the raw synced rows plus a dashboard tab with the session/daily/weekly/overtime formulas built on top. Or start from a blank sheet and build your own `CSV` tab if you'd rather.
6. **Share** that sheet with the service account's email address — it looks like `something@your-project.iam.gserviceaccount.com` (find it inside the downloaded JSON as `client_email`, or on the service account's details page) — as **Editor**. Without this share, every sync will fail with a permission error, since a service account has no Drive/Sheets access of its own.
7. Grab the Sheet's ID from its URL: `https://docs.google.com/spreadsheets/d/`**`THIS_PART`**`/edit`.
8. Continue to [Installing](#installing) below. When `./install.sh` asks about Sheet sync, answer **y** and give it the JSON key file path from step 4 and the Sheet ID from step 7.

The JSON key is stored in macOS Keychain (service name `ActiveTimeServiceAccount`) and is never written to disk anywhere else — `active_time.py` reads it back at runtime via `security find-generic-password`.

Once `install.sh` has stored it, **delete the downloaded `.json` key file** — it's no longer needed (nothing reads from that path again) and leaving a plaintext private key sitting in `~/Downloads` defeats the point of moving it into Keychain in the first place. If you ever need it again (reinstalling on another Mac, rotating the key), generate a fresh one from the same service account (Cloud Console → Keys → Add Key → JSON) rather than trying to recover the original — a service account can hold multiple valid keys at once, so this doesn't disturb what's already stored in Keychain.

## Installing

```bash
curl -fsSL https://github.com/ericmoret/active-time/archive/refs/heads/master.tar.gz | tar xz
cd active-time-master
./install.sh
```

It'll ask a few questions (Google Sheet sync, office hours) and is safe to re-run anytime to change your answers.

## Where everything lives after install

| What | Location |
|---|---|
| Script | `~/bin/active_time.py` |
| Generated CSV | `~/Library/Application Support/ActiveTime/active_time.csv` |
| Credential | macOS Keychain, service `ActiveTimeServiceAccount` |
| Job log | `~/Library/Logs/ActiveTime/active_time.log` |
| Launch agent | `~/Library/LaunchAgents/com.activetime.agent.plist` |

## Uninstalling

From a checkout (the same one you installed from, or a fresh one — same tarball command as Installing):

```bash
./uninstall.sh
```

Unloads the launchd job, removes the installed script and plist, and deletes the Keychain item. Asks before touching your local CSV or logs — your Google Sheet (if you used the sync) is never touched by the uninstaller. Safe to run again afterward — it just finds nothing left to remove.

It does not uninstall the `gspread`/`google-auth` Python packages.

## Manual usage

Without any install, you can run it directly.

Read the live system log and update `active_time.csv`:

```bash
python3 active_time.py
```

Read a saved log and update `active_time.csv`:

```bash
python3 active_time.py my-pmset-snapshot.log
```

Pipe one in and update `active_time.csv`:

```bash
pmset -g log | python3 active_time.py
```

Override the inactivity gap (minutes) or minimum session length, and update `active_time.csv`:

```bash
python3 active_time.py --gap 15 --min 5
```

Also sync with a Google Sheet, updating both `active_time.csv` and the Sheet — requires the Keychain credential from `install.sh`:

```bash
python3 active_time.py --push-sheet --sheet-id YOUR_SHEET_ID --sheet-tab CSV
```

Skip CSV output entirely, so `active_time.csv` is not updated:

```bash
python3 active_time.py --no-csv
```

Override office days/hours (default: `Tue,Wed,Thu`, `9:00`-`18:00`) and update `active_time.csv`:

```bash
python3 active_time.py --office-days Mon,Tue,Wed,Thu,Fri --office-start 8am --office-end 5pm
```

Override the day boundary used for grouping/reporting (default: 3:00 AM, so e.g. a 9 PM-2 AM session stays grouped with the evening it started instead of splitting into a new day right after midnight), and update `active_time.csv`:

```bash
python3 active_time.py --day-start 4am
```

Permanently clear all tracked history — local CSV and, with `--push-sheet`, the Sheet's tab — and exit. Prompts for confirmation unless `-y`/`--yes` is given:

```bash
python3 active_time.py --reset --push-sheet --sheet-id YOUR_SHEET_ID --sheet-tab CSV
```

To capture a log snapshot for later/offline use:

```bash
pmset -g log > my-pmset-snapshot.log
```

A saved snapshot only reflects the machine it was captured on. If you're reprocessing history for real tracking/billing purposes (e.g. after a `--reset`), prefer the live log (no file argument) over an old saved snapshot, so you don't end up syncing stale or wrong-machine data into your CSV/Sheet.

## Checking on the scheduled job

Confirm it's loaded:

```bash
launchctl list | grep com.activetime.agent
```

Run it right now, on demand:

```bash
launchctl start com.activetime.agent
```

Tail its output:

```bash
tail -f ~/Library/Logs/ActiveTime/active_time.log
```

## How activity detection works

macOS logs a `UserIsActive` power-management assertion whenever real HID input (keyboard, trackpad, lid) occurs, under several different actions — `Created`, `TurnedOn`, `Summary` (a periodic heartbeat on a still-open assertion), and `TimedOut`. `active_time.py` treats every one of these as a timestamped "activity pulse," rather than only tracking `Created`/`TimedOut` pairs by assertion ID — the latter approach misses real, continuous activity whenever a brief sleep/wake blip (a few seconds of `Idle Sleep` immediately followed by a `DarkWake`) intervenes, since the OS can log that blip mid-assertion without a fresh `Created` event afterward. Pulses within the inactivity gap of each other are merged into a single session.

## License

[MIT](LICENSE).
