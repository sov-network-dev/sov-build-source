# Vendored SQLite amalgamation

**Version:** SQLite 3.53.4 (`sqlite-amalgamation-3530400`)
**Source:** https://sqlite.org/2026/sqlite-amalgamation-3530400.zip
**License:** public domain (SQLite is dedicated to the public domain — no attribution required)

**sha256**
```
b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189  sqlite3.c
919e7f2e8ed1d8f56ac17b412b8971c76aa5d1a879752cc6058f75e7d5910e1d  sqlite3.h
```

## Why this is vendored rather than downloaded

The `sqlite3` Dart package (pulled in transitively by `sqflite_common_ffi`) ships a
build hook that, by default, **downloads a precompiled `libsqlite3.<abi>.android.so`
from GitHub releases during compilation**. That breaks the core requirement that an
operator node can build the app with no network at all, and it puts GitHub on the
critical path for producing a citizen APK — the exact single point of failure the
build-capacity design exists to remove (`docs/BUILD_CAPACITY_DESIGN.md`).

Measured 2026-08-24, building offline against the bundled toolchain:

```
By default, this package downloads a pre-compiled SQLite library.
This failed (attepted to download https://github.com/simolus3/sqlite3.dart/releases/
  download/sqlite3-3.3.2/libsqlite3.arm.android.so).
Original cause: SocketException: Failed host lookup: 'github.com'
```

`pubspec.yaml` therefore points the hook at this vendored source:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: source
      path: third_party/sqlite3/sqlite3.c
```

SQLite is then compiled by the bundled Android NDK as part of the normal build —
no external host is contacted, and the resulting library is built from source we
ship and can hash.

`source: system` was rejected: Android does not expose a system SQLite to apps
through the NDK, so it is not a reliable target.

## Updating

Download a newer amalgamation from https://sqlite.org/download.html, replace both
files, and update the version + hashes above. Rebuild and re-verify the APK on a
device before shipping — this compiles into the app.
