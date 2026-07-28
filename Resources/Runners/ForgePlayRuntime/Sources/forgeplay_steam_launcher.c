#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <stdbool.h>
#include <stdlib.h>
#include <wchar.h>
#include <windows.h>
#include <shellapi.h>

/*
 * ForgePlay-owned Windows Steam child launcher.
 *
 * This program has a deliberately small ForgePlay-specific interface. It
 * starts the requested Windows executable through CreateProcessW and can
 * return after successful creation so the macOS app does not block on the
 * Steam client lifetime. Its complete command contract is the project-owned
 * `--detach -- <Windows command...>` interface implemented below.
 */

static bool argument_equals(const wchar_t *argument, const wchar_t *expected)
{
    return _wcsicmp(argument, expected) == 0;
}

static size_t windows_quoted_argument_length(const wchar_t *argument)
{
    size_t length = 2;
    size_t backslashes = 0;

    for (const wchar_t *cursor = argument; *cursor; ++cursor)
    {
        if (*cursor == L'\\')
        {
            ++backslashes;
            continue;
        }
        if (*cursor == L'"')
        {
            length += backslashes * 2 + 2;
            backslashes = 0;
            continue;
        }
        length += backslashes + 1;
        backslashes = 0;
    }

    return length + backslashes * 2;
}

static wchar_t *append_windows_quoted_argument(wchar_t *output, const wchar_t *argument)
{
    size_t backslashes = 0;
    *output++ = L'"';

    for (const wchar_t *cursor = argument; *cursor; ++cursor)
    {
        if (*cursor == L'\\')
        {
            ++backslashes;
            continue;
        }

        if (*cursor == L'"')
        {
            size_t escaped_backslashes = backslashes * 2 + 1;
            while (escaped_backslashes > 0)
            {
                *output++ = L'\\';
                --escaped_backslashes;
            }
            *output++ = L'"';
            backslashes = 0;
            continue;
        }

        while (backslashes > 0)
        {
            *output++ = L'\\';
            --backslashes;
        }
        *output++ = *cursor;
    }

    size_t trailing_backslashes = backslashes * 2;
    while (trailing_backslashes > 0)
    {
        *output++ = L'\\';
        --trailing_backslashes;
    }
    *output++ = L'"';
    return output;
}

static wchar_t *build_windows_command_line(int argc, wchar_t **argv, int first_target_argument)
{
    size_t length = 1;
    for (int index = first_target_argument; index < argc; ++index)
        length += windows_quoted_argument_length(argv[index]) + 1;

    wchar_t *command_line = (wchar_t *)calloc(length, sizeof(wchar_t));
    if (!command_line) return NULL;

    wchar_t *output = command_line;
    for (int index = first_target_argument; index < argc; ++index)
    {
        if (index != first_target_argument) *output++ = L' ';
        output = append_windows_quoted_argument(output, argv[index]);
    }
    *output = 0;
    return command_line;
}

static bool standard_handle_is_valid(HANDLE handle)
{
    return handle && handle != INVALID_HANDLE_VALUE;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous_instance, PWSTR command, int show_command)
{
    (void)instance;
    (void)previous_instance;
    (void)command;

    int argc = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) return 2;
    if (argc < 2)
    {
        LocalFree(argv);
        return 2;
    }

    bool detach_after_creation = false;
    int first_target_argument = 1;

    for (; first_target_argument < argc; ++first_target_argument)
    {
        if (argument_equals(argv[first_target_argument], L"--"))
        {
            ++first_target_argument;
            break;
        }
        if (argument_equals(argv[first_target_argument], L"--detach"))
        {
            detach_after_creation = true;
            continue;
        }
        LocalFree(argv);
        return 2;
    }

    if (first_target_argument >= argc)
    {
        LocalFree(argv);
        return 2;
    }

    wchar_t *target_command_line = build_windows_command_line(argc, argv, first_target_argument);
    if (!target_command_line)
    {
        LocalFree(argv);
        return 3;
    }

    STARTUPINFOW startup_info;
    PROCESS_INFORMATION process_info;
    ZeroMemory(&startup_info, sizeof(startup_info));
    ZeroMemory(&process_info, sizeof(process_info));
    startup_info.cb = sizeof(startup_info);
    startup_info.dwFlags = STARTF_USESHOWWINDOW;
    startup_info.wShowWindow = (WORD)show_command;

    HANDLE stdin_handle = GetStdHandle(STD_INPUT_HANDLE);
    HANDLE stdout_handle = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE stderr_handle = GetStdHandle(STD_ERROR_HANDLE);
    if (standard_handle_is_valid(stdin_handle) ||
        standard_handle_is_valid(stdout_handle) ||
        standard_handle_is_valid(stderr_handle))
    {
        startup_info.dwFlags |= STARTF_USESTDHANDLES;
        startup_info.hStdInput = standard_handle_is_valid(stdin_handle) ? stdin_handle : NULL;
        startup_info.hStdOutput = standard_handle_is_valid(stdout_handle) ? stdout_handle : NULL;
        startup_info.hStdError = standard_handle_is_valid(stderr_handle) ? stderr_handle : NULL;
    }

    BOOL created = CreateProcessW(
        argv[first_target_argument],
        target_command_line,
        NULL,
        NULL,
        TRUE,
        0,
        NULL,
        NULL,
        &startup_info,
        &process_info
    );
    DWORD exit_code = created ? 0 : GetLastError();

    if (created)
    {
        if (!detach_after_creation)
        {
            WaitForSingleObject(process_info.hProcess, INFINITE);
            GetExitCodeProcess(process_info.hProcess, &exit_code);
        }
        CloseHandle(process_info.hThread);
        CloseHandle(process_info.hProcess);
    }

    free(target_command_line);
    LocalFree(argv);
    return (int)exit_code;
}
