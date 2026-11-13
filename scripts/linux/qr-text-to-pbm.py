"""Turns a QR code the Linux host drew in a terminal (half blocks, black on white, `yardlet host pair`) into a PBM
image, which zbarimg reads back, for scripts/linux/check-remote.sh.

    python3 qr-text-to-pbm.py TERMINAL_OUTPUT IMAGE.pbm
"""
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
lines = [re.sub(r"\x1b\[[0-9;]*m", "", line) for line in text.splitlines() if "\x1b[30;107m" in line]
if not lines:
    sys.exit("no QR code in the output")
rows = []
for line in lines:
    top, bottom = [], []
    for char in line:
        top.append(1 if char in "▀█" else 0)
        bottom.append(1 if char in "▄█" else 0)
    rows += [top, bottom]
scale = 8
width = len(rows[0]) * scale
with open(sys.argv[2], "w", encoding="ascii") as image:
    image.write(f"P1\n{width} {len(rows) * scale}\n")
    for row in rows:
        line = " ".join(str(bit) for bit in row for _ in range(scale))
        for _ in range(scale):
            image.write(line + "\n")
