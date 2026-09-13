#!/usr/bin/env python3
"""Read-only CPU-time delta for the installed app and its direct children."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=int, default=30)
args = parser.parse_args()
if not 5 <= args.seconds <= 60:
    parser.error('--seconds must be between 5 and 60')
app_path = str(Path.home() / 'Applications/Codex Tokenmaxxing.app/Contents/MacOS/CodexTokenmaxxing')


def rows():
    output = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,time=,comm='], text=True)
    return [line.strip().split(None, 3) for line in output.splitlines()]


def cpu_seconds(value):
    days, _, clock = value.rpartition('-')
    return (float(days) * 86400 if days else 0) + sum(
        float(part) * 60 ** index for index, part in enumerate(reversed(clock.split(':'))))


before = rows()
apps = [row[0] for row in before if len(row) == 4 and row[3] == app_path]
if len(apps) != 1:
    raise SystemExit('Expected exactly one installed app instance')
app_pid = apps[0]
start_cpu = {row[0]: cpu_seconds(row[2]) for row in before
             if len(row) == 4 and (row[0] == app_pid or row[1] == app_pid)}
start = time.monotonic()
time.sleep(args.seconds)
elapsed = time.monotonic() - start
results = [{'role': 'app' if row[0] == app_pid else 'owned_child',
            'cpu_percent': round(100 * (cpu_seconds(row[2]) - start_cpu[row[0]]) / elapsed, 3)}
           for row in rows() if len(row) == 4 and row[0] in start_cpu]
if len(results) != len(start_cpu):
    raise SystemExit('A measured process exited; repeat with stable processes')
print(json.dumps({'elapsed_seconds': round(elapsed, 2), 'processes': results}, indent=2))
