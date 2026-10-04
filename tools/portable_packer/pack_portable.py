#!/usr/bin/env python3
r"""pack_portable.py — GENERIC single-exe portable packer (the "no-SmartScreen"
load-in-place pattern), reusable for ANY Windows app. Optional Authenticode signing.

Produces ONE portable <App>.exe that loads like a native app (PyInstaller-onefile
style): on first run it extracts the embedded Release folder to
%LOCALAPPDATA%\<name>\<build_id>\ and launches the inner exe; later runs skip
straight to launch. No install, no UAC, no registry.

The native loader (stub.c) is app-agnostic — the inner exe name and cache folder
are passed here and injected at compile time via a forced-include header, so you
NEVER edit C per project.

Pipeline:
  1. render stub.rc.tmpl + stub.manifest.tmpl with your app's name/version/icon
  2. compile stub.c (+ /FIapp_params.h defining APP_EXE/APP_CACHE) -> stub_gen.exe
  3. [optional] sign the stub  (--sign-mode stub)
  4. zip the Release folder
  5. stub + zip + 24B footer  ->  <out>.exe
  6. [optional] sign the final exe (--sign-mode full, default)  + verify

Footer (little-endian): 8B magic "SOVPK\1\0\0" | 8B zip_offset | 8B build_id
(the stub finds it by scanning the tail backward, so a trailing Authenticode
certificate table from full-exe signing does not hide it).

Examples
  # unsigned, any app:
  python pack_portable.py --name "MyApp" --exe MyApp.exe \
      --src build\windows\x64\runner\Release --icon my.ico --out dist\MyApp.exe

  # sign the final exe with a real OV/EV PFX (clears SmartScreen on reputation):
  python pack_portable.py --name "MyApp" --exe MyApp.exe --src ...\Release \
      --out dist\MyApp.exe --sign --pfx C:\secrets\cs.pfx --pfx-pass "***"

  # prove the signing pipeline with a throwaway self-signed cert (does NOT clear
  # SmartScreen — for plumbing verification only):
  python pack_portable.py ... --sign --self-signed
"""
import os, sys, glob, struct, time, zipfile, subprocess, shutil, argparse, tempfile

HERE  = os.path.dirname(os.path.abspath(__file__))
MAGIC = b"SOVPK\x01\x00\x00"

# ── Toolchain discovery (override with env vars) ────────────────────────────
def _latest(pattern):
    hits = sorted(glob.glob(pattern))
    return hits[-1] if hits else None

def find_vcvars():
    if os.environ.get("VCVARS"): return os.environ["VCVARS"]
    for p in [
        r"C:\Program Files\Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvars64.bat",
        r"C:\Program Files (x86)\Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvars64.bat",
    ]:
        h = _latest(p)
        if h: return h
    raise SystemExit("vcvars64.bat not found (set VCVARS=...)")

def find_sdk_tool(name):
    env = os.environ.get(name.upper())
    if env: return env
    h = _latest(rf"C:\Program Files (x86)\Windows Kits\10\bin\*\x64\{name}.exe")
    if h: return h
    raise SystemExit(f"{name}.exe not found in Windows Kits (set {name.upper()}=...)")

def render(tmpl_path, out_path, subs):
    s = open(tmpl_path, "r", encoding="utf-8").read()
    for k, v in subs.items():
        s = s.replace("{{" + k + "}}", v)
    open(out_path, "w", encoding="utf-8", newline="").write(s)

# ── Signing ─────────────────────────────────────────────────────────────────
def make_self_signed(pfx_path, subject, password):
    """Generate a throwaway self-signed code-signing cert -> PFX (pipeline test only)."""
    ps = f'''
$ErrorActionPreference = "Stop"
$c = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN={subject}" `
        -CertStoreLocation Cert:\\CurrentUser\\My -KeyUsage DigitalSignature `
        -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(2)
$pw = ConvertTo-SecureString -String "{password}" -Force -AsPlainText
Export-PfxCertificate -Cert $c -FilePath "{pfx_path}" -Password $pw | Out-Null
Remove-Item ("Cert:\\CurrentUser\\My\\" + $c.Thumbprint) -Force
Write-Output "OK"
'''
    r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps],
                       capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(pfx_path):
        print(r.stdout[-800:]); print(r.stderr[-800:])
        raise SystemExit("self-signed cert generation FAILED")
    print(f"  self-signed PFX -> {pfx_path}")

