#!/usr/bin/env python3
"""Generic pty wrapper for supra CLI. Provides the profile password when
the (interactive-only) password prompt fires. Otherwise transparently
forwards stdout/stderr.

Usage:
    SUPRA_PASSWORD=... python3 supra-pty.py <supra-args...>
"""
import os
import pty
import sys
import select
import time

PASSWORD = os.environ.get(
    'SUPRA_PASSWORD',
    'DesnetMainnetDeploy2026!StrongPasswordForLocalCliOnly',
).encode() + b'\n'

cmd = ['supra'] + sys.argv[1:]
TIMEOUT = int(os.environ.get('SUPRA_PTY_TIMEOUT', '900'))

PROMPT_TRIGGERS = [
    b'Enter your password',
    b'Please create a new password',
    b'Please re-enter',
    b'Confirmation',
    b'Confirm',
]

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

deadline = time.time() + TIMEOUT
buf = b''
written = 0

while time.time() < deadline:
    try:
        rl, _, _ = select.select([fd], [], [], 1.0)
    except OSError:
        break
    child_done = False
    if fd in rl:
        try:
            chunk = os.read(fd, 4096)
            if not chunk:
                child_done = True
            else:
                try:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                except BrokenPipeError:
                    pass
                buf += chunk
                if any(t in buf for t in PROMPT_TRIGGERS):
                    if written < 6:
                        time.sleep(0.25)
                        os.write(fd, PASSWORD)
                        buf = b''
                        written += 1
                        time.sleep(0.4)
        except OSError:
            child_done = True

    try:
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid != 0:
            code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1
            sys.exit(code)
    except ChildProcessError:
        sys.exit(0)

    if child_done:
        # Read any remaining buffered output before exiting.
        try:
            while True:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
        except OSError:
            pass
        try:
            _, status = os.waitpid(pid, 0)
            sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
        except ChildProcessError:
            sys.exit(0)

print('\n[supra-pty timeout]', file=sys.stderr)
try:
    os.kill(pid, 9)
except ProcessLookupError:
    pass
sys.exit(2)
