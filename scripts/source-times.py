#!/usr/bin/env python3
"""Dates each tracked file by its content, so a build restored from CI's cache compiles only what changed.

SwiftPM and the Swift compiler tell a changed source from its modification time. A fresh checkout dates
every file at the moment of the checkout, so a build restored from a cache would compile everything
again. This gives each tracked file a time drawn from its Git blob ID instead: a file whose content is
the one the cached build compiled has the time that build saw, and a changed file has another (two
contents share a time about once in 270 million). Each named folder's files, such as generated
sources Git does not track, are dated the same way from their content.

CI runs it right after the checkout (.github/workflows/ci.yml). A working tree's own times are what a
local build should see, so it is not for a checkout someone works in.

usage: source-times.py [FOLDER]...
"""
import hashlib
import os
import subprocess
import sys

EPOCH = 946684800  # 2000-01-01 UTC
BITS = 28  # some eight and a half years of seconds


def date(path, digest):
    seconds = EPOCH + (int(digest, 16) >> (len(digest) * 4 - BITS))
    os.utime(path, (seconds, seconds))


def main():
    listing = subprocess.run(["git", "ls-files", "--stage", "-z"], capture_output=True, check=True).stdout
    dated = 0
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        info, path = entry.split(b"\t", 1)
        mode, blob, _ = info.split(b" ")
        # A link's own time and a submodule's folder are no build's input.
        if mode in (b"120000", b"160000"):
            continue
        date(os.fsdecode(path), blob.decode())
        dated += 1
    for folder in sys.argv[1:]:
        for root, _, files in os.walk(folder):
            for name in files:
                path = os.path.join(root, name)
                if os.path.islink(path):
                    continue
                with open(path, "rb") as file:
                    date(path, hashlib.sha1(file.read()).hexdigest())
                dated += 1
    print(f"Dated {dated} files by their content.")


if __name__ == "__main__":
    main()