def sign_file(path, args):
    signtool = find_sdk_tool("signtool")
    cmd = [signtool, "sign", "/fd", "SHA256",
           "/tr", args.timestamp_url, "/td", "SHA256"]
    if args.pfx:
        cmd += ["/f", args.pfx]
        if args.pfx_pass: cmd += ["/p", args.pfx_pass]
    elif args.cert_subject:
        cmd += ["/n", args.cert_subject, "/s", args.cert_store]
    cmd += [path]
    r = subprocess.run(cmd, capture_output=True, text=True)
    print("  " + (r.stdout.strip().splitlines() or ["(signtool)"])[-1])
    if r.returncode != 0:
        print(r.stdout[-1200:]); print(r.stderr[-1200:])
        raise SystemExit("signtool sign FAILED")

def verify_file(path):
    signtool = find_sdk_tool("signtool")
    # /pa = use the default authenticode policy (what Windows/SmartScreen applies)
    r = subprocess.run([signtool, "verify", "/pa", "/v", path],
                       capture_output=True, text=True)
    ok = (r.returncode == 0)
    tail = (r.stdout + r.stderr).strip().splitlines()
    print("  verify:", "VALID" if ok else "NOT TRUSTED (expected for self-signed)")
    for ln in tail[-6:]:
        if ln.strip(): print("    " + ln.strip())
    return ok

# ── Build ─────────────────────────────────────────────────────────────────
def compile_stub(args, ident, ver_csv):
    # app params via forced-include header (no quote-escaping in the batch)
    open(os.path.join(HERE, "app_params.h"), "w", newline="").write(
        f'#define APP_EXE   L"{args.exe}"\n'
        f'#define APP_CACHE L"{args.cache}"\n')

    subs = {
        "NAME": args.name, "IDENT": ident, "COMPANY": args.company,
        "VERSION": args.version, "VERCSV": ver_csv,
        "OUTNAME": os.path.basename(args.out),
    }
    render(os.path.join(HERE, "stub.manifest.tmpl"),
           os.path.join(HERE, "stub_gen.manifest"), subs)
    render(os.path.join(HERE, "stub.rc.tmpl"),
           os.path.join(HERE, "stub_gen.rc"), subs)

    # icon (optional) — rc needs the file present; if none, drop a 1x1 placeholder ref out
    if args.icon and os.path.exists(args.icon):
        shutil.copyfile(args.icon, os.path.join(HERE, "app_icon.ico"))
    else:
        # remove the ICON line so rc doesn't fail on a missing file
        rc = open(os.path.join(HERE, "stub_gen.rc")).read().replace('1 ICON "app_icon.ico"\n', "")
        open(os.path.join(HERE, "stub_gen.rc"), "w", newline="").write(rc)

    rc_exe = find_sdk_tool("rc")
    vcvars = find_vcvars()
    bat = (
        f'@echo off\r\n'
        f'call "{vcvars}"\r\n'
        f'cd /d "{HERE}"\r\n'
        f'"{rc_exe}" /nologo /fo stub_gen.res stub_gen.rc || exit /b 1\r\n'
        f'cl /nologo /O2 /W3 /FIapp_params.h stub.c stub_gen.res /Fe:stub_gen.exe '
        f'/link /SUBSYSTEM:WINDOWS kernel32.lib user32.lib shell32.lib ole32.lib || exit /b 1\r\n'
    )
    bp = os.path.join(HERE, "_build_gen.bat")
    open(bp, "w", newline="").write(bat)
    r = subprocess.run([bp], capture_output=True, text=True, shell=True)
    stub = os.path.join(HERE, "stub_gen.exe")
    if r.returncode != 0 or not os.path.exists(stub):
        print(r.stdout[-1800:]); print(r.stderr[-1800:])
        raise SystemExit("stub compile FAILED")
    print(f"  stub_gen.exe compiled ({os.path.getsize(stub):,} bytes)")
    return stub

def zip_release(src, zip_path, exclude_top):
    n = 0
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for dp, dns, fns in os.walk(src):
            rel = os.path.relpath(dp, src)
            top = rel.split(os.sep)[0] if rel != "." else ""
            if top in exclude_top:
                dns[:] = []; continue
            for fn in fns:
                full = os.path.join(dp, fn)
                z.write(full, os.path.relpath(full, src)); n += 1
    print(f"  zipped {n:,} files -> {os.path.getsize(zip_path):,} bytes")

