#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // ── Single-instance guard (GUI only) ──────────────────────────────────────
  // The SAME executable also runs a headless CLI (`--cli ...`). Those MUST run
  // alongside an open GUI (and each other), so the guard is skipped whenever
  // `--cli` is present. For the GUI, a named mutex ensures only one window: a
  // second launch focuses the existing window and exits, preventing the
  // concurrent secure-storage races and node-port conflicts two GUIs cause.
  const bool is_cli =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                std::string("--cli")) != command_line_arguments.end();
  HANDLE single_instance_mutex = nullptr;
  if (!is_cli) {
    single_instance_mutex =
        ::CreateMutexW(nullptr, TRUE, L"SOV_Node_Single_Instance_GUI");
    if (single_instance_mutex != nullptr &&
        ::GetLastError() == ERROR_ALREADY_EXISTS) {
      // A GUI is already running — surface it (even if minimised to tray) and exit.
      HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"SOV Node");
      if (existing == nullptr) existing = ::FindWindowW(nullptr, L"SOV Node");
      if (existing != nullptr) {
        if (::IsIconic(existing)) {
          ::ShowWindow(existing, SW_RESTORE);
        } else {
          ::ShowWindow(existing, SW_SHOW);
        }
        ::SetForegroundWindow(existing);
      }
      ::CloseHandle(single_instance_mutex);
      return EXIT_SUCCESS;
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"SOV Node", origin, size)) {
    return EXIT_FAILURE;
  }
  // Close-to-tray is handled in Dart via window_manager (setPreventClose) so the
  // bundled full node keeps serving when the window is closed. Do NOT quit the
  // process on window close here.
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);  // OS also releases it on process exit
  }
  return EXIT_SUCCESS;
}
