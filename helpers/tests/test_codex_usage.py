import importlib.util
import io
import json
import sqlite3
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import date, datetime, timedelta
from pathlib import Path
from unittest.mock import patch


HELPERS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("codex_usage", HELPERS / "codex_usage.py")
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


class TokenTotalsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.database = str(Path(self.temp.name) / "opencode.db")
        self.today = date(2026, 10, 17)
        self.oldest = self.today - timedelta(days=6)
        self.db = sqlite3.connect(self.database)
        self.addCleanup(self.db.close)

    def table(self, name):
        extra = ", type TEXT" if name == "session_message" else ""
        self.db.execute("CREATE TABLE %s (id TEXT PRIMARY KEY, time_created INTEGER, data TEXT%s)" % (name, extra))

    def message(self, table, identifier, day, tokens=None, model="gpt-test", role="assistant"):
        data = {"tokens": tokens or {}, "role": role}
        data["model" if table == "session_message" else "modelID"] = {"id": model} if table == "session_message" else model
        created = int(datetime.combine(day, datetime.min.time()).timestamp() * 1000)
        values = (identifier, created, json.dumps(data))
        if table == "session_message":
            values += (role,)
        self.db.execute("INSERT INTO %s VALUES (%s)" % (table, ",".join("?" for _ in values)), values)
        self.db.commit()

    def totals(self):
        return usage.token_totals(self.database, self.oldest, self.today)

    def test_v2_counts_turns_by_day_and_all_token_fields(self):
        self.table("session_message")
        yesterday = self.today - timedelta(days=1)
        self.message("session_message", "first", yesterday, {"input": 10, "output": 20, "reasoning": 3, "cache": {"read": 40, "write": 5}})
        self.message("session_message", "second", self.today, {"input": 7})
        self.message("session_message", "user", self.today, {"input": 999}, role="user")
        self.message("session_message", "streaming", self.today)
        days, models = self.totals()
        self.assertEqual(dict(days), {yesterday: 78, self.today: 7})
        self.assertEqual(dict(models), {"gpt-test": 85})

    def test_migrated_messages_are_not_double_counted(self):
        self.table("message")
        self.table("session_message")
        self.message("message", "shared", self.today, {"input": 100})
        self.message("session_message", "shared", self.today, {"input": 120})
        self.message("message", "legacy", self.oldest, {"output": 5}, model="gpt-legacy")
        days, models = self.totals()
        self.assertEqual(dict(days), {self.oldest: 5, self.today: 120})
        self.assertEqual(dict(models), {"gpt-legacy": 5, "gpt-test": 120})

    def test_legacy_only_and_local_date_boundaries(self):
        self.table("message")
        self.message("message", "old", self.oldest - timedelta(days=1), {"input": 999})
        self.message("message", "first", self.oldest, {"input": 1})
        self.message("message", "last", self.today, {"output": 2})
        self.message("message", "future", self.today + timedelta(days=1), {"input": 999})
        days, models = self.totals()
        self.assertEqual(dict(days), {self.oldest: 1, self.today: 2})
        self.assertEqual(dict(models), {"gpt-test": 3})

    def test_main_emits_seven_days_for_panel(self):
        self.table("session_message")
        self.message("session_message", "today", date.today(), {"input": 1200})
        output = io.StringIO()
        with patch.object(usage, "DATABASE", self.database), patch.object(usage, "fetch_plan", return_value=None), patch.object(usage, "fetch_limits", return_value={}), redirect_stdout(output):
            usage.main()
        self.assertIn("day.7=Today|1.2K|100\n", output.getvalue())
        self.assertIn("days=7\n", output.getvalue())
        self.assertIn("model.1=gpt-test|1.2K|100\n", output.getvalue())


if __name__ == "__main__":
    unittest.main()
