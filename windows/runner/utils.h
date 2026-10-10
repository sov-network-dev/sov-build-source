#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// D67: is a standard stream a pipe or a file? Must be asked BEFORE AttachConsole (after it, Windows reports
// the console for a redirected stream too).
bool StdHandleIsRedirected(unsigned long which);

// D67: after AttachConsole(ATTACH_PARENT_PROCESS), point every stream that was NOT redirected at the console,
// so a CLI command typed at a prompt prints; redirected streams keep their pipe or file.
void ReopenStdStreamsToAttachedConsole(bool out_redirected, bool err_redirected);

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_
