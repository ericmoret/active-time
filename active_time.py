#!/usr/bin/env python3
"""
active_time.py - Compute voluntary computer interaction time from a macOS pmset log.

Usage:
    python3 active_time.py [pmset.log]
    pmset -g log | python3 active_time.py
    python3 active_time.py --gap 20   (override inactivity gap to 20 minutes)

The inactivity gap defaults to 20 minutes. A pause longer than that is treated
as a session break. Override with --gap.

Sessions overlapping office hours are labeled [Office] in the output.
Defaults to Tue-Thu, 9 AM-6 PM; override with --office-days/--office-start
/--office-end (e.g. --office-days Mon,Tue,Wed,Thu,Fri --office-start 8am
--office-end 5pm).

The CSV output is merged, not overwritten: each run reads whatever is
already at --csv, adds this run's sessions, drops exact duplicates, and
rewrites the file sorted by date/start_time. This makes it safe to run
repeatedly (e.g. via a scheduled launchd job) against a pmset log whose
window overlaps a previous run.

To capture a fresh log:
    pmset -g log > pmset.log
"""

import os
import re
import stat
import sys
import argparse
import subprocess
import csv
from dataclasses import dataclass
from datetime import datetime, timedelta, time


# ---------------------------------------------------------------------------
# pmset log parsing
# ---------------------------------------------------------------------------

HID_KEYS = [
    "lidopen",
    "AppleHIDKeyboard",
    "AppleMultitouch",
    "AppleMesaShim",
    "kernel.useractive",
]

TS_PAT = re.compile(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})\s+(\S+)\s+(.+)$')


def parse_events(lines):
    events = []
    for line in lines:
        m = TS_PAT.match(line.rstrip())
        if not m:
            continue
        ts_str, etype, detail = m.groups()
        try:
            ts = datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S %z")
        except ValueError:
            continue
        events.append((ts, etype.strip(), detail.strip()))
    return events


DURATION_PAT = re.compile(r'"\s+(\d{2}):(\d{2}):(\d{2})\s+id:')


def parse_event_duration(detail):
    """Parse the HH:MM:SS duration field pmset prints after the quoted
    detail string (e.g. '... eventType:11" 00:13:14  id:0x...')."""
    m = DURATION_PAT.search(detail)
    if not m:
        return timedelta(0)
    h, mnt, s = (int(g) for g in m.groups())
    return timedelta(hours=h, minutes=mnt, seconds=s)


def compute_intervals(events):
    """Turn each qualifying UserIsActive HID event into a zero-length activity
    pulse. Sessions fall out later via merge_intervals bucketing pulses that
    are within the inactivity gap of each other.

    Deliberately action-agnostic (Created/TurnedOn/Summary/TimedOut all count):
    a still-active assertion emits periodic "Summary" heartbeats rather than a
    fresh "Created", so tracking only Created/TimedOut pairs by assertion id
    misses ongoing activity whenever a brief sleep/wake blip (e.g. a few
    seconds of Idle Sleep before an immediate DarkWake) intervenes.

    A TimedOut event's own timestamp is when the assertion expired, not when
    activity last happened - its duration field is how long it had already
    been idle by then, so the real last-active moment is
    (timestamp - duration). Using the raw TimedOut timestamp as the pulse
    inflates every session's end by however long that particular timeout
    happened to be (seen ranging from seconds to over an hour in practice).
    """
    pulses = []
    for ts, etype, detail in events:
        if etype != "Assertions" or "UserIsActive" not in detail:
            continue
        if not any(k in detail for k in HID_KEYS):
            continue
        if "TimedOut" in detail:
            ts = ts - parse_event_duration(detail)
        pulses.append(ts)

    return sorted((ts, ts) for ts in pulses)


def merge_intervals(intervals, gap):
    merged = []
    for start, end in intervals:
        if merged and start - merged[-1][1] <= gap:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append([start, end])
    return merged


# ---------------------------------------------------------------------------
# Office hours detection
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class OfficeConfig:
    """Built once in main() from --office-days/--office-start/--office-end
    /--day-start and threaded explicitly into business_date(),
    session_location() and merge_office_sessions() below."""
    days: set        # weekday ints, Monday=0 (see WEEKDAY_ABBR)
    start: time
    end: time
    day_start: time  # see business_date()


