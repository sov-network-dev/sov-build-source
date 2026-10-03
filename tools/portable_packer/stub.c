// tools/portable_packer/stub.c
// GENERIC single-exe portable loader — the PyInstaller-style "load like a native
// app" pattern (no install, no UAC, no registry). App-agnostic: the inner exe
// name and cache folder are COMPILE-TIME parameters (-DAPP_EXE / -DAPP_CACHE),
// so one source serves every app — no C editing per project.
//
//   1. The packer appends a ZIP of the app's Release folder to this stub, then a
//      24-byte footer:  8B magic | 8B zip_offset | 8B build_id  (little-endian).
//   2. On run, extract the ZIP into %LOCALAPPDATA%\<APP_CACHE>\<buildid>\ ONCE
//      (skipped on later runs via a .ready marker), then launch <APP_EXE>.
//   asInvoker manifest (linked via stub.manifest) => never prompts for elevation.
//
// SIGNING-ROBUST: the footer is located by scanning the tail of the file BACKWARD
// for the magic, not by assuming it is the literal last 24 bytes. So this works
// whether you (a) sign the stub then append the payload [footer stays last], or
// (b) assemble everything then Authenticode-sign the final exe [the signature's
// certificate table is appended AFTER the footer]. Either way the loader finds it.
//
// CLI passthrough: `App.exe --cli <command>` forwards args to the inner exe,
// inherits the caller's stdio, waits, and returns the child's exit code. In CLI
// mode fatal errors go to STDERR (never a blocking MessageBox that would hang a
// headless/scripted invocation).
#include <windows.h>
#include <shlobj.h>
#include <string.h>

// ── App parameters (overridable at compile time via /D) ─────────────────────
#ifndef APP_EXE
#define APP_EXE   L"SovNode.exe"   // the real Flutter exe inside the Release zip
#endif
#ifndef APP_CACHE
#define APP_CACHE L"SovNode"       // -> %LOCALAPPDATA%\<APP_CACHE>\<buildid> dir
#endif

// Footer: 8 bytes magic | 8 bytes zip_offset | 8 bytes build_id (little-endian).
#define FOOTER_LEN 24
#define SCAN_MAX   (1 << 20)       // search the last 1 MB for the footer magic
static const unsigned char MAGIC[8] = { 'S','O','V','P','K',1,0,0 };

static int g_cli = 0;
static wchar_t g_logpath[MAX_PATH];   // %LOCALAPPDATA%\<APP_CACHE>\stub.log (set once base dir is known)

// Non-fatal problem: append a timestamped line to stub.log (+ stderr in CLI mode)
// and keep going. Never blocks — a warning must not stall a GUI launch.
static void log_note(const wchar_t* msg) {
    SYSTEMTIME st; GetLocalTime(&st);
    wchar_t line[900];
    wsprintfW(line, L"%04u-%02u-%02u %02u:%02u:%02u  %s\r\n",
              st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, msg);
    char buf[2048];
    int n = WideCharToMultiByte(CP_UTF8, 0, line, -1, buf, (int)sizeof(buf), NULL, NULL);
    if (n <= 1) return;
    n--;  // drop the trailing NUL
    if (g_logpath[0]) {
        HANDLE hl = CreateFileW(g_logpath, FILE_APPEND_DATA, FILE_SHARE_READ, NULL,
                                OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hl != INVALID_HANDLE_VALUE) {
            DWORD w; WriteFile(hl, buf, (DWORD)n, &w, NULL);
            CloseHandle(hl);
        }
    }
    if (g_cli) {
        HANDLE he = GetStdHandle(STD_ERROR_HANDLE);
        if (he && he != INVALID_HANDLE_VALUE) { DWORD w; WriteFile(he, buf, (DWORD)n, &w, NULL); }
    }
}

// Fatal error. CLI mode → stderr + exit (no dialog, never blocks). GUI → MessageBox.
static void die(const wchar_t* msg) {
    if (g_cli) {
        HANDLE he = GetStdHandle(STD_ERROR_HANDLE);
        if (he && he != INVALID_HANDLE_VALUE) {
            char buf[512];
            int n = WideCharToMultiByte(CP_UTF8, 0, msg, -1, buf,
                                        (int)sizeof(buf) - 2, NULL, NULL);
            if (n > 0) {
                if (buf[n - 1] == '\0') n--;
                buf[n++] = '\n';
                DWORD w; WriteFile(he, buf, (DWORD)n, &w, NULL);
            }
        }
        ExitProcess(1);
    }
    MessageBoxW(NULL, msg, APP_CACHE, MB_ICONERROR | MB_OK);
    ExitProcess(1);
}

