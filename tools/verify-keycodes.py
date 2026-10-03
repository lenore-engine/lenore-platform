# Checks the evdev codes transcribed into src/backend/linux/wl/keycodes.zig
# against the kernel header they came from.
#
# The file maps a number to a position and names the kernel's constant in a
# comment beside it. That comment is the only thing tying the two together, and
# this is what makes it load-bearing rather than decorative. A wrong number is
# a key that silently reports as another one.
#
#   python3 tools/verify-keycodes.py [/usr/include/linux/input-event-codes.h]
#
# The printed count is part of the result: a run that checks nothing also
# reports no mismatches.

import os
import re
import sys

header_path = sys.argv[1] if len(sys.argv) > 1 else "/usr/include/linux/input-event-codes.h"
source_path = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "src", "backend", "linux", "wl", "keycodes.zig",
)

header = {}
for line in open(header_path):
    match = re.match(r"#define\s+((?:KEY|BTN)_\w+)\s+(0x[0-9a-fA-F]+|\d+)", line)
    if match:
        header.setdefault(match.group(1), int(match.group(2), 0))

checked = 0
problems = 0
for match in re.finditer(
    r"\n\s+(0x[0-9a-fA-F]+|\d+) => \.(\w+), // ((?:KEY|BTN)_\w+)",
    open(source_path).read(),
):
    code, position, name = int(match.group(1), 0), match.group(2), match.group(3)
    checked += 1
    if header.get(name) != code:
        print(f"  {name} -> .{position}: file says {code}, header says {header.get(name)}")
        problems += 1

print(f"{checked} codes checked against {header_path}; {problems} mismatches")
sys.exit(1 if problems else 0)