def main():
    ap = argparse.ArgumentParser(description="Generic no-SmartScreen portable packer")
    ap.add_argument("--name", required=True, help="App display name")
    ap.add_argument("--exe",  required=True, help="Inner exe filename (e.g. MyApp.exe)")
    ap.add_argument("--src",  required=True, help="Release folder to embed")
    ap.add_argument("--out",  required=True, help="Output portable exe path")
    ap.add_argument("--icon", default="", help=".ico path (optional)")
    ap.add_argument("--cache", default="", help="LocalAppData cache folder (default: name, alnum)")
    ap.add_argument("--ident", default="", help="Internal name (default: cache)")
    ap.add_argument("--company", default="", help="CompanyName/Copyright string")
    ap.add_argument("--version", default="1.0.0", help="x.y.z (default 1.0.0)")
    ap.add_argument("--exclude", default="", help="comma list of top-level dirs to omit")
    # signing
    ap.add_argument("--sign", action="store_true", help="Authenticode-sign the output")
    ap.add_argument("--sign-mode", choices=["full", "stub"], default="full",
                    help="full=sign assembled exe (payload protected); stub=sign loader then append")
    ap.add_argument("--pfx", default="", help="PFX/PKCS12 cert file")
    ap.add_argument("--pfx-pass", default="", help="PFX password")
    ap.add_argument("--cert-subject", default="", help="Use a store cert by subject (alt to --pfx)")
    ap.add_argument("--cert-store", default="My", help="Cert store for --cert-subject (default My)")
    ap.add_argument("--timestamp-url", default="http://timestamp.digicert.com",
                    help="RFC-3161 timestamp authority")
    ap.add_argument("--self-signed", action="store_true",
                    help="generate a throwaway self-signed cert (pipeline test; does NOT clear SmartScreen)")
    args = ap.parse_args()

    if not os.path.exists(os.path.join(args.src, args.exe)):
        raise SystemExit(f"inner exe not found: {os.path.join(args.src, args.exe)}")


    alnum = "".join(c for c in args.name if c.isalnum()) or "PortableApp"
    args.cache = args.cache or alnum
    ident = args.ident or args.cache
    parts = (args.version.split(".") + ["0", "0", "0"])[:3]
    ver_csv = ",".join(parts) + ",0"
    exclude_top = {x.strip() for x in args.exclude.split(",") if x.strip()}
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    build_id = int(time.time())

    # self-signed cert (for pipeline testing) -> a temp PFX consumed by sign_file
    tmp_pfx = None
    if args.sign and args.self_signed and not args.pfx:
        tmp_pfx = os.path.join(tempfile.gettempdir(), f"portable_selfsign_{build_id}.pfx")
        args.pfx_pass = args.pfx_pass or "portable-test"
        print("[*] generating self-signed cert (TEST ONLY — will not clear SmartScreen)…")
        make_self_signed(tmp_pfx, args.name.replace('"', ''), args.pfx_pass)
        args.pfx = tmp_pfx

    try:
        print("[1/5] compiling stub…");      stub = compile_stub(args, ident, ver_csv)
        if args.sign and args.sign_mode == "stub":
            print("[2/5] signing stub…");     sign_file(stub, args)
        else:
            print("[2/5] (stub signing skipped)")
        print("[3/5] zipping Release…")
        zpath = args.out + ".payload.zip"
        zip_release(args.src, zpath, exclude_top)

        print("[4/5] assembling portable…")
        with open(args.out, "wb") as out:
            with open(stub, "rb") as f: out.write(f.read())
            zip_off = out.tell()
            with open(zpath, "rb") as f: shutil.copyfileobj(f, out, 1 << 20)
            out.write(MAGIC + struct.pack("<QQ", zip_off, build_id))
        os.remove(zpath)
        mb = os.path.getsize(args.out) / (1024 * 1024)
        print(f"  -> {args.out}  ({mb:.1f} MB, build_id={build_id})")

        if args.sign and args.sign_mode == "full":
            print("[5/5] signing final exe…"); sign_file(args.out, args)
            verify_file(args.out)
        elif args.sign:
            print("[5/5] verifying stub signature carried through…")
            verify_file(args.out)
        else:
            print("[5/5] (unsigned — relies on load-in-place to avoid SmartScreen installer flag)")
        print("OK — single portable exe: loads in place, no install, no UAC.")
    finally:
        if tmp_pfx and os.path.exists(tmp_pfx): os.remove(tmp_pfx)

if __name__ == "__main__":
    main()