static int run_wait(wchar_t* cmd, const wchar_t* workdir) {
    STARTUPINFOW si; PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, 0, NULL, workdir, &si, &pi))
        return -1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0; GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    return (int)code;
}

int WINAPI wWinMain(HINSTANCE hI, HINSTANCE hP, PWSTR pCmd, int nShow) {
    (void)hI; (void)hP; (void)nShow;

    g_cli = (pCmd && wcsstr(pCmd, L"--cli") != NULL);

    // ── Locate this exe ──────────────────────────────────────────────────────
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(NULL, self, MAX_PATH);

    HANDLE hf = CreateFileW(self, GENERIC_READ, FILE_SHARE_READ, NULL,
                            OPEN_EXISTING, 0, NULL);
    if (hf == INVALID_HANDLE_VALUE) die(L"Cannot open self.");
    LARGE_INTEGER fsz; GetFileSizeEx(hf, &fsz);

    // ── Find the footer by scanning the tail BACKWARD for the magic ───────────
    // (Robust to an Authenticode certificate table appended after the footer.)
    DWORD scanlen = (DWORD)(fsz.QuadPart < SCAN_MAX ? fsz.QuadPart : SCAN_MAX);
    static unsigned char tail[SCAN_MAX];
    LARGE_INTEGER pos; pos.QuadPart = fsz.QuadPart - (LONGLONG)scanlen;
    SetFilePointerEx(hf, pos, NULL, FILE_BEGIN);
    DWORD rd = 0;
    ReadFile(hf, tail, scanlen, &rd, NULL);
    if (rd < FOOTER_LEN) die(L"This build is not packaged correctly (too small).");

    long long fi = -1;
    for (long long i = (long long)rd - FOOTER_LEN; i >= 0; --i) {
        if (memcmp(tail + i, MAGIC, 8) == 0) { fi = i; break; }   // last occurrence
    }
    if (fi < 0) die(L"This build is not packaged correctly (missing payload).");

    unsigned long long zip_off = 0, build_id = 0;
    memcpy(&zip_off,  tail + fi + 8,  8);
    memcpy(&build_id, tail + fi + 16, 8);
    unsigned long long footer_abs =
        (unsigned long long)(fsz.QuadPart - (LONGLONG)scanlen) + (unsigned long long)fi;

    // ── Cache dir: %LOCALAPPDATA%\<APP_CACHE>\<build_id> ─────────────────────
    wchar_t local[MAX_PATH];
    if (FAILED(SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, 0, local)))
        die(L"Cannot resolve LocalAppData.");
    wchar_t cache[MAX_PATH];
    wsprintfW(cache, L"%s\\%s\\%I64u", local, APP_CACHE, build_id);

    wchar_t base[MAX_PATH];
    wsprintfW(base, L"%s\\%s", local, APP_CACHE);
    CreateDirectoryW(base, NULL);
    CreateDirectoryW(cache, NULL);
    wsprintfW(g_logpath, L"%s\\stub.log", base);

    wchar_t marker[MAX_PATH];
    wsprintfW(marker, L"%s\\.ready", cache);

    // Serialize cold-start extraction across concurrent invocations.
    wchar_t mtxname[200];
    wsprintfW(mtxname, L"Local\\%sExtract_%I64u", APP_CACHE, build_id);
    HANDLE hmtx = CreateMutexW(NULL, FALSE, mtxname);
    if (hmtx) WaitForSingleObject(hmtx, 120000);

    if (GetFileAttributesW(marker) == INVALID_FILE_ATTRIBUTES) {
        // Write the appended zip slice to %TEMP%, then tar -xf into cache.
        wchar_t tmp[MAX_PATH], zippath[MAX_PATH];
        GetTempPathW(MAX_PATH, tmp);
        wsprintfW(zippath, L"%s%spk_%I64u_%lu.zip", tmp, APP_CACHE, build_id,
                  GetCurrentProcessId());

        HANDLE ho = CreateFileW(zippath, GENERIC_WRITE, 0, NULL,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (ho == INVALID_HANDLE_VALUE) {
            if (hmtx) { ReleaseMutex(hmtx); CloseHandle(hmtx); }
            die(L"Cannot write temp payload.");
        }
        pos.QuadPart = (LONGLONG)zip_off;
        SetFilePointerEx(hf, pos, NULL, FILE_BEGIN);
        unsigned long long remaining = footer_abs - zip_off;  // payload bytes only
        static unsigned char buf[1 << 20];
        while (remaining) {
            DWORD want = (DWORD)(remaining < sizeof(buf) ? remaining : sizeof(buf));
            DWORD got = 0, put = 0;
            if (!ReadFile(hf, buf, want, &got, NULL) || got == 0) break;
            WriteFile(ho, buf, got, &put, NULL);
            remaining -= got;
        }
        CloseHandle(ho);

        wchar_t sys[MAX_PATH]; GetSystemDirectoryW(sys, MAX_PATH);
        wchar_t cmd[MAX_PATH * 3];
        wsprintfW(cmd, L"\"%s\\tar.exe\" -xf \"%s\" -C \"%s\"", sys, zippath, cache);
        int rc = run_wait(cmd, NULL);
        DeleteFileW(zippath);
        if (rc != 0) {
            // tar can exit nonzero on "Can't unlink already-existing object" when a
            // running instance holds locks on cache files. The cache is keyed by
            // build_id, so locked files already contain the exact bytes we were
            // writing — if the inner exe is present, launch it instead of dying.
            // .ready is withheld so a later (unlocked) launch completes extraction.
            wchar_t probe[MAX_PATH];
            wsprintfW(probe, L"%s\\%s", cache, APP_EXE);
            if (GetFileAttributesW(probe) == INVALID_FILE_ATTRIBUTES) {
                if (hmtx) { ReleaseMutex(hmtx); CloseHandle(hmtx); }
                die(L"Failed to unpack the app payload.");
            }
            log_note(L"WARN: extraction exited nonzero but the inner exe is already "
                     L"in the cache (files likely locked by a running instance); "
                     L"launching the existing copy. .ready withheld; extraction "
                     L"will be retried on a later launch.");
        } else {
            // A failed .ready write must not be silent: without the marker every
            // launch re-extracts, and a locked cache then bricks relaunches.
            HANDLE hm = INVALID_HANDLE_VALUE;
            for (int attempt = 0; attempt < 5; ++attempt) {
                hm = CreateFileW(marker, GENERIC_WRITE, 0, NULL,
                                 CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
                if (hm != INVALID_HANDLE_VALUE) break;
                Sleep(200);
            }
            if (hm != INVALID_HANDLE_VALUE) CloseHandle(hm);
            else log_note(L"WARN: could not write the .ready marker after 5 attempts; "
                          L"every launch will re-extract until it can be written.");
        }
    }
    CloseHandle(hf);
    if (hmtx) { ReleaseMutex(hmtx); CloseHandle(hmtx); }

    // ── Launch <APP_EXE> from the cache (working dir = cache) ─────────────────
    wchar_t app[MAX_PATH];
    wsprintfW(app, L"%s\\%s", cache, APP_EXE);
    if (GetFileAttributesW(app) == INVALID_FILE_ATTRIBUTES)
        die(L"Unpacked app is incomplete (inner exe missing).");

    // Tell the inner app where the portable exe lives (inherited env var).
    // The cache path changes every build_id, so anything the app persists
    // pointing at itself (shell verbs, shortcuts, protocol handlers) should
    // use this stable path instead of its own resolved executable.
    SetEnvironmentVariableW(L"PORTABLE_STUB_EXE", self);

    static wchar_t launch[40000];
    launch[0] = L'"';
    lstrcpyW(launch + 1, app);
    lstrcatW(launch, L"\"");
    if (pCmd && pCmd[0]) { lstrcatW(launch, L" "); lstrcatW(launch, pCmd); }

    STARTUPINFOW si; PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));
    BOOL inherit = FALSE;
    if (g_cli) {
        si.dwFlags    = STARTF_USESTDHANDLES;
        si.hStdInput  = GetStdHandle(STD_INPUT_HANDLE);
        si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
        si.hStdError  = GetStdHandle(STD_ERROR_HANDLE);
        inherit = TRUE;
    }
    if (!CreateProcessW(NULL, launch, NULL, NULL, inherit, 0, NULL, cache, &si, &pi))
        die(L"Could not launch the app.");
    if (g_cli) {
        WaitForSingleObject(pi.hProcess, INFINITE);
        DWORD code = 0; GetExitCodeProcess(pi.hProcess, &code);
        CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
        return (int)code;
    }
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    return 0;
}
