#include <windows.h>

/*
 * Initialize Wine's shared desktop from a base-runtime process before a
 * renderer-scoped game child starts. ForgePlay's production order is the
 * same: Steam owns the base Wine UI session, then launches the selected game.
 */
int wmain(void)
{
    static const WCHAR class_name[] = L"ForgePlayBaseDesktopInitializer";
    WNDCLASSW window_class = { 0 };
    HINSTANCE instance = GetModuleHandleW(NULL);
    HWND window;

    window_class.lpfnWndProc = DefWindowProcW;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    if (!RegisterClassW(&window_class)) return 60;

    window = CreateWindowExW(
        0,
        class_name,
        L"ForgePlay base desktop initializer",
        WS_OVERLAPPED,
        0,
        0,
        32,
        32,
        NULL,
        NULL,
        instance,
        NULL
    );
    if (!window)
    {
        UnregisterClassW(class_name, instance);
        return 61;
    }

    DestroyWindow(window);
    UnregisterClassW(class_name, instance);
    return 0;
}
