# portable_packer — generic "no-SmartScreen" single-exe packer (+ signing)

A reusable version of the SOV `tools/portable_stub` recipe (see
`docs/PORTABLE_PACKAGING.md` for *why* it works). Turns any Windows app's
**Release folder** into ONE portable `.exe` that **loads like a native app** —
extracts to `%LOCALAPPDATA%\<name>\<build_id>\` on first run and launches the
inner exe. **No install, no UAC, no registry** → it sidesteps the SmartScreen
installer/dropper weighting. App-specific values are **flags**, not C edits.

Proven end-to-end 2026-06-22 (parameterised compile + self-signed signing +
load-in-place + arg/exit-code passthrough + signed-exe footer survival).

## Why it avoids SmartScreen
SmartScreen punishes the **installer pattern** (writes to Program Files, asks for
UAC elevation, touches the registry/uninstall entries). This loader does none of
that — it unpacks to the user's LocalAppData and runs in place (the PyInstaller
`--onefile` trick). NB: SmartScreen is ultimately **reputation-based**; removing the
installer triggers clears the *unknown-publisher installer* wall, but a brand-new
unsigned binary can still warn until reputation accrues. The durable fix is a real
**OV/EV Authenticode** signature (below).

## Files
| file | role |
|------|------|
| `stub.c` | app-agnostic native loader. Inner exe + cache folder are `-D` defines (injected via a forced-include `app_params.h`). Finds its payload by **scanning the tail backward for the footer magic**, so it works whether you sign the stub-then-append OR sign the whole assembled exe. |
| `stub.manifest.tmpl` / `stub.rc.tmpl` | templated manifest (`asInvoker` → no UAC) + version/icon resources. Rendered per app. |
| `pack_portable.py` | the CLI packer (compile → [sign stub] → zip → concat+footer → [sign exe] → verify). |

## Build a portable (unsigned)
```bat
python tools\portable_packer\pack_portable.py ^
  --name "MyApp" --exe MyApp.exe ^
  --src build\windows\x64\runner\Release ^
  --icon windows\runner\resources\app_icon.ico ^
  --out dist\MyApp.exe ^
  --company "My Company" --version 1.4.0 ^
  --exclude "node,sov-node"        REM optional: omit top-level payload dirs
```
Output: one `dist\MyApp.exe`. First run extracts to `%LOCALAPPDATA%\MyApp\<id>\`;
later runs launch instantly (`.ready` short-circuit). `MyApp.exe --cli <args>` and
deep-link URLs are forwarded to the inner exe; in `--cli` mode stdio is inherited
and the child's exit code is returned (scriptable).

## Runtime robustness (stub hardened 2026-07-14)
Failure mode found in the PCShare project (its `SESSION_PLAN.md` 2026-07-14 entry has
the full diagnosis): a cache dir that exists WITHOUT its `.ready` marker while a
previous instance still holds locks on cache files made every relaunch re-run
extraction; `tar` exited nonzero ("Can't unlink already-existing object") and the old
stub died with "Failed to unpack the app payload" — the inner app (and any in-app
single-instance handoff) never ran. The stub now:
- **Launches through a locked cache.** If extraction exits nonzero but `<APP_EXE>` is
  already present in the cache, the stub logs a warning and launches the existing copy
  — the cache is keyed by `build_id`, so a locked file already contains the same bytes.
  `.ready` is withheld so a later, unlocked launch completes extraction (self-heal).
  If `<APP_EXE>` is missing it still dies as before (genuinely broken payload).
- **Retries the `.ready` write** (5 × 200 ms) instead of silently discarding a failure
  that would leave the cache in re-extract-every-launch mode; persistent failure is
  logged.
- **Logs non-fatal warnings** (timestamped, ASCII) to `%LOCALAPPDATA%\<name>\stub.log`,
  echoed to stderr in `--cli` mode. Fatal errors are unchanged (MessageBox / stderr).

## PORTABLE_STUB_EXE (added 2026-07-15)
Before launching the inner exe the stub sets the inherited env var
**`PORTABLE_STUB_EXE`** = the portable exe's own full path. Apps that persist a
path to themselves (Explorer shell verbs, shortcuts, protocol handlers, "open at
login" entries) MUST prefer this over their own resolved executable: the resolved
path is the version-numbered cache folder (`%LOCALAPPDATA%\<name>\<build_id>\...`),
which goes stale on every re-pack, while the portable exe path stays constant. The
stub forwards command-line args to the inner exe, so anything launched via the
portable path behaves identically. First consumer: PCShare's "Send with PCShare"
Explorer verb (`share_integration.dart`), which previously pinned whatever exe
registered it.

## Signing
Two parts: the **pipeline** (free, here) and the **certificate** (a secret you supply).

```bat
REM real OV/EV cert (clears SmartScreen as reputation builds) — sign the final exe:
python ...\pack_portable.py ... --sign --pfx C:\secrets\codesign.pfx --pfx-pass "***"

REM or use a cert already in the Windows store by subject name:
python ...\pack_portable.py ... --sign --cert-subject "My Company Ltd"

REM prove the pipeline with a throwaway self-signed cert (does NOT clear SmartScreen):
python ...\pack_portable.py ... --sign --self-signed
```
- `--sign-mode full` (default) signs the **assembled** exe → the whole payload is
  signature-protected (tamper-evident). The loader's backward-scan finds the footer
  even though the Authenticode cert table is appended after it.
- `--sign-mode stub` signs just the ~107 KB loader, then appends the payload after it
  (cheaper; payload not covered by the signature; relies on the default Authenticode
  behaviour of ignoring trailing data).
- Always RFC-3161 timestamped (`--timestamp-url`, default DigiCert) so signatures stay
  valid after the cert expires.

### Getting a real certificate (owner action, not automatable)
1. Buy an **OV** (~$200–400/yr) or **EV** (~$300–600/yr; instant SmartScreen reputation)
   code-signing cert from a CA (DigiCert, Sectigo, SSL.com, …). EV ships on an HSM/USB
   token or cloud-HSM (key never exportable) — for token/cloud certs use `--cert-subject`
   (signtool talks to the token/KSP), not `--pfx`.
2. Provide it as a **sealed secret** (PFX path + password, or store-installed token).
3. Re-run with `--sign --pfx …` / `--cert-subject …`. `signtool verify /pa` then reports
   **VALID** instead of the self-signed "NOT TRUSTED".

## Requirements
- Build host: MSVC (`cl.exe` via `vcvars64.bat`), Windows SDK `rc.exe` + `signtool.exe`
  (auto-detected; override with env vars `VCVARS`, `RC`, `SIGNTOOL`).
- End-user host: **Windows 10/11** only (uses the built-in `tar.exe` to unzip at runtime —
  no shipped runtime deps).

## Cross-platform note
Same load-in-place idea exists natively elsewhere: Linux **AppImage** (self-mounting,
runs in place), macOS **.app/.dmg** (loads in place; needs `notarytool` to clear
Gatekeeper). Only Windows needs this stub.
