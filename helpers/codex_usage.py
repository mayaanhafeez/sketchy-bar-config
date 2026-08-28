#!/usr/bin/env python3
"""Emit recent OpenCode token totals for the SketchyBar Codex popup."""

import base64
import os
import sqlite3
import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from urllib.request import Request, urlopen
from urllib.error import HTTPError

HOME = os.path.expanduser("~")
DATABASE = os.path.join(HOME, ".local", "share", "opencode", "opencode.db")
DAYS = 7


def human_duration(seconds):
    seconds = max(int(seconds or 0), 0)
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes = seconds // 60
    if days:
        return "%dd %dh" % (days, hours)
    if hours:
        return "%dh %dm" % (hours, minutes)
    return "%dm" % max(minutes, 1)


# The usage endpoint reports one window per cap Codex enforces: the rolling
# 5-hour window in primary_window, the weekly one in secondary_window. Both are
# keyed off limit_window_seconds rather than the field name, so a window that
# moves between the two slots still lands on the right row.
LIMIT_WINDOWS = (("session", 18000), ("weekly", 604800))

# ChatGPT OAuth token refresh, mirroring the Codex CLI's own refresh flow.
# The client id is a public PKCE client identifier (not a secret).
REFRESH_TOKEN_URL = "https://auth.openai.com/oauth/token"
REFRESH_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"


def refresh_auth():
    """Exchange the stored refresh_token for fresh tokens and rewrite auth.json.

    Returns True on success. On any failure the on-disk auth.json is left
    untouched so the caller can fall back to the existing (stale) token.
    """
    auth_path = os.path.join(HOME, ".codex", "auth.json")
    try:
        with open(auth_path) as handle:
            auth = json.load(handle)
        refresh_token = auth["tokens"]["refresh_token"]
    except (OSError, KeyError, TypeError, ValueError):
        return False

    payload = {
        "client_id": REFRESH_CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    }
    request = Request(
        REFRESH_TOKEN_URL,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=10) as response:
            tokens = json.load(response)
    except (OSError, ValueError):
        return False

    # The endpoint may omit fields that did not change (token rotation), so
    # merge rather than overwrite. Always keep the previous refresh_token as a
    # fallback in case the response left it out.
    updated = dict(auth["tokens"])
    for key in ("access_token", "id_token", "refresh_token"):
        if tokens.get(key):
            updated[key] = tokens[key]
    if not updated.get("refresh_token"):
        updated["refresh_token"] = refresh_token

    auth["tokens"] = updated
    auth["last_refresh"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    try:
        with open(auth_path, "w") as handle:
            json.dump(auth, handle, indent=2)
    except OSError:
        return False
    return True


def fetch_limits():
    """Return {name: (used_percent, reset_after_seconds)} for each known cap."""
    for attempt in range(2):
        try:
            with open(os.path.join(HOME, ".codex", "auth.json")) as handle:
                auth = json.load(handle)
            token = auth["tokens"]["access_token"]
            account = auth["tokens"].get("account_id")
            headers = {"Authorization": "Bearer " + token}
            if account:
                headers["ChatGPT-Account-Id"] = account
            request = Request("https://chatgpt.com/backend-api/wham/usage", headers=headers)
            with urlopen(request, timeout=10) as response:
                rate_limit = json.load(response)["rate_limit"]
        except HTTPError as error:
            # The access token expired: refresh it from the refresh_token and
            # retry once with the new token before giving up.
            if error.code == 401 and attempt == 0 and refresh_auth():
                continue
            return {}
        except (OSError, KeyError, TypeError, ValueError):
            return {}

        windows = []
        for key in ("primary_window", "secondary_window"):
            window = rate_limit.get(key)
            if isinstance(window, dict) and window.get("used_percent") is not None:
                windows.append(window)

        limits = {}
        for name, span in LIMIT_WINDOWS:
            if not windows:
                break
            # Nearest window length wins, so an exact match is picked even when the
            # API reports a slightly different span than the documented one.
            window = min(windows, key=lambda w: abs((w.get("limit_window_seconds") or 0) - span))
            windows.remove(window)
            limits[name] = (window.get("used_percent"), window.get("reset_after_seconds"))
        return limits
    return {}


def fetch_plan():
    """Read the ChatGPT plan name out of the cached auth id_token.

    The claim payload is only decoded, never verified -- it is trusted local
    state written by the Codex CLI itself.
    """
    try:
        with open(os.path.join(HOME, ".codex", "auth.json")) as handle:
            token = json.load(handle)["tokens"]["id_token"]
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
        plan = (claims.get("https://api.openai.com/auth") or {}).get("chatgpt_plan_type")
        return plan.replace("_", " ").title() if plan else None
    except (OSError, KeyError, IndexError, AttributeError, TypeError, ValueError):
        return None


def human_tokens(tokens):
    if tokens >= 1_000_000:
        return "%.1fM" % (tokens / 1_000_000)
    if tokens >= 1_000:
        return "%.1fK" % (tokens / 1_000)
    return str(tokens)


def display_model(model):
    try:
        parsed = json.loads(model)
        if isinstance(parsed, dict):
            return parsed.get("id") or model
    except (TypeError, ValueError):
        pass
    return model


def main():
    plan = fetch_plan()
    if plan:
        print("plan=%s" % plan)

    for name, (percent, reset) in fetch_limits().items():
        if percent is not None:
            print("%s_pct=%d" % (name, round(percent)))
        if reset is not None:
            print("%s_reset=%s" % (name, human_duration(reset)))

    if not os.path.isfile(DATABASE):
        print("days=0\nmodels=0")
        return

    today = datetime.now().date()
    oldest = today - timedelta(days=DAYS - 1)
    by_day = defaultdict(int)
    by_model = defaultdict(int)

    try:
        # Open read-only so a busy OpenCode instance is never blocked.
        db = sqlite3.connect("file:%s?mode=ro" % DATABASE, uri=True, timeout=1)
        rows = db.execute("""
            SELECT time_updated, model,
                   tokens_input + tokens_output + tokens_reasoning +
                   tokens_cache_read + tokens_cache_write
            FROM session
            WHERE time_archived IS NULL
        """)
        for updated, model, tokens in rows:
            if not updated or not tokens:
                continue
            day = datetime.fromtimestamp(updated / 1000).astimezone().date()
            if day < oldest or day > today:
                continue
            by_day[day] += tokens
            if model:
                by_model[display_model(model)] += tokens
        db.close()
    except (sqlite3.Error, OSError, OverflowError):
        print("days=0\nmodels=0")
        return

    days = []
    for offset in range(DAYS):
        day = oldest + timedelta(days=offset)
        days.append(("Today" if day == today else day.strftime("%a"), by_day[day]))
    peak = max((tokens for _, tokens in days), default=0) or 1
    for index, (label, tokens) in enumerate(days, 1):
        print("day.%d=%s|%s|%d" % (index, label, human_tokens(tokens), round(tokens / peak * 100)))
    print("days=%d" % len(days))

    models = sorted(by_model.items(), key=lambda entry: -entry[1])[:6]
    peak = max((tokens for _, tokens in models), default=0) or 1
    for index, (model, tokens) in enumerate(models, 1):
        print("model.%d=%s|%s|%d" % (index, model, human_tokens(tokens), round(tokens / peak * 100)))
    print("models=%d" % len(models))


if __name__ == "__main__":
    main()
