#!/usr/bin/env python3
"""Emit recent OpenCode token totals for the SketchyBar Codex popup."""

import os
import sqlite3
import json
from collections import defaultdict
from datetime import datetime, timedelta
from urllib.request import Request, urlopen

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


def fetch_weekly_limit():
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
            window = json.load(response)["rate_limit"]["primary_window"]
        return window.get("used_percent"), window.get("reset_after_seconds")
    except (OSError, KeyError, TypeError, ValueError):
        return None, None


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
    weekly_percent, weekly_reset = fetch_weekly_limit()
    if weekly_percent is not None:
        print("weekly_pct=%d" % round(weekly_percent))
    if weekly_reset is not None:
        print("weekly_reset=%s" % human_duration(weekly_reset))

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
