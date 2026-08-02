#!/usr/bin/python3
"""Collects everything the sketchybar Claude popup shows.

Three independent sources, each cached separately so a slow one never blocks
the others:

  plan    `claude auth status --json`      -- subscription vs API key
  limits  the OAuth usage endpoint          -- session / weekly percentages
  tokens  ~/.claude/projects/**/*.jsonl     -- tokens by day and by model

Output is flat `key=value` lines for the Lua side to parse. Anything that
cannot be determined is simply omitted, and the popup hides that section.

Usage:
  claude_usage.py            emit key=value snapshot (cached)
  claude_usage.py --probe    dump the raw limits response, for debugging
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone

HOME = os.path.expanduser("~")
CACHE_DIR = os.path.join(HOME, ".cache", "sketchybar", "claude")
CLAUDE_DIR = os.path.join(HOME, ".claude")

TTL_PLAN = 600
TTL_LIMITS = 60
TTL_TOKENS = 900

DAYS = 7
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"


# --------------------------------------------------------------------------
# cache
# --------------------------------------------------------------------------

def cached(name, ttl, produce):
    """Return produce(), memoised on disk for `ttl` seconds.

    On failure the previous value is reused if there is one, so a transient
    network blip does not blank out the popup.
    """
    path = os.path.join(CACHE_DIR, name + ".json")
    try:
        st = os.stat(path)
        if time.time() - st.st_mtime < ttl:
            with open(path) as fh:
                return json.load(fh)
    except (OSError, ValueError):
        pass

    try:
        value = produce()
    except Exception:
        value = None

    if value is None:
        try:
            with open(path) as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return None

    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(value, fh)
        os.replace(tmp, path)
    except OSError:
        pass
    return value


# --------------------------------------------------------------------------
# plan
# --------------------------------------------------------------------------

def which_claude():
    for p in ("/opt/homebrew/bin/claude", "/usr/local/bin/claude",
              os.path.join(HOME, ".local/bin/claude")):
        if os.access(p, os.X_OK):
            return p
    return None


def fetch_plan():
    exe = which_claude()
    if not exe:
        return None
    out = subprocess.run([exe, "auth", "status", "--json"],
                         capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        return None
    return json.loads(out.stdout)


PLAN_NAMES = {
    "pro": "Pro",
    "max": "Max",
    "max_5x": "Max 5x",
    "max_20x": "Max 20x",
    "team": "Team",
    "enterprise": "Enterprise",
}


# --------------------------------------------------------------------------
# limits
# --------------------------------------------------------------------------

def oauth_token():
    """Read the local OAuth access token: keychain first, then the file."""
    try:
        out = subprocess.run(
            ["/usr/bin/security", "find-generic-password",
             "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=10)
        if out.returncode == 0:
            tok = json.loads(out.stdout)["claudeAiOauth"]["accessToken"]
            if tok:
                return tok
    except Exception:
        pass
    try:
        with open(os.path.join(CLAUDE_DIR, ".credentials.json")) as fh:
            return json.load(fh)["claudeAiOauth"]["accessToken"]
    except Exception:
        return None


def fetch_limits_raw():
    tok = oauth_token()
    if not tok:
        return None
    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": "Bearer " + tok,
        "anthropic-beta": "oauth-2025-04-20",
        "Content-Type": "application/json",
        "User-Agent": "sketchybar-claude-widget",
    })
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode())


def pick_window(raw, *needles):
    """Find the sub-object describing a rate-limit window.

    The payload groups limits under keys like `five_hour` / `seven_day`; this
    matches loosely so a rename upstream degrades to a hidden row rather than
    a wrong number.
    """
    if not isinstance(raw, dict):
        return None
    for key, val in raw.items():
        k = key.lower()
        if not isinstance(val, dict):
            continue
        if any(n in k for n in needles):
            # Prefer the plain window over per-model variants (…_opus).
            return val
    return None


def as_percent(val):
    if not isinstance(val, (int, float)):
        return None
    pct = val * 100.0 if 0.0 <= val <= 1.0 else float(val)
    return max(0, min(100, int(round(pct))))


def window_percent(win):
    if not isinstance(win, dict):
        return None
    for key in ("utilization", "percent_used", "percentage", "used_percent"):
        pct = as_percent(win.get(key))
        if pct is not None:
            return pct
    used, limit = win.get("used"), win.get("limit")
    if isinstance(used, (int, float)) and isinstance(limit, (int, float)) and limit:
        return max(0, min(100, int(round(used / limit * 100))))
    return None


def window_reset(win):
    if not isinstance(win, dict):
        return None
    for key in ("resets_at", "reset_at", "resets", "expires_at"):
        val = win.get(key)
        if val is None:
            continue
        try:
            if isinstance(val, (int, float)):
                when = datetime.fromtimestamp(val, timezone.utc)
            else:
                when = datetime.fromisoformat(str(val).replace("Z", "+00:00"))
        except (ValueError, OSError):
            continue
        return humanize_delta(when - datetime.now(timezone.utc))
    return None


def humanize_delta(delta):
    secs = int(delta.total_seconds())
    if secs <= 0:
        return "now"
    days, rem = divmod(secs, 86400)
    hours, rem = divmod(rem, 3600)
    mins = rem // 60
    if days:
        return "%dd %dh" % (days, hours)
    if hours:
        return "%dh %dm" % (hours, mins)
    return "%dm" % max(mins, 1)


# --------------------------------------------------------------------------
# tokens
# --------------------------------------------------------------------------

MODEL_PATTERNS = [
    (re.compile(r"opus-?4[._-]8"), "Opus 4.8"),
    (re.compile(r"opus-?4[._-]7"), "Opus 4.7"),
    (re.compile(r"opus-?5"), "Opus 5"),
    (re.compile(r"sonnet-?5"), "Sonnet 5"),
    (re.compile(r"fable-?5"), "Fable 5"),
    (re.compile(r"haiku-?4[._-]5"), "Haiku 4.5"),
    (re.compile(r"opus"), "Opus"),
    (re.compile(r"sonnet"), "Sonnet"),
    (re.compile(r"haiku"), "Haiku"),
]


def pretty_model(model):
    m = (model or "").lower()
    if not m or m == "<synthetic>":
        return None
    for pat, name in MODEL_PATTERNS:
        if pat.search(m):
            return name
    return model


def total_tokens(usage):
    return (usage.get("input_tokens", 0)
            + usage.get("output_tokens", 0)
            + usage.get("cache_creation_input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0))


def fetch_tokens():
    """Aggregate token counts from the last DAYS days of transcripts.

    Transcripts run to tens of megabytes, so lines are cheaply pre-filtered on
    a substring before paying for json.loads -- only assistant turns carry a
    requestId, and only those hold usage.
    """
    root = os.path.join(CLAUDE_DIR, "projects")
    if not os.path.isdir(root):
        return None

    today = datetime.now().date()
    oldest = today - timedelta(days=DAYS - 1)
    cutoff = time.time() - (DAYS + 1) * 86400

    by_day = defaultdict(int)
    by_model = defaultdict(int)
    seen = {}

    for dirpath, _, files in os.walk(root):
        for fname in files:
            if not fname.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, fname)
            try:
                if os.stat(path).st_mtime < cutoff:
                    continue
                fh = open(path, "r", errors="replace")
            except OSError:
                continue
            with fh:
                for line in fh:
                    if '"requestId"' not in line:
                        continue
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    if rec.get("type") != "assistant":
                        continue
                    msg = rec.get("message") or {}
                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    # One request can span several assistant records; the usage
                    # on each restates the request total, so keep it once.
                    rid = rec.get("requestId")
                    key = (path, rid) if rid else (path, rec.get("uuid"))
                    if key in seen:
                        continue
                    seen[key] = True

                    try:
                        when = datetime.fromisoformat(
                            str(rec.get("timestamp", "")).replace("Z", "+00:00"))
                    except ValueError:
                        continue
                    day = when.astimezone().date()
                    if day < oldest or day > today:
                        continue

                    tokens = total_tokens(usage)
                    if tokens <= 0:
                        continue
                    by_day[day.isoformat()] += tokens
                    name = pretty_model(msg.get("model"))
                    if name:
                        by_model[name] += tokens

    days = []
    for i in range(DAYS):
        day = oldest + timedelta(days=i)
        label = "Today" if day == today else day.strftime("%a")
        days.append({"label": label, "tokens": by_day.get(day.isoformat(), 0)})

    models = sorted(by_model.items(), key=lambda kv: -kv[1])[:5]
    return {"days": days, "models": [{"label": n, "tokens": t} for n, t in models]}


def human_tokens(n):
    if n >= 1_000_000_000:
        return "%.1fB" % (n / 1_000_000_000)
    if n >= 1_000_000:
        return "%.1fM" % (n / 1_000_000)
    if n >= 1_000:
        return "%.1fK" % (n / 1_000)
    return str(n)


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------

def emit(out, key, value):
    out.append("%s=%s" % (key, value))


def main():
    if "--probe" in sys.argv:
        try:
            print(json.dumps(fetch_limits_raw(), indent=2))
        except urllib.error.HTTPError as exc:
            print("HTTP %s: %s" % (exc.code, exc.read().decode()[:500]))
        except Exception as exc:
            print("error: %r" % (exc,))
        return

    out = []

    plan = cached("plan", TTL_PLAN, fetch_plan) or {}
    subscription = plan.get("subscriptionType")
    on_subscription = bool(plan.get("loggedIn")) and plan.get("authMethod") == "claude.ai"
    emit(out, "logged_in", "1" if plan.get("loggedIn") else "0")
    emit(out, "subscribed", "1" if on_subscription else "0")
    if on_subscription and subscription:
        emit(out, "plan", PLAN_NAMES.get(subscription, subscription.replace("_", " ").title()))
    elif plan.get("loggedIn"):
        emit(out, "plan", "API")

    # Limits only mean anything on a subscription; API-key users are billed.
    if on_subscription:
        raw = cached("limits", TTL_LIMITS, fetch_limits_raw)
        session = pick_window(raw, "five_hour", "session")
        weekly = pick_window(raw, "seven_day", "week")
        shown = 0
        for name, win in (("session", session), ("weekly", weekly)):
            pct = window_percent(win)
            if pct is None:
                continue
            shown += 1
            emit(out, name + "_pct", pct)
            reset = window_reset(win)
            if reset:
                emit(out, name + "_reset", reset)
        emit(out, "limits", "1" if shown else "0")
    else:
        emit(out, "limits", "0")

    tokens = cached("tokens", TTL_TOKENS, fetch_tokens)
    if tokens:
        days = tokens["days"]
        peak = max((d["tokens"] for d in days), default=0) or 1
        for i, day in enumerate(days, 1):
            emit(out, "day.%d" % i, "%s|%s|%d" % (
                day["label"], human_tokens(day["tokens"]),
                round(day["tokens"] / peak * 100)))
        emit(out, "days", len(days))

        models = tokens["models"]
        mpeak = max((m["tokens"] for m in models), default=0) or 1
        for i, model in enumerate(models, 1):
            emit(out, "model.%d" % i, "%s|%s|%d" % (
                model["label"], human_tokens(model["tokens"]),
                round(model["tokens"] / mpeak * 100)))
        emit(out, "models", len(models))
    else:
        emit(out, "days", 0)
        emit(out, "models", 0)

    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
