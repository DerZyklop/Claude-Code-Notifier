#!/usr/bin/env python3
"""Runs the last Claude run of a report again, with other effort levels, all at the same time.

The app saves the command of each run in `last-run.json` and its input in `last-run-input.json`. The command
runs through the login shell and removes the tokens of the app, the same as in the app. The replay never
writes the overview. It writes each answer and a summary into the folder `replay`.

Usage: python3 scripts/replay-last-run.py [--report morning-overview] default medium low

`default` runs without `--effort`. Each run uses the usage of your Claude plan.
"""

import argparse
import json
import pathlib
import re
import subprocess
import time

SUPPORT = pathlib.Path.home() / "Library/Application Support/local.claude-code-notifier.app"
LEVELS = ["default", "low", "medium", "high", "xhigh", "max"]


def summary_row(level, seconds, status, text):
    tasks = len(re.findall(r"(?m)^- \[ \] ", text))
    steps = len(re.findall(r"(?m)^\s+- \[ \] ", text))
    keeps = len(re.findall(r"(?m)^- \[ \] KEEP ", text))
    return f"| {level} | {seconds:.0f} s | {status} | {len(text)} | {tasks} | {steps} | {keeps} |"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--report", default="morning-overview", help="the folder of the report in the support folder")
    parser.add_argument("levels", nargs="+", choices=LEVELS)
    args = parser.parse_args()

    folder = SUPPORT / args.report
    run = json.loads((folder / "last-run.json").read_text())
    stdin = (folder / "last-run-input.json").read_bytes()
    out = folder / "replay"
    out.mkdir(exist_ok=True)

    started = {}
    for level in args.levels:
        command = [run["executable"]] + run["arguments"] + ([] if level == "default" else ["--effort", level])
        answer = open(out / f"{level}.md", "wb")
        errors = open(out / f"{level}.err", "wb")
        process = subprocess.Popen(command, cwd=run["directory"], stdin=subprocess.PIPE, stdout=answer, stderr=errors)
        process.stdin.write(stdin)
        process.stdin.close()
        started[level] = (process, time.monotonic(), answer, errors)

    rows = []
    for level, (process, start, answer, errors) in started.items():
        try:
            status = process.wait(timeout=run["timeout"])
        except subprocess.TimeoutExpired:
            process.kill()
            status = "timeout"
        seconds = time.monotonic() - start
        answer.close()
        errors.close()
        rows.append(summary_row(level, seconds, status, (out / f"{level}.md").read_text(errors="replace")))

    table = "\n".join(["| Effort | Time | Exit | Chars | Tasks | Sub-items | KEEP |", "| --- | ---: | --- | ---: | ---: | ---: | ---: |"] + rows)
    (out / "summary.md").write_text(table + "\n")
    print(table)
    print(f"\nThe answers are in {out}")


if __name__ == "__main__":
    main()
