#include <windows.h>
#include <stdlib.h>
#include <wchar.h>

static int run_target(const WCHAR *executable, const WCHAR *output_path, BOOL explicit_environment)
{
    STARTUPINFOW startup = { .cb = sizeof(startup) };
    PROCESS_INFORMATION process = { 0 };
    WCHAR *command_line;
    WCHAR *environment = NULL;
    DWORD command_size, exit_code = 1;
    BOOL created;

    command_size = (DWORD)(wcslen(executable) + wcslen(output_path) + 8);
    command_line = calloc(command_size, sizeof(WCHAR));
    if (!command_line) return 40;
    swprintf(command_line, command_size, L"\"%ls\" \"%ls\"", executable, output_path);
    if (explicit_environment) environment = GetEnvironmentStringsW();
    created = CreateProcessW(
        executable,
        command_line,
        NULL,
        NULL,
        FALSE,
        explicit_environment ? CREATE_UNICODE_ENVIRONMENT : 0,
        environment,
        NULL,
        &startup,
        &process
    );
    if (environment) FreeEnvironmentStringsW(environment);
    free(command_line);
    if (!created) return 41;
    if (WaitForSingleObject(process.hProcess, 30000) != WAIT_OBJECT_0) {
        TerminateProcess(process.hProcess, 42);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        return 42;
    }
    if (!GetExitCodeProcess(process.hProcess, &exit_code)) exit_code = 43;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return (int)exit_code;
}

int wmain(int argc, WCHAR **argv)
{
    int index, result;

    if (argc == 3) return run_target(argv[1], argv[2], FALSE);
    if (argc < 7 || !(argc & 1)) return 50;
    for (index = 1; index < argc; index += 2)
    {
        /* Preserve explicit-environment coverage for the second child while
         * allowing the policy fixture to add independently scoped helpers. */
        result = run_target(argv[index], argv[index + 1], index == 3);
        if (result) return result;
    }
    return 0;
}
