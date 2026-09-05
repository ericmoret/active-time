# active-time

## Why

I was handed a laptop dedicated to one consulting gig, billed by the hour.
Which meant timesheets — and timers you forget to start, forget to stop, or
just fudge at the end of the week.

Then it clicked: since the machine touches nothing but this work, *any*
time I'm interacting with it *is* billable time. macOS is already logging
every keystroke and trackpad touch to decide when to dim the screen. So
rather than tracking my time, I let the laptop do it — pull that log,
turn it into sessions, push it to a spreadsheet. That's this project.

## What it does

Computes voluntary computer interaction time from the macOS `pmset` power log,
tracks it to a CSV, and optionally keeps a Google Sheet in sync as a durable,
off-machine backup of your history.

- Parses `pmset -g log` for real keyboard/trackpad/lid HID activity (not
  background wake-ups, video playback, or other non-human triggers).
- Groups activity into sessions, merging gaps shorter than a configurable
  threshold (default 20 minutes).
- Flags sessions that fall on Tuesday–Thursday, 9 AM–6 PM as `[Office]`.
- Appends to the same CSV on every run instead of overwriting it, deduping
  and sorting so repeated runs against an overlapping log window never
  produce duplicate rows.
- Can run unattended once a day via `launchd`, and optionally push/pull the
  same data to a Google Sheet so your history survives a lost or replaced
  Mac.

## Contents

- [`active_time.py`](active_time.py) — the script.
- [`install.sh`](install.sh) — one-command setup: installs the script,
  Python dependencies, the launchd job, and (optionally) your Google
  service-account credential in Keychain.
- [`uninstall.sh`](uninstall.sh) — tears it back down.
- [`lib.sh`](lib.sh) — layout paths and small helpers shared by
  `install.sh`/`uninstall.sh`; not meant to be run directly.
- [`com.activetime.plist.template`](com.activetime.plist.template) — the
  launchd job definition, templated with real paths at install time.

## Requirements

- macOS — this monitors macOS's own `pmset` power log, plus `launchd` and
  Keychain for the scheduled sync, so none of it runs on other platforms.
  Tested on macOS 26.6.2.
- Python 3 (the system one at `/usr/bin/python3` is fine — no third-party
  packages needed for local-only use).
