#!/usr/bin/env python3
"""
apk_content_digest.py — the number independent builders compare.

THE PROBLEM THIS SOLVES
Two builders producing byte-identical software still produce different FILES. Measured
2026-08-25: two builds of the same source had byte-identical ZIP entries and differed
only inside the APK Signing Block, because v2 signing uses randomised PSS padding. So
comparing artifacts on their own sha256 makes every honest builder look like it
disagrees with every other, and k-of-n can never reach quorum.

So builders are compared on CONTENT: a digest over the entries, computed identically by
everyone. This file IS that contract. Change it and every previously-agreed digest
becomes meaningless network-wide.

THE ALGORITHM (deliberately boring, so any language can reimplement it)
  1. list every ZIP entry
  2. drop META-INF/*  -- see below
  3. for each survivor emit exactly:  "<name>:<sha256-hex-of-bytes>\n"
  4. sort those lines as BYTES (not locale-aware text -- a locale-sensitive sort would
     make the digest depend on the builder's environment, which is the whole thing we
     are trying to eliminate)
  5. sha256 the concatenation

WHY META-INF IS EXCLUDED
It holds the v1 JAR signature files, which differ per signing key. A tier-2 builder
never holds the SOV key (king, 2026-08-26) and signs with whatever throwaway key its CI
has, so including META-INF would guarantee disagreement between a builder and the key
holder for a reason that has nothing to do with the software. The APK Signing Block
itself is NOT a ZIP entry and is invisible here already.

WHAT THIS DOES AND DOES NOT PROVE
Equal digests mean two builders produced the same software. It says nothing about
whether that software is honest -- that is what quorum across DISTINCT OPERATORS is
for. A single builder agreeing with itself proves nothing at all.

Usage:
    python scripts/apk_content_digest.py app-release.apk
    python scripts/apk_content_digest.py a.apk b.apk      # compare two
"""
import hashlib
import sys
import zipfile


def content_digest(path):
    """Return (digest_hex, entry_count) for an APK/ZIP."""
    lines = []
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            name = info.filename
            if name.startswith('META-INF/'):
                continue
            h = hashlib.sha256(z.read(name)).hexdigest()
            lines.append(f'{name}:{h}\n'.encode('utf-8'))
    lines.sort()                      # byte sort, locale-independent by construction
    outer = hashlib.sha256()
    for ln in lines:
        outer.update(ln)
    return outer.hexdigest(), len(lines)


def main(argv):
    if len(argv) == 2:
        d, n = content_digest(argv[1])
        print(f'content_digest {d}')
        print(f'entries        {n}')
        return 0
    if len(argv) == 3:
        a, na = content_digest(argv[1])
        b, nb = content_digest(argv[2])
        print(f'{argv[1]}\n  {a}  ({na} entries)')
        print(f'{argv[2]}\n  {b}  ({nb} entries)')
        print()
        if a == b:
            print('AGREE — these two builders produced identical software.')
            print('        (The FILES will still differ: v2 signing randomises padding.)')
            return 0
        print('DISAGREE — same release, different content.')
        print('        Before treating this as hostile, check the attested toolchain_id,')
        print('        config_hash and build_path: builders that built different things')
        print('        are not in disagreement, they answered different questions.')
        return 1
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
