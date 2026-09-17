#!/usr/bin/env python3
"""Print line coverage from a JaCoCo CSV report, as one percentage.

`coverage` in .loop.toml is a command whose output ends in one percentage, and
scripts/coverage-ratchet.sh compares that figure with the committed floor. For a
Java project built with Maven or Gradle and instrumented with JaCoCo, this is that
command, so the project names it instead of copying the same one-liner:

    coverage = "python3 scripts/coverage-percent.py"
    coverage = "python3 scripts/coverage-percent.py build/reports/jacoco/jacoco.csv"

The default report is `target/site/jacoco/jacoco.csv`, which is where the Maven
plugin writes it. A report that is absent, or that measures no executable line, is
refused rather than printed as 0.00: 0/0 is not a measurement, and a floor compared
against a figure invented from it is a gate that passes for the wrong reason.

    scripts/coverage-percent.py [<jacoco.csv>]   the percentage, two decimals
    scripts/coverage-percent.py --self-test      a fixture report proves both
"""

import csv
import os
import shutil
import subprocess
import sys
import tempfile

DEFAULT_REPORT = "target/site/jacoco/jacoco.csv"


def percent(path):
    """The measured line coverage, or a refusal naming what is wrong."""
    try:
        stream = open(path, newline="")
    except OSError as error:
        raise SystemExit(f"no JaCoCo report at {path} ({error.strerror}); run the tests first")
    with stream:
        rows = list(csv.DictReader(stream))
    missed = sum(int(row["LINE_MISSED"]) for row in rows)
    covered = sum(int(row["LINE_COVERED"]) for row in rows)
    if missed + covered == 0:
        raise SystemExit(
            f"{path} reports no executable lines; no coverage floor can be measured"
        )
    return 100.0 * covered / (missed + covered)


def self_test():
    """A fixture report, an unmeasured report, and an absent one."""
    tmp = tempfile.mkdtemp(prefix="coverage-percent.")
    try:
        me = os.path.abspath(__file__)
        header = "GROUP,PACKAGE,CLASS,LINE_MISSED,LINE_COVERED\n"
        good = os.path.join(tmp, "good.csv")
        with open(good, "w") as stream:
            # Seven covered of eight executable lines: 87.50, not the 100.00 a report
            # that counted only what the tests touched would print.
            stream.write(header + "g,p,First,1,3\ng,p,Second,0,4\n")
        run = subprocess.run(
            [sys.executable, me, good], capture_output=True, text=True
        )
        if run.returncode != 0 or run.stdout.strip() != "87.50":
            print(f"self-test: 7 of 8 lines should read 87.50 (rc {run.returncode})", file=sys.stderr)
            print(run.stdout + run.stderr, file=sys.stderr)
            return 1
        # No executable lines is a refusal, not a 0.00.
        empty = os.path.join(tmp, "empty.csv")
        with open(empty, "w") as stream:
            stream.write(header + "g,p,None,0,0\n")
        run = subprocess.run(
            [sys.executable, me, empty], capture_output=True, text=True
        )
        if run.returncode == 0 or "no executable lines" not in run.stderr:
            print("self-test: a report with no executable lines must be refused", file=sys.stderr)
            print(run.stdout + run.stderr, file=sys.stderr)
            return 1
        # An absent report is a refusal that names the path, not a traceback.
        run = subprocess.run(
            [sys.executable, me, os.path.join(tmp, "absent.csv")],
            capture_output=True, text=True,
        )
        if run.returncode == 0 or "no JaCoCo report at" not in run.stderr:
            print("self-test: an absent report must be refused by name", file=sys.stderr)
            print(run.stdout + run.stderr, file=sys.stderr)
            return 1
        # The default path is the Maven plugin's, and the argument overrides it.
        if DEFAULT_REPORT != "target/site/jacoco/jacoco.csv":
            print("self-test: the default report path moved", file=sys.stderr)
            return 1
        print("coverage-percent self-test passed")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    args = sys.argv[1:]
    if args == ["--self-test"]:
        return self_test()
    if len(args) > 1 or (args and args[0].startswith("-")):
        print("usage: scripts/coverage-percent.py [<jacoco.csv>] | --self-test", file=sys.stderr)
        return 2
    print(f"{percent(args[0] if args else DEFAULT_REPORT):.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