WEEKDAY_ABBR = {
    "mon": 0, "monday": 0,
    "tue": 1, "tues": 1, "tuesday": 1,
    "wed": 2, "weds": 2, "wednesday": 2,
    "thu": 3, "thur": 3, "thurs": 3, "thursday": 3,
    "fri": 4, "friday": 4,
    "sat": 5, "saturday": 5,
    "sun": 6, "sunday": 6,
}


def parse_office_days(spec):
    """Parse a comma-separated weekday list like 'Tue,Wed,Thu' into the
    {0..6} (Monday=0) weekday-index set session_location() expects."""
    days = set()
    for part in spec.split(","):
        key = part.strip().lower()
        if not key:
            continue
        if key not in WEEKDAY_ABBR:
            raise ValueError(f"unrecognized weekday '{part.strip()}' (use Mon/Tue/Wed/.../Sun)")
        days.add(WEEKDAY_ABBR[key])
    return days


def business_date(dt, cfg):
    """Which calendar day a timestamp belongs to for grouping/reporting,
    given a day boundary at cfg.day_start (default 3 AM, overridable via
    --day-start) rather than midnight - so work spanning past midnight (e.g.
    9 PM-2 AM) stays grouped with the evening it started, instead of
    splitting into a new day right after midnight.
    """
    local = dt.astimezone()
    if local.time() < cfg.day_start:
        local -= timedelta(days=1)
    return local.date()


def parse_time_of_day(spec):
    """Parse a time-of-day like '9:00', '09:00', '9am', or '9:00 AM'."""
    spec = spec.strip().upper()
    for fmt in ("%H:%M", "%I:%M%p", "%I:%M %p", "%I%p", "%I %p"):
        try:
            return datetime.strptime(spec, fmt).time()
        except ValueError:
            continue
    raise ValueError(f"unrecognized time '{spec}' (use e.g. 9:00, 09:00, or 9am)")


def session_location(start_dt, end_dt, cfg):
    """Return 'Office' if the session overlaps office hours (cfg.days/
    cfg.start/cfg.end - configurable via --office-days/--office-start
    /--office-end, default Tue-Thu 9 AM-6 PM), else ''.

    A session is Office if it starts before office-end and ends after
    office-start.
    """
    local_start = start_dt.astimezone()
    local_end   = end_dt.astimezone()

    if local_start.weekday() not in cfg.days:
        return ""

    day = local_start.date()
    office_start = datetime.combine(day, cfg.start).astimezone()
    office_end   = datetime.combine(day, cfg.end).astimezone()

    if local_start < office_end and local_end > office_start:
        return "Office"
    return ""


def merge_office_sessions(sessions, cfg):
    """Collapse consecutive Office-labeled sessions on the same (business)
    day into one span.

    Returns (start, end, is_office) triples rather than plain (start, end)
    pairs, so callers (the by-date grouping and the print loop in main())
    can reuse is_office instead of each calling session_location() again for
    the same session.
    """
    result = []
    for start, end in sessions:
        is_office = session_location(start, end, cfg) == "Office"
        if (result and result[-1][2] and is_office
                and business_date(start, cfg) == business_date(result[-1][0], cfg)):
            result[-1] = (result[-1][0], max(result[-1][1], end), True)
        else:
            result.append((start, end, is_office))
    return result


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def fmt_duration(td):
    total = int(td.total_seconds())
    h, rem = divmod(total, 3600)
    m = rem // 60
    if h:
        return f"{h}h{m:02d}"
    return f"0h{m:02d}"


CSV_FIELDS = ["date", "start_time", "end_time"]

# Keychain item that holds the Google service-account JSON key used for the
# optional --push-sheet sync. Written once by install.sh; never touches disk.
KEYCHAIN_SERVICE = "ActiveTimeServiceAccount"

SHEETS_SCOPES = ["https://www.googleapis.com/auth/spreadsheets"]


def _normalize_date(value):
    """Coerce a date value into canonical ISO 'YYYY-MM-DD'. Rows read back
    from the Sheet should already be ISO (that's what USER_ENTERED settles
    on for cells written that way), but this stays defensive in case a
    locale/format setting ever renders it differently."""
    s = str(value).strip()
    for fmt in ("%Y-%m-%d", "%m/%d/%Y"):
        try:
            return datetime.strptime(s, fmt).date().isoformat()
        except ValueError:
            continue
    return s


