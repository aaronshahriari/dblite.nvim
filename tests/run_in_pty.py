#!/usr/bin/env python3
"""Run a Lua spec inside a pty of a fixed size.

Window widths cannot be tested with `nvim -l`: setting `vim.o.columns` does not
reflow the layout there, and `nvim_ui_attach` is unavailable, so a spec that
measures a window is measuring an 80-column grid whatever it thinks it set.
A pty gives nvim a real terminal of a chosen size.

    tests/run_in_pty.py <cols> <rows> <spec.lua> <data-dir>

The spec writes its result lines to the path in $DBLITE_SPEC_OUT and exits
non-zero by writing a line starting with "FAIL".
"""
import fcntl
import os
import pty
import struct
import subprocess
import sys
import tempfile
import termios


def main():
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    cols, rows, spec, data = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]

    out_fd, out_path = tempfile.mkstemp(prefix="dblite-spec-")
    os.close(out_fd)

    env = dict(os.environ, XDG_DATA_HOME=data, DBLITE_SPEC_OUT=out_path,
               DBLITE_SPEC_COLS=str(cols), DBLITE_SPEC_ROWS=str(rows))

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    proc = subprocess.Popen(
        ["nvim", "--clean", "-c", f"luafile {spec}", "-c", "qa!"],
        stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True)
    os.close(slave)
    proc.wait()
    try:
        os.close(master)
    except OSError:
        pass

    body = ""
    if os.path.exists(out_path):
        with open(out_path) as f:
            body = f.read()
        os.unlink(out_path)

    if not body.strip():
        print("    spec produced no output (nvim exited %d)" % proc.returncode)
        return 1
    failed = [ln for ln in body.splitlines() if ln.startswith("FAIL")]
    if failed:
        for ln in body.splitlines():
            print("    " + ln)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
