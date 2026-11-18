"""Run `flutter test --reporter json` and print pass/fail per test file.

Usage: python tools/test_summary.py [flutter test args...]
Writes the raw report to artifacts/test_report.jsonl.
"""
import collections
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLUTTER = os.environ.get("FLUTTER", r"C:\Projects\tools\flutter\bin\flutter.bat")


def main():
    (ROOT / "artifacts").mkdir(exist_ok=True)
    out = ROOT / "artifacts" / "test_report.jsonl"
    proc = subprocess.run([FLUTTER, "test", "--reporter", "json", *sys.argv[1:]],
                          cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    out.write_text(proc.stdout, encoding="utf-8")
    suites, tests = {}, {}
    per = collections.defaultdict(lambda: [0, 0, 0])
    for line in proc.stdout.splitlines():
        try:
            d = json.loads(line)
        except ValueError:
            continue
        t = d.get("type")
        if t == "suite":
            suites[d["suite"]["id"]] = d["suite"]["path"]
        elif t == "testStart":
            tests[d["test"]["id"]] = d["test"]["suiteID"]
        elif t == "testDone" and not d.get("hidden"):
            path = suites.get(tests.get(d["testID"]), "?")
            rel = os.path.relpath(path, ROOT) if path != "?" else path
            idx = {"success": 0, "failure": 1}.get(d["result"], 2)
            if d.get("skipped"):
                continue
            per[rel][idx] += 1
    tot = [0, 0, 0]
    for f in sorted(per):
        p, fl, e = per[f]
        tot = [tot[0] + p, tot[1] + fl, tot[2] + e]
        print(f"{p:4d} {fl:4d} {e:4d}  {f}")
    print(f"TOTAL pass={tot[0]} fail={tot[1]} error={tot[2]} (exit {proc.returncode})")


if __name__ == "__main__":
    main()