- A Google Cloud service account, **only if** you want the Google Sheet
  sync. Skip [that section](#set-up-google-sheet-sync-optional) entirely if
  you just want a local CSV.

## Quick start

```bash
git clone <this repo> && cd active-time
./install.sh
```

The installer:

1. Creates `~/bin`, `~/Library/Application Support/ActiveTime`,
   `~/Library/Logs/ActiveTime`, and `~/Library/LaunchAgents` if they don't
   exist.
2. Copies `active_time.py` into `~/bin` and migrates any CSV already sitting
   next to it in this folder, so a prior manual run's history isn't
   stranded.
3. Asks whether to set up Google Sheet sync now. Answer no and you get local
   CSV tracking only — nothing Sheets-related is installed or scheduled,
   and you can rerun the installer later to add it. Answer yes and it:
   - installs the `gspread`/`google-auth` Python packages,
   - prompts for your Google service-account JSON key path and stores its
     contents in Keychain,
   - prompts for the target Google Sheet ID (required) and tab name.
4. Prompts for which days count as office days and what your office hours
   are (default: Tue,Wed,Thu, 9:00-18:00) — sessions overlapping these get
   labeled `[Office]`.
5. Renders and loads the launchd job, scheduled for **8:00 AM daily** — or
   as soon as possible after, if your Mac was asleep or off at 8 AM.

Re-running `install.sh` is safe: it reinstalls the script/plist and reloads
the job.

## Set up Google Sheet sync (optional)

This is the one step that can't be automated — a service account is an
identity you have to create yourself in Google Cloud Console. Takes about
five minutes:

1. Go to the [Google Cloud Console](https://console.cloud.google.com/) and
   create a project (or pick an existing one).
2. **APIs & Services → Library** → search for **Google Sheets API** →
   Enable.
3. **APIs & Services → Credentials → Create Credentials → Service account**.
   Give it any name (e.g. `active-time-sync`) and finish the wizard — it
   doesn't need any project-level IAM role.
4. Open the new service account → **Keys** tab → **Add Key → Create new
   key → JSON**. This downloads a `.json` file — that's your credential.
5. Get your own copy of the [timesheet template](https://docs.google.com/spreadsheets/d/1TxOuZzwroCcdWhjEDlEd0j9zz5ZdOZaGnGrjRopAHdY/edit?gid=75883665#gid=75883665) — open it and **File → Make a copy** (the shared link itself isn't yours to write to). It already has a `CSV` tab laid out for the raw synced rows plus a dashboard tab with the session/daily/weekly/overtime formulas built on top. Or start from a blank sheet and build your own `CSV` tab if you'd rather.
6. **Share** that sheet with the service account's email address — it looks
   like `something@your-project.iam.gserviceaccount.com` (find it inside
   the downloaded JSON as `client_email`, or on the service account's
   details page) — as **Editor**. Without this share, every sync will fail
   with a permission error, since a service account has no Drive/Sheets
   access of its own.
7. Grab the Sheet's ID from its URL:
   `https://docs.google.com/spreadsheets/d/`**`THIS_PART`**`/edit`.
8. Run `./install.sh`, answer **y** when it asks about Sheet sync, then give
   it the path to the JSON key file downloaded in step 4 and the Sheet ID
   from step 7.

The JSON key is stored in macOS Keychain (service name
`ActiveTimeServiceAccount`) and is never written to disk anywhere else —
`active_time.py` reads it back at runtime via `security
find-generic-password`.

Once `install.sh` has stored it, **delete the downloaded `.json` key file** —
it's no longer needed (nothing reads from that path again) and leaving a
plaintext private key sitting in `~/Downloads` defeats the point of moving
it into Keychain in the first place. If you ever need it again (reinstalling
on another Mac, rotating the key), generate a fresh one from the same
service account (Cloud Console → Keys → Add Key → JSON) rather than trying
to recover the original — a service account can hold multiple valid keys at
once, so this doesn't disturb what's already stored in Keychain.

### Why a service account instead of your own Google login?

The job runs unattended once a day. A personal OAuth login would need a
one-time browser consent step and its refresh token can expire under an
unpublished ("Testing") OAuth consent screen — both a poor fit for a
background job with nobody watching. A service account authenticates
without any interactive step, ever.

### How the sync avoids losing history

Each run **pulls** the sheet's current rows, **merges** them with the local
CSV and this run's newly computed sessions, dedupes and sorts the result,
then **pushes** that merged set back to both the local CSV and the sheet.

That round-trip matters: it's what makes the sheet a real backup rather
than a one-way mirror. If you ever move to a new Mac with no local CSV at
all, the very first run reconstructs your full history from the sheet,
merged with whatever the new machine's `pmset` log currently has — nothing
is lost, no manual restore step required.

## Manual usage

Without any install, you can run it directly:

```bash
# Read the live system log
python3 active_time.py

# Read a saved log
python3 active_time.py my-pmset-snapshot.log

# Pipe one in
pmset -g log | python3 active_time.py

# Override the inactivity gap (minutes) or minimum session length
python3 active_time.py --gap 15 --min 5

# Also sync with a Google Sheet (requires the Keychain credential from install.sh)
python3 active_time.py --push-sheet --sheet-id <SHEET_ID> --sheet-tab CSV

# Skip CSV output entirely
python3 active_time.py --no-csv

# Override office days/hours (default: Tue,Wed,Thu, 9:00-18:00)
python3 active_time.py --office-days Mon,Tue,Wed,Thu,Fri --office-start 8am --office-end 5pm

# Override the day boundary used for grouping/reporting (default: 3:00 AM,
# so e.g. a 9 PM-2 AM session stays grouped with the evening it started
# instead of splitting into a new day right after midnight)
python3 active_time.py --day-start 4am

# Permanently clear all tracked history - local CSV and, with --push-sheet,
# the Sheet's tab - and exit. Prompts for confirmation unless -y/--yes is given.
python3 active_time.py --reset --push-sheet --sheet-id <SHEET_ID> --sheet-tab CSV
```

To capture a log snapshot for later/offline use:

```bash
pmset -g log > my-pmset-snapshot.log
```

A saved snapshot only reflects the machine it was captured on. If you're
reprocessing history for real tracking/billing purposes (e.g. after a
`--reset`), prefer the live log (no file argument) over an old saved
snapshot, so you don't end up syncing stale or wrong-machine data into your
CSV/Sheet.

## Where everything lives after install

| What | Location |
|---|---|
| Script | `~/bin/active_time.py` |
| Generated CSV | `~/Library/Application Support/ActiveTime/active_time.csv` |
| Credential | macOS Keychain, service `ActiveTimeServiceAccount` |
| Job log | `~/Library/Logs/ActiveTime/active_time.log` |
| Launch agent | `~/Library/LaunchAgents/com.activetime.agent.plist` |

## Checking on the scheduled job

```bash
# Confirm it's loaded
launchctl list | grep com.activetime.agent

# Run it right now, on demand
launchctl start com.activetime.agent

# Tail its output
tail -f ~/Library/Logs/ActiveTime/active_time.log
```

## Uninstalling

```bash
./uninstall.sh
```

Unloads the launchd job, removes the installed script and plist, and
deletes the Keychain item. Asks before touching your local CSV or logs —
your Google Sheet (if you used the sync) is never touched by the
uninstaller.

## How activity detection works

macOS logs a `UserIsActive` power-management assertion whenever real HID
input (keyboard, trackpad, lid) occurs, under several different actions —
`Created`, `TurnedOn`, `Summary` (a periodic heartbeat on a still-open
assertion), and `TimedOut`. `active_time.py` treats every one of these as a
timestamped "activity pulse," rather than only tracking `Created`/`TimedOut`
pairs by assertion ID — the latter approach misses real, continuous
activity whenever a brief sleep/wake blip (a few seconds of `Idle Sleep`
immediately followed by a `DarkWake`) intervenes, since the OS can log that
blip mid-assertion without a fresh `Created` event afterward. Pulses within
the inactivity gap of each other are merged into a single session.

## License

Personal-use script — adapt as you like.
