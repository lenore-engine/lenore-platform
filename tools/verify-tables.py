# Diffs the tables tools/scanner.zig generates against the ones the canonical
# wayland-scanner produces from the same vendored XML.
#
# A wrong wl_message signature or types entry corrupts libwayland at the first
# request rather than failing to compile, so the generator is checked against
# the reference implementation instead of being trusted. Run it after changing
# the scanner or revendoring a protocol:
#
#   mkdir -p /tmp/wl-canon
#   for f in protocols/*.xml; do
#       wayland-scanner private-code "$f" "/tmp/wl-canon/$(basename ${f%.xml}).c"
#   done
#   python3 tools/verify-tables.py /tmp/wl-canon
#
# Needs wayland-progs. The printed counts are part of the result: a run that
# compares nothing also reports no problems.

import re, sys, glob, os

CANON = sys.argv[1] if len(sys.argv) > 1 else "/tmp/wl-canon"
GEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                   "src", "backend", "linux", "wl", "protocol")

# The one reference no vendored protocol defines. The request that carries it is
# deliberately not generated, so the null in its place can never be read.
ALLOWED_UNRESOLVED = {("wp_cursor_shape_manager_v1", "requests", "get_tablet_tool_v2")}
CORE_PROTOCOL = "wayland"

def nargs(sig):
    return sum(1 for c in sig.lstrip("0123456789") if c != "?")

def camel(name):
    head, *rest = name.split("_")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)

def canon_protocol(path):
    src = open(path).read()
    m = re.search(r"static const struct wl_interface \*(\w+)_types\[\] = \{(.*?)\n\};", src, re.S)
    types, prefix = [], m.group(1) if m else ""
    if m:
        for line in m.group(2).split("\n"):
            line = line.strip().rstrip(",")
            if not line: continue
            types.append(None if line == "NULL" else line.lstrip("&").replace("_interface", ""))

    messages = {}
    for mm in re.finditer(r"static const struct wl_message (\w+)_(requests|events)\[\] = \{(.*?)\n\};", src, re.S):
        table, kind, body = mm.group(1), mm.group(2), mm.group(3)
        entries = []
        for em in re.finditer(r'\{ "([^"]*)", "([^"]*)", ' + re.escape(prefix) + r'_types \+ (\d+) \}', body):
            name, sig, off = em.group(1), em.group(2), int(em.group(3))
            entries.append((name, sig, tuple(types[off:off + nargs(sig)])))
        messages[(table, kind)] = entries

    ifaces = {}
    for im in re.finditer(r"const struct wl_interface (\w+)_interface = \{\s*\"([^\"]+)\", (\d+),", src):
        table, name, version = im.group(1), im.group(2), int(im.group(3))
        ifaces[name] = {"version": version,
                        "requests": messages.get((table, "requests"), []),
                        "events": messages.get((table, "events"), [])}
    return ifaces