def _normalize_time(value):
    """Coerce a time value into canonical 24-hour zero-padded 'HH:MM'.

    Rows we write ourselves are always already in this form. But rows read
    back from the Sheet via ws.get_all_records() come back as Sheets' own
    *formatted display* string for that cell - and since sync_with_sheet
    writes with value_input_option=USER_ENTERED, start_time/end_time land
    as real time-of-day values, which Sheets displays without a leading
    zero (e.g. "8:33", not "08:33"). Comparing that raw string against our
    "08:33" would treat the same real session as two different rows on
    every subsequent sync. strptime's %H is lenient about the missing
    digit, so re-parsing and re-formatting here normalizes both forms to
    the same key before rows are deduped.
    """
    s = str(value).strip()
    for fmt in ("%H:%M", "%H:%M:%S", "%I:%M %p", "%I:%M:%S %p"):
        try:
            return datetime.strptime(s, fmt).strftime("%H:%M")
        except ValueError:
            continue
    return s


def dedupe_sort_rows(rows):
    """Dedupe a list of row dicts (date/start_time/end_time) and sort
    chronologically. Callers combine rows from multiple sources (the
    existing local CSV, an existing Google Sheet, this run's freshly
    computed sessions) with `+` before calling this.

    date/start_time/end_time are normalized to sortable canonical form
    (ISO date, zero-padded 24-hour time) so rows from those different
    sources - including a Sheet's own re-formatted read-back - can be
    merged this way without ambiguity.
    """
    combined = {}
    for row in rows:
        date = _normalize_date(row["date"])
        start = _normalize_time(row["start_time"])
        end = _normalize_time(row["end_time"])
        key = (date, start, end)
        combined[key] = {"date": date, "start_time": start, "end_time": end}
    return sorted(combined.values(), key=lambda r: (r["date"], r["start_time"]))


def read_csv_rows(csv_path):
    if not os.path.exists(csv_path):
        return []
    with open(csv_path, newline="") as f:
        return list(csv.DictReader(f))


def write_csv_rows(csv_path, rows):
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def load_service_account_from_keychain(account=None):
    """Fetch the Google service-account JSON key from macOS Keychain.

    Stored there by install.sh via `security add-generic-password`, so the
    key material never sits on disk as a plaintext file.
    """
    import getpass
    account = account or os.environ.get("USER") or getpass.getuser()
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-a", account, "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, check=True,
        )
    except FileNotFoundError:
        raise RuntimeError("'security' command not found - this only works on macOS.")
    except subprocess.CalledProcessError:
        raise RuntimeError(
            f"No '{KEYCHAIN_SERVICE}' Keychain item found for account '{account}'. "
            "Run install.sh to store your Google service-account key first."
        )

    raw = result.stdout.strip()
    # `security -w` prints hex instead of raw text for values it doesn't
    # treat as a clean printable string, which a multi-line JSON key file
    # can trigger - sometimes prefixed with "0x", sometimes bare hex digits.
    hex_candidate = raw[2:] if raw.startswith("0x") else raw
    if hex_candidate and len(hex_candidate) % 2 == 0 and all(c in "0123456789abcdefABCDEF" for c in hex_candidate):
        raw = bytes.fromhex(hex_candidate).decode("utf-8")

    import json
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        raise RuntimeError(
            f"Keychain item '{KEYCHAIN_SERVICE}' did not contain valid JSON ({e}). "
            "Re-run install.sh and re-enter your service-account key."
        )


def get_sheets_worksheet(sheet_id, tab_name):
    try:
        import gspread
        from google.oauth2.service_account import Credentials
    except ImportError:
        raise RuntimeError(
            "gspread/google-auth not installed. Run: "
            "python3 -m pip install --user gspread google-auth"
        )

    creds_info = load_service_account_from_keychain()
    creds = Credentials.from_service_account_info(creds_info, scopes=SHEETS_SCOPES)
    client = gspread.authorize(creds)
    sh = client.open_by_key(sheet_id)
    try:
        return sh.worksheet(tab_name)
    except gspread.WorksheetNotFound:
        return sh.add_worksheet(title=tab_name, rows=1000, cols=len(CSV_FIELDS))


