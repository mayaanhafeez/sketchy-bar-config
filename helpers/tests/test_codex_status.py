import re
import subprocess
import unittest
from pathlib import Path


class CodexStatusTest(unittest.TestCase):
    def count(self, processes):
        script = (Path(__file__).resolve().parents[1] / "codex_status.sh").read_text()
        program = re.search(r"/usr/bin/awk '([^']*)'", script).group(1)
        result = subprocess.run(["/usr/bin/awk", program], input="\n".join(processes), text=True, capture_output=True, check=True)
        return int(result.stdout.strip())

    def test_native_and_runtime_launchers(self):
        self.assertEqual(self.count([
            "/Users/test/.local/share/mise/installs/opencode/2.0.32/node_modules/@opencode/cli/bin/opencode.exe serve --service",
            "/opt/homebrew/bin/opencode",
            "/Applications/OpenCode.app/Contents/MacOS/OpenCode",
            "/usr/local/bin/codex --model gpt-test",
            "node /usr/local/bin/opencode",
            "/opt/homebrew/bin/bun /usr/local/bin/codex",
        ]), 6)

    def test_helpers_and_unrelated_arguments_are_not_agents(self):
        self.assertEqual(self.count([
            "bash /Users/test/.config/sketchybar/helpers/codex_status.sh",
            "vim /Users/test/.config/opencode/config.json",
            "sh -c opencode --version",
            "grep opencode",
            "/usr/bin/awk opencode",
            "node /work/opencode-tools/server.js",
            "/Applications/OpenCode.app/Contents/MacOS/chrome_crashpad_handler",
        ]), 0)


if __name__ == "__main__":
    unittest.main()