def gen_protocols():
    typemap, files = {}, {}
    for path in sorted(glob.glob(os.path.join(GEN, "*.zig"))):
        stem = os.path.basename(path)[:-4]
        src = files[stem] = open(path).read()
        for m in re.finditer(r"// (\w+), version (\d+)\npub const (\w+) = opaque \{", src):
            typemap[(stem, m.group(3))] = m.group(1)
    qualified = {f"{s}.{z}": i for (s, z), i in typemap.items()}

    result = {}
    for stem, src in files.items():
        for block in re.finditer(r"// (\w+), version (\d+)\npub const (\w+) = opaque \{(.*?)\n\};\n", src, re.S):
            iface, version, body = block.group(1), int(block.group(2)), block.group(4)
            entry = {"version": version, "requests": [], "events": [],
                     "protocol": stem, "opcodes": {}, "event_opcodes": {}, "skipped": set()}
            for kind in ("requests", "events"):
                tm = re.search(r"    const " + kind + r" = \[_\]client\.Message\{(.*?)\n    \};", body, re.S)
                if not tm: continue
                for em in re.finditer(r'\.\{ \.name = "([^"]*)", \.signature = "([^"]*)", \.types = &\[_\]\?\*const client\.Interface\{([^}]*)\} \}', tm.group(1)):
                    items = [t.strip() for t in em.group(3).split(",") if t.strip()]
                    resolved = []
                    for it in items:
                        if it == "null":
                            resolved.append(None)
                        else:
                            base = it[: -len(".interface")]
                            resolved.append(qualified.get(base, typemap.get((stem, base), "?" + base)))
                    entry[kind].append((em.group(1), em.group(2), tuple(resolved)))

            # Opcode actually used by each generated request wrapper.
            for fm in re.finditer(r"    pub fn (\w+)\(self: \*\w+[^\n]*\n(.*?)\n    \}(?:\n|$)", body, re.S):
                fname, fbody = fm.group(1), fm.group(2)
                om = re.search(r"\.marshal(?:Destructor|Constructor|ConstructorVersioned)?\((\d+)", fbody)
                if om: entry["opcodes"][fname] = int(om.group(1))
            dm = re.search(r"fn decodeEvent\(opcode: u32.*?\n    \}", body, re.S)
            if dm:
                for em in re.finditer(r'\n            (\d+) => \.\{? ?\.?(?:@"([^"]+)"|(\w+))', dm.group(0)):
                    entry["event_opcodes"][em.group(2) or em.group(3)] = int(em.group(1))
            for sm in re.finditer(r"// (\w+) is not generated:", body):
                entry["skipped"].add(sm.group(1))
            result[iface] = entry
    return result

canon = {}
for c in sorted(glob.glob(os.path.join(CANON, "*.c"))):
    canon.update(canon_protocol(c))
gen = gen_protocols()

problems = []
for name in sorted(set(canon) - set(gen)):
    problems.append(f"interface {name} is not generated")
for name in sorted(set(gen) - set(canon)):
    problems.append(f"interface {name} is generated but canonical output has none")

tables_checked = opcodes_checked = 0
for name in sorted(set(canon) & set(gen)):
    c, g = canon[name], gen[name]
    core = g["protocol"] == CORE_PROTOCOL
    if c["version"] != g["version"]:
        problems.append(f"{name}: version {g['version']} != canonical {c['version']}")

    # Tables: emitted for extensions only, since libwayland owns the core ones.
    if not core:
        for kind in ("requests", "events"):
            if len(c[kind]) != len(g[kind]):
                problems.append(f"{name}.{kind}: {len(g[kind])} entries != canonical {len(c[kind])}")
                continue
            for i, (ce, ge) in enumerate(zip(c[kind], g[kind])):
                tables_checked += 1
                if ce == ge: continue
                if (ce[0], ce[1]) == (ge[0], ge[1]) and (name, kind, ce[0]) in ALLOWED_UNRESOLVED:
                    if ce[0] not in g["skipped"]:
                        problems.append(f"{name}.{kind}[{i}] {ce[0]}: unresolved type but the request is still generated")
                    continue
                problems.append(f"{name}.{kind}[{i}]:\n    canonical {ce}\n    generated {ge}")

    # Opcodes: checked everywhere, including the core, where they are the only
    # thing this generator contributes and a wrong one is silent.
    for i, (mname, _, _) in enumerate(c["requests"]):
        if mname in g["skipped"]: continue
        got = g["opcodes"].get(camel(mname))
        if got is None:
            problems.append(f"{name}.{mname}: no generated request wrapper")
        elif got != i:
            problems.append(f"{name}.{mname}: opcode {got} != canonical {i}")
        else:
            opcodes_checked += 1
    for i, (ename, _, _) in enumerate(c["events"]):
        got = g["event_opcodes"].get(ename)
        if got is None:
            problems.append(f"{name}: event {ename} missing from decodeEvent")
        elif got != i:
            problems.append(f"{name}: event {ename} opcode {got} != canonical {i}")
        else:
            opcodes_checked += 1

for p in problems: print(p)
print(f"\n{len(canon)} interfaces: {tables_checked} table entries and {opcodes_checked} opcodes "
      f"compared against wayland-scanner {os.popen('wayland-scanner --version 2>&1').read().split()[-1]}; "
      f"{len(problems)} problems")
sys.exit(1 if problems else 0)
