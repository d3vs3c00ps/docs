"""Drive a full-screen terminal program through a pseudo-terminal.

    python3 tui.py CMD [ARG...] < steps

Each line of steps is one of:
    send TEXT       type TEXT; \\r is Enter, \\x1b is Esc, \\x03 is Ctrl-C, \\x0b is Ctrl-K
    expect REGEX    wait (up to 30s) until REGEX shows up in the screen output since
                    the last send; escape sequences are stripped before matching
    wait SECONDS    sleep, still reading output
    exit            wait (up to 30s) for the program to exit

Prints one line per step. On a failed step, prints the stripped output and exits 1.
"""
import os
import pty
import re
import select
import shlex
import struct
import sys
import time
import fcntl
import termios

ANSI = re.compile(rb"\x1b(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|[()][0-9A-B]|[=>78M])")

pid, fd = pty.fork()
if pid == 0:
    os.environ.setdefault("TERM", "xterm-256color")
    os.execvp(sys.argv[1], sys.argv[1:])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
buf = b""
exited = False


def pump(timeout):
    global buf, exited
    r, _, _ = select.select([fd], [], [], timeout)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        if not data:
            exited = True
        buf += data


def screen():
    # Cursor moves become spaces so words drawn cell by cell stay apart from neighbours.
    return ANSI.sub(b" ", buf).decode("utf-8", "replace")


def fail(step):
    print(f"FAILED: {step}\n--- output since last send ---\n{screen()[-4000:]}")
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    sys.exit(1)


for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    op, _, arg = line.partition(" ")
    if op == "send":
        buf = b""
        for ch in arg.encode().decode("unicode_escape"):
            os.write(fd, ch.encode())
            time.sleep(0.15)
        print(f"sent {arg}")
    elif op == "expect":
        deadline = time.time() + 30
        while not re.search(arg, screen()):
            if exited or time.time() > deadline:
                fail(line)
            pump(0.5)
        print(f"saw /{arg}/")
    elif op == "wait":
        deadline = time.time() + float(arg)
        while time.time() < deadline:
            pump(0.2)
    elif op == "exit":
        deadline = time.time() + 30
        while not exited:
            if time.time() > deadline:
                fail(line)
            pump(0.5)
            if os.waitpid(pid, os.WNOHANG)[0]:
                exited = True
        print("exited")
    else:
        fail(f"unknown step: {shlex.quote(line)}")