def sync_with_sheet(csv_path, sheet_id, tab_name, new_rows):
    """Pull the sheet's current rows, merge with the local CSV and this
    run's new rows, then push the reconciled set back to both the local
    CSV and the sheet.

    Pulling before pushing (rather than a blind overwrite) is what makes the
    sheet a real off-machine backup of full history: on a machine with no
    local CSV at all (e.g. after switching computers), this reconstructs it
    from whatever the sheet already has, merged with newly computed
    sessions, instead of the sheet's history being clobbered by a bare/empty
    local start.
    """
    ws = get_sheets_worksheet(sheet_id, tab_name)
    sheet_rows = ws.get_all_records()
    local_rows = read_csv_rows(csv_path)

    all_rows = dedupe_sort_rows(local_rows + sheet_rows + new_rows)

    write_csv_rows(csv_path, all_rows)

    # clear() first: all_rows can be *smaller* than what's currently on the
    # sheet - e.g. deduping collapses old format-mismatched duplicate rows -
    # so update() overwriting from A1 alone can leave stale rows sitting
    # below the new, shorter block. (Previously this skipped clear() on the
    # assumption row count only ever grows; that assumption was wrong.)
    ws.clear()
    # USER_ENTERED (rather than gspread's default RAW) makes Sheets parse
    # these the way it would if you'd typed them into a cell - so the date
    # column becomes a real date value and the time columns become real
    # time values, instead of plain text marked with a leading '.
    ws.update(
        [CSV_FIELDS] + [[row[field] for field in CSV_FIELDS] for row in all_rows],
        value_input_option="USER_ENTERED",
    )

    return all_rows


