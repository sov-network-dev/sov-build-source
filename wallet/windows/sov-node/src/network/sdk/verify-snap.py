#!/usr/bin/env python3
"""
verify-snap.py — check a sov-relay snap against the source the network is actually
running, before installing it.

There is no founder signing key, and this script does not look for one. The previous
version verified an Ed25519 signature against a hardcoded "founder trust anchor".
That model is retired and was dead in practice: nothing signed with the key, no node
produced the .snap.sig file (the route answers 404), the app had stopped shipping the
key, and the node's own manifest anchor was all zeros. A single keyholder is also
exactly the point of failure the network is built to avoid — see
docs/NODE_INTEGRITY_DESIGN.md.

What legitimacy rests on instead: every node computes `source_root`, a sha256 over
each file of its own src/ tree, and peers refuse a node whose root is not one that
EARNED nodes already run. So the honest question about a snap is not "who signed
it?" but "is this the source the running network agrees on?" — and that is
answerable by anyone, from several independent nodes, with no secret anywhere.

Usage:
  curl -O http://<node-address>/sov-relay.snap
  python3 verify-snap.py <node-address> <node-address> [<node-address> ...]

  e.g.  python3 verify-snap.py node-a.example:80 node-b.example:80 node-c.example:80

Give at least two addresses you chose yourself. Do NOT take the list from the same
node that served you the snap, and do not take it from this file: a node that hands
you both the software and the authority to judge it has told you nothing. Addresses
are only the operator's own choice of who to ask.

Exit codes:
  0  at least two independent nodes run exactly this source. Safe to install.
  1  disagreement, or too few nodes answered. Do not install.
  2  could not perform the check (missing snap, missing unsquashfs, no answers).

Requires: unsquashfs (squashfs-tools). No Python packages, and no network trust.
"""
import sys, os, json, hashlib, shutil, subprocess, tempfile, urllib.request

SNAP_PATH = "sov-relay.snap"
QUORUM    = 2          # distinct nodes that must agree; see NODE_INTEGRITY_DESIGN.md
TIMEOUT   = 15


def die(code, msg):
    print()
    print("  %s %s" % ("✗" if code else "✓", msg))
    if code == 1:
        print()
        print("  DO NOT INSTALL THIS SNAP.")
    sys.exit(code)


def ok(msg):
    print("  ✓ %s" % msg)


def note(msg):
    print("    %s" % msg)


def node_source_root(addr):
    """Ask one node what source it is running. Returns the root, or None."""
    url = addr if addr.startswith("http") else "http://%s" % addr
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/node-info", timeout=TIMEOUT) as r:
            info = json.loads(r.read().decode("utf-8", "replace"))
    except Exception as e:
        note("%-28s unreachable (%s)" % (addr, str(e)[:44]))
        return None
    root = (info or {}).get("source_root") or ""
    if not root:
        note("%-28s answered, but serves no source_root (node too old)" % addr)
        return None
    note("%-28s %s" % (addr, root))
    return root.lower()


def main():
    addrs = [a for a in sys.argv[1:] if a.strip()]
    print()
    print("=" * 74)
    print("  SOV-RELAY SNAP — does the network run this source?")
    print("=" * 74)
    print()

    if len(addrs) < QUORUM:
        die(2, "give at least %d node addresses of your own choosing. See the header." % QUORUM)
    if len(set(addrs)) != len(addrs):
        die(2, "the addresses must be distinct - asking one node twice is one opinion.")
    if not os.path.exists(SNAP_PATH):
        die(2, "missing %s in the current directory." % SNAP_PATH)
    if not shutil.which("unsquashfs"):
        die(2, "unsquashfs not found. Install squashfs-tools, then run this again.")

    with open(SNAP_PATH, "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    ok("snap sha256: %s" % sha)

    tmp = tempfile.mkdtemp(prefix="sovverify-")
    try:
        root_dir = os.path.join(tmp, "squashfs-root")
        p = subprocess.run(["unsquashfs", "-q", "-f", "-d", root_dir, SNAP_PATH],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if p.returncode != 0:
            die(2, "could not unpack the snap: %s" % p.stdout.decode("utf-8", "replace")[-200:])

        srjs = os.path.join(root_dir, "src", "release", "source_root.js")
        nodebin = os.path.join(root_dir, "bin", "node")
        if not os.path.exists(srjs):
            die(2, "this snap has no src/release/source_root.js - it cannot be checked this way.")
        if not os.path.exists(nodebin):
            die(2, "this snap bundles no node binary at bin/node.")
        os.chmod(nodebin, 0o755)

        # Compute the root with the snap's OWN copy of the algorithm. That is deliberate:
        # a snap whose source_root.js lies about its own tree still has to produce a root
        # that earned nodes already run, and it cannot - it would have to guess a hash of
        # source it is not carrying.
        expr = ('const m=require(%r);'
                'const r=m.sourceRoot(%r,{include:["src"]});'
                'process.stdout.write(r.root+" "+r.fileCount);') % (srjs, root_dir)
        p = subprocess.run([nodebin, "-e", expr], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = p.stdout.decode("utf-8", "replace").strip()
        if p.returncode != 0 or " " not in out:
            die(2, "could not compute the snap's source_root: %s" % out[-200:])
        snap_root, file_count = out.split(" ", 1)
        snap_root = snap_root.lower()
        ok("snap source_root: %s  (%s files)" % (snap_root, file_count))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print()
    print("  asking %d nodes what source they run:" % len(addrs))
    roots = {}
    for a in addrs:
        r = node_source_root(a)
        if r:
            roots[a] = r
    print()

    if not roots:
        die(2, "no node answered with a source_root. Nothing was verified.")

    agree    = [a for a, r in roots.items() if r == snap_root]
    disagree = {a: r for a, r in roots.items() if r != snap_root}

    # This line prints BEFORE the quorum test, and ok() always prints a tick - so the
    # one-reachable-node path showed a tick on "1 of 1 answering nodes run exactly this
    # source" immediately above the cross on "only 1 node(s) confirmed ... DO NOT
    # INSTALL". The count was right; the glyph contradicted the verdict two lines later,
    # which is the wrong way round for a tool whose job is to refuse. Mark it by whether
    # the count actually clears QUORUM, and say what the bar is. Exit codes untouched.
    _mark = "✓" if len(agree) >= QUORUM else "•"
    print("  %s %d of %d answering nodes run exactly this source (%d required)"
          % (_mark, len(agree), len(roots), QUORUM))
    for a, r in disagree.items():
        note("DIFFERENT: %s runs %s" % (a, r))

    if len(agree) >= QUORUM:
        print()
        print("=" * 74)
        print("  VERIFIED: %d independent nodes run this exact source." % len(agree))
        print("  root: %s" % snap_root)
        print("=" * 74)
        print()
        print("  Install with:  sudo snap install --dangerous --devmode %s" % SNAP_PATH)
        print()
        print("  --dangerous means 'not from the Snap Store', not 'unsafe'. What you have")
        print("  checked is that the running network agrees on this source - which is a")
        print("  stronger claim than one signature, and it needs nobody to stay alive.")
        print()
        sys.exit(0)

    if disagree and not agree:
        die(1, "no node runs this source. The nodes agree on something else - you have a "
               "build the network does not accept.")
    die(1, "only %d node(s) confirmed this source; %d are required. Ask more nodes, or "
           "treat this build as unverified." % (len(agree), QUORUM))


if __name__ == "__main__":
    main()
