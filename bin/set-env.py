#!/usr/bin/env python3
"""Write one setting into .env safely.

    set-env.py KEY "value with spaces or ; or $ in it"

Values are single-quoted, so nothing in a pasted token can ever be run as a
command by a script that reads this file.
"""
import io
import os
import re
import sys

if len(sys.argv) < 3:
    sys.exit("usage: set-env.py KEY VALUE")
key, value = sys.argv[1], sys.argv[2]
if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
    sys.exit(f"'{key}' is not a valid setting name")

line = "{}='{}'".format(key, value.replace("'", "'\\''"))
s = io.open(".env", encoding="utf-8").read() if os.path.exists(".env") else ""
if re.search(rf"^{re.escape(key)}=", s, re.M):
    s = re.sub(rf"^{re.escape(key)}=.*$", line, s, flags=re.M)
else:
    s = s.rstrip("\n") + "\n" + line + "\n"
io.open(".env", "w", encoding="utf-8").write(s)
os.chmod(".env", 0o600)
print(f"  saved {key}")