def do_reset(args):
    """Permanently clear all tracked history: the local CSV and, if
    --push-sheet is set, the Sheet's tab too. Both sides need clearing -
    sync_with_sheet() pulls from whichever side still has data, so clearing
    only one just gets it repopulated on the next run.
    """
    targets = [f"local CSV ({args.csv})"]
    if args.push_sheet:
        targets.append(f"Google Sheet tab '{args.sheet_tab}' ({args.sheet_id})")

    if not args.yes:
        print("This will permanently clear:")
        for t in targets:
            print(f"  - {t}")
        reply = input("Type 'yes' to continue: ").strip().lower()
        if reply != "yes":
            print("Aborted.")
            sys.exit(1)

    if os.path.exists(args.csv):
        os.remove(args.csv)
        print(f"Removed {args.csv}")
    else:
        print(f"{args.csv} did not exist - nothing to remove.")

    if args.push_sheet:
        try:
            ws = get_sheets_worksheet(args.sheet_id, args.sheet_tab)
            ws.clear()
            print(f"Cleared Google Sheet tab '{args.sheet_tab}'")
        except RuntimeError as e:
            print(f"Could not clear Google Sheet: {e}", file=sys.stderr)
            sys.exit(1)

    print("Reset complete.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Compute voluntary interaction time from pmset log.")
    parser.add_argument("logfile", nargs="?", help="Path to pmset log (default: auto-run pmset -g log)")
    parser.add_argument("--gap", type=int, default=20,
                        help="Minutes of inactivity to still count as one session (default: 20)")
    parser.add_argument("--min", type=int, default=1, dest="min_duration",
                        help="Minimum session duration in minutes to include (default: 1)")
    parser.add_argument("--csv", metavar="FILE", nargs="?", const="active_time.csv",
                        default="active_time.csv",
                        help="CSV output path (default: active_time.csv)")
    parser.add_argument("--no-csv", action="store_true", help="Skip CSV output")
    parser.add_argument("--push-sheet", action="store_true",
                        help="Also sync with a Google Sheet: pull its rows, merge with "
                             "the local CSV and this run's sessions, push the result back "
                             "to both (see --sheet-id/--sheet-tab)")
    parser.add_argument("--sheet-id", default=None,
                        help="Google Sheet ID to sync with (required when --push-sheet is set)")
    parser.add_argument("--sheet-tab", default="CSV",
                        help="Worksheet/tab name within the sheet (default: CSV)")
    parser.add_argument("--reset", action="store_true",
                        help="Permanently clear all tracked history - the local CSV, and "
                             "(if --push-sheet is also given) the Sheet's tab - then exit "
                             "without processing any log. Irreversible.")
    parser.add_argument("-y", "--yes", action="store_true",
                        help="Skip the confirmation prompt for --reset")
    parser.add_argument("--office-days", default="Tue,Wed,Thu",
                        help="Comma-separated weekdays counted as office days (default: Tue,Wed,Thu)")
    parser.add_argument("--office-start", default="9:00",
                        help="Office hours start time, e.g. 9:00 or 9am (default: 9:00)")
    parser.add_argument("--office-end", default="18:00",
                        help="Office hours end time, e.g. 18:00 or 6pm (default: 18:00)")
    parser.add_argument("--day-start", default="3:00",
                        help="Day boundary for grouping/reporting - activity before this "
                             "local time counts as the previous day (default: 3:00, i.e. "
                             "work that runs past midnight stays grouped with the evening "
                             "it started)")
    args = parser.parse_args()

    if args.push_sheet and not args.sheet_id:
        parser.error("--sheet-id is required when --push-sheet is set")

    try:
        cfg = OfficeConfig(
            days=parse_office_days(args.office_days),
            start=parse_time_of_day(args.office_start),
            end=parse_time_of_day(args.office_end),
            day_start=parse_time_of_day(args.day_start),
        )
    except ValueError as e:
        parser.error(str(e))

    if args.reset:
        do_reset(args)
        return

    try:
        stdin_mode = os.fstat(sys.stdin.fileno()).st_mode
        stdin_has_data = stat.S_ISFIFO(stdin_mode) or stat.S_ISREG(stdin_mode)
    except OSError:
        stdin_has_data = False

    if args.logfile:
        with open(args.logfile) as f:
            lines = f.readlines()
    elif stdin_has_data:
        lines = sys.stdin.readlines()
    else:
        print("Reading pmset log from system...", flush=True)
        try:
            result = subprocess.check_output(["pmset", "-g", "log"], text=True, timeout=30)
            lines = result.splitlines(keepends=True)
        except FileNotFoundError:
            print("Error: pmset not found. Are you on macOS?", file=sys.stderr)
            sys.exit(1)
        except subprocess.TimeoutExpired:
            print("Error: pmset -g log timed out.", file=sys.stderr)
            sys.exit(1)

    events = parse_events(lines)
    if not events:
        print("No parseable events found.")
        sys.exit(1)

    intervals = compute_intervals(events)
    if not intervals:
        print("No UserIsActive HID events found in this log.")
        sys.exit(1)

    gap = timedelta(minutes=args.gap)
    min_duration = timedelta(minutes=args.min_duration)
    sessions = merge_intervals(intervals, gap)
    sessions = [(s, e) for s, e in sessions if e - s >= min_duration]
    sessions = merge_office_sessions(sessions, cfg)

    # Group by date
    by_date = {}
    for start, end, is_office in sessions:
        by_date.setdefault(business_date(start, cfg), []).append((start, end, is_office))

    print(f"\nVoluntary interaction time  (ignoring gaps < {args.gap} min)\n")

    csv_rows = []
    grand_total = timedelta()
    for date, day_sessions in sorted(by_date.items()):
        day_total = timedelta()
        date_str = date.strftime("%a, %b %-d")
        print(f"  {date_str}")
        for start, end, is_office in day_sessions:
            dur = end - start
            day_total += dur
            start_str = start.strftime("%-I:%M %p")
            end_str   = end.strftime("%-I:%M %p")
            loc_label = "  [Office]" if is_office else ""
            print(f"    {start_str} - {end_str}  {fmt_duration(dur)}{loc_label}")
            csv_rows.append({
                "date":       date.isoformat(),
                "start_time": start.strftime("%H:%M"),
                "end_time":   end.strftime("%H:%M"),
            })
        print(f"    Day total: {fmt_duration(day_total)}\n")
        grand_total += day_total

    if len(by_date) > 1:
        print(f"  Grand total: {fmt_duration(grand_total)}")
    else:
        print(f"  Total: {fmt_duration(grand_total)}")

    if not args.no_csv:
        if args.push_sheet:
            try:
                all_rows = sync_with_sheet(args.csv, args.sheet_id, args.sheet_tab, csv_rows)
            except RuntimeError as e:
                print(f"\n  Sheet sync failed: {e}", file=sys.stderr)
                sys.exit(1)
            print(f"\n  CSV + Google Sheet synced ({len(all_rows)} total rows)")
        else:
            all_rows = dedupe_sort_rows(read_csv_rows(args.csv) + csv_rows)
            write_csv_rows(args.csv, all_rows)
            print(f"\n  CSV written to {args.csv} ({len(all_rows)} total rows)")


if __name__ == "__main__":
    main()
