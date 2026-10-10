#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

bool StdHandleIsRedirected(DWORD which) {
  HANDLE h = ::GetStdHandle(which);
  if (h == nullptr || h == INVALID_HANDLE_VALUE) return false;
  const DWORD t = ::GetFileType(h);
  return t == FILE_TYPE_PIPE || t == FILE_TYPE_DISK;
}

void ReopenStdStreamsToAttachedConsole(bool out_redirected, bool err_redirected) {
  // D67: the caller samples redirection BEFORE AttachConsole. After attaching, Windows reports the console
  // (FILE_TYPE_CHAR) even for a stream that was piped or sent to a file (measured 2026-10-10), so a check made
  // here cannot tell them apart: v1.2.30 skipped the console case (nothing printed at a prompt), and a later
  // attempt that reopened it stole the output from pipes and files. A redirected stream is left alone.
  bool changed = false;
  FILE *unused;
  if (!out_redirected && freopen_s(&unused, "CONOUT$", "w", stdout) == 0) {
    _dup2(_fileno(stdout), 1);
    // Dart's stdout writes to the Win32 standard handle, not to the C runtime stream: point it here too.
    ::SetStdHandle(STD_OUTPUT_HANDLE, reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(stdout))));
    changed = true;
  }
  if (!err_redirected && freopen_s(&unused, "CONOUT$", "w", stderr) == 0) {
    _dup2(_fileno(stderr), 2);
    ::SetStdHandle(STD_ERROR_HANDLE, reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(stderr))));
    changed = true;
  }
  if (changed) {
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  unsigned int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr)
    -1; // remove the trailing null character
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length == 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
