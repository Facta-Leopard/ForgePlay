#define COBJMACROS

#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_2.h>
#include <setupapi.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#define FORGEPLAY_NGX_RESULT_SUCCESS 0x00000001u
#define FORGEPLAY_NGX_RESULT_NOT_INVOKED UINT32_MAX
#define FORGEPLAY_NGX_VERSION_API 0x00000015u
#define FORGEPLAY_NGX_FEATURE_SUPER_SAMPLING 1u
#define FORGEPLAY_NGX_ENGINE_TYPE_CUSTOM 0
#define FORGEPLAY_NGX_DIAGNOSTIC_PROJECT_ID \
    "8c98e13d-0cc2-4a52-91bb-3f662b173ed0"
#define FORGEPLAY_NGX_DIAGNOSTIC_ENGINE_VERSION "1.0.0"
#define FORGEPLAY_NGX_PERF_QUALITY_MAX_PERFORMANCE 0
#define FORGEPLAY_NGX_DLSS_FEATURE_FLAG_MV_LOW_RES (1u << 1)
#define FORGEPLAY_NGXCORE_REGISTRY_PATH \
    L"SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore"
#define FORGEPLAY_NGXCORE_FULL_PATH_VALUE L"FullPath"
#define FORGEPLAY_NGX_DRIVER_REGISTRY_PATH \
    L"SYSTEM\\CurrentControlSet\\Services\\nvlddmkm\\NGXCore"
#define FORGEPLAY_NGX_DRIVER_PATH_VALUE L"NGXPath"
#define FORGEPLAY_NVAPI_OK 0
#define FORGEPLAY_NVAPI_INITIALIZE_ID 0x0150e828u
#define FORGEPLAY_NVAPI_ENUM_PHYSICAL_GPUS_ID 0xe5ac921fu
#define FORGEPLAY_NVAPI_SYS_GET_DRIVER_AND_BRANCH_VERSION_ID 0x2926aaadu
#define FORGEPLAY_NVAPI_MAX_PHYSICAL_GPUS 64u
#define FORGEPLAY_NVAPI_SHORT_STRING_MAX 64u

/* The bundled bridge exposes Init_ProjectID as the export alias for NVIDIA's
 * public seven-argument Init_with_ProjectID contract. */
typedef struct forgeplay_ngx_feature_common_info
    forgeplay_ngx_feature_common_info;
typedef uint32_t (__cdecl *forgeplay_ngx_d3d12_init_project_id_fn)(
    const char *,
    int,
    const char *,
    const WCHAR *,
    ID3D12Device *,
    const forgeplay_ngx_feature_common_info *,
    uint32_t
);
typedef uint32_t (__cdecl *forgeplay_ngx_parameters_fn)(void **);
typedef uint32_t (__cdecl *forgeplay_ngx_destroy_parameters_fn)(void *);
typedef uint32_t (__cdecl *forgeplay_ngx_d3d12_shutdown_fn)(ID3D12Device *);
typedef struct forgeplay_ngx_parameter forgeplay_ngx_parameter;
typedef struct forgeplay_ngx_handle forgeplay_ngx_handle;
typedef struct forgeplay_ngx_parameter_vtable
{
    void (__cdecl *set_unsigned_long_long)(
        forgeplay_ngx_parameter *, const char *, unsigned long long);
    void (__cdecl *set_float)(forgeplay_ngx_parameter *, const char *, float);
    void (__cdecl *set_double)(forgeplay_ngx_parameter *, const char *, double);
    void (__cdecl *set_unsigned_int)(
        forgeplay_ngx_parameter *, const char *, unsigned int);
    void (__cdecl *set_int)(forgeplay_ngx_parameter *, const char *, int);
    void (__cdecl *set_d3d11_resource)(
        forgeplay_ngx_parameter *, const char *, ID3D11Resource *);
    void (__cdecl *set_d3d12_resource)(
        forgeplay_ngx_parameter *, const char *, ID3D12Resource *);
    void (__cdecl *set_void_pointer)(
        forgeplay_ngx_parameter *, const char *, void *);
    uint32_t (__cdecl *get_unsigned_long_long)(
        const forgeplay_ngx_parameter *, const char *, unsigned long long *);
    uint32_t (__cdecl *get_float)(
        const forgeplay_ngx_parameter *, const char *, float *);
    uint32_t (__cdecl *get_double)(
        const forgeplay_ngx_parameter *, const char *, double *);
    uint32_t (__cdecl *get_unsigned_int)(
        const forgeplay_ngx_parameter *, const char *, unsigned int *);
    uint32_t (__cdecl *get_int)(
        const forgeplay_ngx_parameter *, const char *, int *);
    uint32_t (__cdecl *get_d3d11_resource)(
        const forgeplay_ngx_parameter *, const char *, ID3D11Resource **);
    uint32_t (__cdecl *get_d3d12_resource)(
        const forgeplay_ngx_parameter *, const char *, ID3D12Resource **);
    uint32_t (__cdecl *get_void_pointer)(
        const forgeplay_ngx_parameter *, const char *, void **);
    void (__cdecl *reset)(forgeplay_ngx_parameter *);
} forgeplay_ngx_parameter_vtable;
struct forgeplay_ngx_parameter
{
    const forgeplay_ngx_parameter_vtable *methods;
};
typedef uint32_t (__cdecl *forgeplay_ngx_d3d11_init_project_id_fn)(
    const char *,
    int,
    const char *,
    const WCHAR *,
    ID3D11Device *,
    const forgeplay_ngx_feature_common_info *,
    uint32_t
);
typedef uint32_t (__cdecl *forgeplay_ngx_d3d11_create_feature_fn)(
    ID3D11DeviceContext *,
    uint32_t,
    forgeplay_ngx_parameter *,
    forgeplay_ngx_handle **
);
typedef uint32_t (__cdecl *forgeplay_ngx_d3d11_evaluate_feature_fn)(
    ID3D11DeviceContext *,
    const forgeplay_ngx_handle *,
    forgeplay_ngx_parameter *,
    void *
);
typedef uint32_t (__cdecl *forgeplay_ngx_release_feature_fn)(
    forgeplay_ngx_handle *
);
typedef uint32_t (__cdecl *forgeplay_ngx_dlss_optimal_settings_callback_fn)(
    forgeplay_ngx_parameter *
);
typedef uint32_t (__cdecl *forgeplay_ngx_d3d11_shutdown_fn)(ID3D11Device *);
typedef void *(__cdecl *forgeplay_nvapi_query_interface_fn)(uint32_t);
typedef int (__cdecl *forgeplay_nvapi_initialize_fn)(void);
typedef int (__cdecl *forgeplay_nvapi_enum_physical_gpus_fn)(
    void **,
    uint32_t *
);
typedef int (__cdecl *forgeplay_nvapi_get_driver_and_branch_version_fn)(
    uint32_t *,
    char *
);

static BOOL load_procedure(
    HMODULE module,
    const char *name,
    void *destination,
    size_t destination_size
)
{
    FARPROC procedure = GetProcAddress(module, name);

    if (!procedure || destination_size != sizeof(procedure)) return FALSE;
    memcpy(destination, &procedure, sizeof(procedure));
    return TRUE;
}

static const GUID forgeplay_iid_idxgi_factory1 =
    {0x770aae78, 0xf26f, 0x4dba, {0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87}};
static const GUID forgeplay_iid_id3d12_device =
    {0x189819f1, 0x1db6, 0x4b57, {0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7}};
static const GUID forgeplay_iid_id3d11_device =
    {0xdb6f6ddb, 0xac77, 0x4e88, {0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40}};
static const GUID forgeplay_iid_idxgi_device =
    {0x54ec77fa, 0x1377, 0x44e6, {0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c}};
static const GUID forgeplay_guid_devclass_display =
    {0x4d36e968, 0xe325, 0x11ce, {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}};

static void write_environment(FILE *output, const WCHAR *name)
{
    WCHAR wide_value[32768];
    char utf8_value[32768];
    DWORD length;
    int utf8_length;

    length = GetEnvironmentVariableW(name, wide_value, ARRAYSIZE(wide_value));
    if (!length || length >= ARRAYSIZE(wide_value))
    {
        fprintf(output, "%ls=\n", name);
        return;
    }
    utf8_length = WideCharToMultiByte(
        CP_UTF8,
        0,
        wide_value,
        length,
        utf8_value,
        ARRAYSIZE(utf8_value) - 1,
        NULL,
        NULL
    );
    if (!utf8_length)
    {
        fprintf(output, "%ls_utf8_error=%lu\n", name, GetLastError());
        return;
    }
    utf8_value[utf8_length] = 0;
    fprintf(output, "%ls=%s\n", name, utf8_value);
}

static void write_module_path(FILE *output, const char *label, HMODULE module)
{
    WCHAR wide_path[32768];
    char utf8_path[32768];
    DWORD length;
    int utf8_length;

    if (!module)
    {
        fprintf(output, "%s_module_error=%lu\n", label, GetLastError());
        return;
    }
    length = GetModuleFileNameW(module, wide_path, ARRAYSIZE(wide_path));
    if (!length || length >= ARRAYSIZE(wide_path))
    {
        fprintf(output, "%s_module_error=%lu\n", label, GetLastError());
        return;
    }
    utf8_length = WideCharToMultiByte(
        CP_UTF8,
        0,
        wide_path,
        length,
        utf8_path,
        ARRAYSIZE(utf8_path) - 1,
        NULL,
        NULL
    );
    if (!utf8_length)
    {
        fprintf(output, "%s_module_utf8_error=%lu\n", label, GetLastError());
        return;
    }
    utf8_path[utf8_length] = 0;
    fprintf(output, "%s_module=%s\n", label, utf8_path);
}

static void write_wide_value(
    FILE *output,
    const char *label,
    const WCHAR *wide_value
)
{
    char utf8_value[32768];
    int utf8_length;

    utf8_length = WideCharToMultiByte(
        CP_UTF8,
        0,
        wide_value,
        -1,
        utf8_value,
        ARRAYSIZE(utf8_value),
        NULL,
        NULL
    );
    if (!utf8_length)
    {
        fprintf(output, "%s_utf8_error=%lu\n", label, GetLastError());
        return;
    }
    fprintf(output, "%s=%s\n", label, utf8_value);
}

static LSTATUS query_registry_string(
    FILE *output,
    const char *label,
    const WCHAR *registry_path,
    const WCHAR *value_name,
    REGSAM registry_view,
    WCHAR *value,
    DWORD value_capacity
)
{
    HKEY key = NULL;
    DWORD type = 0;
    DWORD byte_count = value_capacity * sizeof(*value);
    LSTATUS open_status;
    LSTATUS query_status = ERROR_FILE_NOT_FOUND;

    if (value_capacity) value[0] = 0;
    open_status = RegOpenKeyExW(
        HKEY_LOCAL_MACHINE,
        registry_path,
        0,
        KEY_READ | registry_view,
        &key
    );
    fprintf(output, "%s_open_status=%ld\n", label, (long)open_status);
    if (open_status == ERROR_SUCCESS)
    {
        query_status = RegQueryValueExW(
            key,
            value_name,
            NULL,
            &type,
            (BYTE *)value,
            &byte_count
        );
        RegCloseKey(key);
    }
    fprintf(output, "%s_query_status=%ld\n", label, (long)query_status);
    fprintf(output, "%s_type=%lu\n", label, (unsigned long)type);
    if (query_status == ERROR_SUCCESS &&
        (type == REG_SZ || type == REG_EXPAND_SZ) &&
        byte_count >= sizeof(*value) &&
        value_capacity)
    {
        value[value_capacity - 1] = 0;
        write_wide_value(output, label, value);
    }
    return query_status;
}

static void write_adapter_description(FILE *output, const DXGI_ADAPTER_DESC1 *description)
{
    char utf8_description[512];
    int utf8_length;

    utf8_length = WideCharToMultiByte(
        CP_UTF8,
        0,
        description->Description,
        -1,
        utf8_description,
        ARRAYSIZE(utf8_description),
        NULL,
        NULL
    );
    if (!utf8_length)
    {
        fprintf(output, "adapter_description_utf8_error=%lu\n", GetLastError());
        return;
    }
    fprintf(output, "adapter_description=%s\n", utf8_description);
}

static void write_setupapi_display_identity(FILE *output)
{
    HDEVINFO devices;
    SP_DEVINFO_DATA device;
    WCHAR description[512];
    WCHAR hardware_ids[1024];
    WCHAR driver_key[512];
    WCHAR class_path[1024];
    WCHAR driver_version[128];
    DWORD type = 0;
    DWORD required = 0;
    DWORD index;

    devices = SetupDiGetClassDevsW(
        &forgeplay_guid_devclass_display,
        NULL,
        NULL,
        DIGCF_PRESENT
    );
    if (devices == INVALID_HANDLE_VALUE)
    {
        fprintf(output, "setupapi_display_open_error=%lu\n", GetLastError());
        return;
    }

    for (index = 0; ; ++index)
    {
        ZeroMemory(&device, sizeof(device));
        device.cbSize = sizeof(device);
        if (!SetupDiEnumDeviceInfo(devices, index, &device)) break;
        if (!SetupDiGetDeviceRegistryPropertyW(
                devices,
                &device,
                SPDRP_DRIVER,
                &type,
                (BYTE *)driver_key,
                sizeof(driver_key),
                &required
            ) ||
            type != REG_SZ)
            continue;

        write_wide_value(output, "setupapi_display_driver_key", driver_key);
        if (SetupDiGetDeviceRegistryPropertyW(
                devices,
                &device,
                SPDRP_DEVICEDESC,
                &type,
                (BYTE *)description,
                sizeof(description),
                &required
            ) &&
            type == REG_SZ)
            write_wide_value(output, "setupapi_display_description", description);
        if (SetupDiGetDeviceRegistryPropertyW(
                devices,
                &device,
                SPDRP_HARDWAREID,
                &type,
                (BYTE *)hardware_ids,
                sizeof(hardware_ids),
                &required
            ) &&
            type == REG_MULTI_SZ &&
            hardware_ids[0])
            write_wide_value(output, "setupapi_display_hardware_id", hardware_ids);

        if (swprintf(
                class_path,
                ARRAYSIZE(class_path),
                L"SYSTEM\\CurrentControlSet\\Control\\Class\\%ls",
                driver_key
            ) > 0)
        {
            query_registry_string(
                output,
                "display_class_driver_version",
                class_path,
                L"DriverVersion",
                KEY_WOW64_64KEY,
                driver_version,
                ARRAYSIZE(driver_version)
            );
        }
        break;
    }
    SetupDiDestroyDeviceInfoList(devices);
}

static HWND create_probe_window(FILE *output, ATOM *window_class)
{
    static const WCHAR class_name[] = L"ForgePlayD3DMetalSwapChainProbe";
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW descriptor;
    HWND window;

    ZeroMemory(&descriptor, sizeof(descriptor));
    descriptor.style = CS_HREDRAW | CS_VREDRAW;
    descriptor.lpfnWndProc = DefWindowProcW;
    descriptor.hInstance = instance;
    descriptor.hCursor = LoadCursorW(NULL, IDC_ARROW);
    descriptor.lpszClassName = class_name;

    *window_class = RegisterClassW(&descriptor);
    if (!*window_class)
    {
        fprintf(output, "register_window_class_error=%lu\n", GetLastError());
        return NULL;
    }
    window = CreateWindowExW(
        0,
        class_name,
        L"ForgePlay D3DMetal Device Probe",
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        640,
        360,
        NULL,
        NULL,
        instance,
        NULL
    );
    if (!window)
    {
        fprintf(output, "create_window_error=%lu\n", GetLastError());
        UnregisterClassW(class_name, instance);
        *window_class = 0;
        return NULL;
    }
    ShowWindow(window, SW_SHOWNORMAL);
    UpdateWindow(window);
    fprintf(output, "window_created=1\n");
    return window;
}

static void pump_window_messages(void)
{
    MSG message;

    while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
}

static ID3D11Texture2D *create_ngx_texture(
    ID3D11Device *device,
    UINT width,
    UINT height,
    DXGI_FORMAT format,
    UINT bind_flags,
    const void *initial_data,
    UINT row_pitch
)
{
    D3D11_TEXTURE2D_DESC description;
    D3D11_SUBRESOURCE_DATA subresource;
    ID3D11Texture2D *texture = NULL;

    ZeroMemory(&description, sizeof(description));
    description.Width = width;
    description.Height = height;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = format;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = bind_flags;
    ZeroMemory(&subresource, sizeof(subresource));
    subresource.pSysMem = initial_data;
    subresource.SysMemPitch = row_pitch;
    if (FAILED(ID3D11Device_CreateTexture2D(
            device,
            &description,
            initial_data ? &subresource : NULL,
            &texture
        )))
        return NULL;
    return texture;
}

static ID3D11Texture2D *create_ngx_readback_texture(
    ID3D11Device *device,
    ID3D11Texture2D *source
)
{
    D3D11_TEXTURE2D_DESC description;
    ID3D11Texture2D *texture = NULL;

    ID3D11Texture2D_GetDesc(source, &description);
    description.Usage = D3D11_USAGE_STAGING;
    description.BindFlags = 0;
    description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    description.MiscFlags = 0;
    if (FAILED(ID3D11Device_CreateTexture2D(
            device, &description, NULL, &texture)))
        return NULL;
    return texture;
}

static BOOL query_ngx_dlss_optimal_render_size(
    forgeplay_ngx_parameter *parameters,
    const forgeplay_ngx_parameter_vtable *methods,
    UINT output_width,
    UINT output_height,
    int performance_quality,
    UINT *input_width,
    UINT *input_height,
    uint32_t *callback_query_result,
    uint32_t *callback_result
)
{
    forgeplay_ngx_dlss_optimal_settings_callback_fn callback = NULL;
    void *callback_procedure = NULL;
    uint32_t width_result;
    uint32_t height_result;
    UINT optimal_width = 0;
    UINT optimal_height = 0;

    if (!parameters || !methods || !methods->get_void_pointer ||
        !methods->get_unsigned_int || !methods->set_unsigned_int ||
        !methods->set_int || !input_width || !input_height ||
        !callback_query_result || !callback_result)
        return FALSE;

    *callback_query_result = methods->get_void_pointer(
        parameters,
        "DLSSOptimalSettingsCallback",
        &callback_procedure
    );
    if (*callback_query_result != FORGEPLAY_NGX_RESULT_SUCCESS ||
        !callback_procedure || sizeof(callback) != sizeof(callback_procedure))
        return FALSE;

    memcpy(&callback, &callback_procedure, sizeof(callback));
    methods->set_unsigned_int(parameters, "Width", output_width);
    methods->set_unsigned_int(parameters, "Height", output_height);
    methods->set_int(parameters, "PerfQualityValue", performance_quality);
    methods->set_int(parameters, "RTXValue", 0);
    *callback_result = callback(parameters);
    if (*callback_result != FORGEPLAY_NGX_RESULT_SUCCESS) return FALSE;

    width_result = methods->get_unsigned_int(
        parameters,
        "OutWidth",
        &optimal_width
    );
    height_result = methods->get_unsigned_int(
        parameters,
        "OutHeight",
        &optimal_height
    );
    if (width_result != FORGEPLAY_NGX_RESULT_SUCCESS ||
        height_result != FORGEPLAY_NGX_RESULT_SUCCESS ||
        !optimal_width || !optimal_height || optimal_width > output_width ||
        optimal_height > output_height)
        return FALSE;
    *input_width = optimal_width;
    *input_height = optimal_height;
    return TRUE;
}

int wmain(int argc, WCHAR **argv)
{
    D3D_FEATURE_LEVEL feature_levels[] = {D3D_FEATURE_LEVEL_11_0};
    D3D_FEATURE_LEVEL selected_feature_level = 0;
    DXGI_ADAPTER_DESC1 adapter_description;
    DXGI_SWAP_CHAIN_DESC swap_chain_description;
    ID3D11DeviceContext *device_context = NULL;
    ID3D11Device *device = NULL;
    ID3D12Device *device12 = NULL;
    IDXGIAdapter1 *adapter = NULL;
    IDXGIFactory1 *factory = NULL;
    IDXGISwapChain *swap_chain = NULL;
    HRESULT factory_hr = E_FAIL;
    HRESULT adapter_hr = E_FAIL;
    HRESULT device_hr = E_FAIL;
    HRESULT device12_hr = E_FAIL;
    HRESULT device12_fl12_hr = E_FAIL;
    HRESULT dxgi_interface_support_hr = E_FAIL;
    HRESULT d3d11_interface_support_hr = E_FAIL;
    HRESULT swap_chain_hr = E_FAIL;
    HRESULT present_hr = E_FAIL;
    HMODULE nvapi_module = NULL;
    forgeplay_nvapi_query_interface_fn nvapi_query_interface = NULL;
    forgeplay_nvapi_initialize_fn nvapi_initialize = NULL;
    forgeplay_nvapi_enum_physical_gpus_fn nvapi_enum_physical_gpus = NULL;
    forgeplay_nvapi_get_driver_and_branch_version_fn
        nvapi_get_driver_and_branch_version = NULL;
    void *nvapi_physical_gpus[FORGEPLAY_NVAPI_MAX_PHYSICAL_GPUS] = {0};
    uint32_t nvapi_physical_gpu_count = 0;
    uint32_t nvapi_driver_version = 0;
    char nvapi_driver_branch[FORGEPLAY_NVAPI_SHORT_STRING_MAX] = {0};
    int nvapi_initialize_result = -999;
    int nvapi_enum_after_initialize = -999;
    int nvapi_driver_version_result = -999;
    BOOL nvapi_exports_ready = FALSE;
    WCHAR metalfx_value[2];
    BOOL nvidia_compatibility_requested = FALSE;
    LARGE_INTEGER dxgi_interface_driver_version;
    LARGE_INTEGER d3d11_interface_driver_version;
    WCHAR headless_probe_value[2];
    BOOL headless_probe = FALSE;
    HMODULE ngx_module = NULL;
    HMODULE ngx_alias_module = NULL;
    forgeplay_ngx_d3d12_init_project_id_fn ngx_init_project_id = NULL;
    forgeplay_ngx_parameters_fn ngx_get_capability_parameters = NULL;
    forgeplay_ngx_destroy_parameters_fn ngx_destroy_parameters = NULL;
    forgeplay_ngx_d3d12_shutdown_fn ngx_shutdown = NULL;
    forgeplay_ngx_d3d11_init_project_id_fn ngx_d3d11_init_project_id = NULL;
    forgeplay_ngx_parameters_fn ngx_d3d11_get_capability_parameters = NULL;
    forgeplay_ngx_destroy_parameters_fn ngx_d3d11_destroy_parameters = NULL;
    forgeplay_ngx_d3d11_create_feature_fn ngx_d3d11_create_feature = NULL;
    forgeplay_ngx_d3d11_evaluate_feature_fn ngx_d3d11_evaluate_feature = NULL;
    forgeplay_ngx_release_feature_fn ngx_release_feature = NULL;
    forgeplay_ngx_d3d11_shutdown_fn ngx_d3d11_shutdown = NULL;
    uint32_t ngx_init_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    uint32_t ngx_capability_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    uint32_t ngx_destroy_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    uint32_t ngx_shutdown_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    void *ngx_parameters = NULL;
    forgeplay_ngx_handle *ngx_feature = NULL;
    uint32_t ngx_d3d11_init_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    uint32_t ngx_d3d11_capability_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    uint32_t ngx_super_sampling_available_query_result =
        FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    int ngx_super_sampling_available = 0;
    uint32_t ngx_super_sampling_feature_init_query_result =
        FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    int ngx_super_sampling_feature_init_result = 0;
    BOOL ngx_super_sampling_capability_allows_evaluation = TRUE;
    uint32_t ngx_optimal_settings_callback_query_result =
        FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    uint32_t ngx_optimal_settings_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    BOOL ngx_optimal_settings_used = FALSE;
    UINT ngx_input_width = 320;
    UINT ngx_input_height = 180;
    uint32_t ngx_create_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    uint32_t ngx_evaluate_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    uint32_t ngx_release_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    uint32_t ngx_d3d11_destroy_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    uint32_t ngx_d3d11_shutdown_result = FORGEPLAY_NGX_RESULT_NOT_INVOKED;
    BOOL ngx_evaluate_invoked = FALSE;
    ID3D11Texture2D *ngx_color = NULL;
    ID3D11Texture2D *ngx_depth = NULL;
    ID3D11Texture2D *ngx_motion = NULL;
    ID3D11Texture2D *ngx_output = NULL;
    ID3D11Texture2D *ngx_readback = NULL;
    uint16_t *ngx_color_data = NULL;
    uint16_t *ngx_output_data = NULL;
    float *ngx_depth_data = NULL;
    uint16_t *ngx_motion_data = NULL;
    BOOL ngx_output_nonzero = FALSE;
    uint64_t ngx_output_checksum = 0;
    WCHAR ngx_application_data_path[MAX_PATH];
    WCHAR ngx_driver_registry_path[32768];
    WCHAR ngx_registry_path_default[32768];
    WCHAR ngx_registry_path_32[32768];
    WCHAR ngx_registry_path_64[32768];
    WCHAR ngx_registry_module_path[32768];
    const WCHAR *ngx_discovered_registry_path = NULL;
    const char *ngx_discovery_label = NULL;
    LSTATUS ngx_driver_registry_status = ERROR_FILE_NOT_FOUND;
    LSTATUS ngx_registry_default_status = ERROR_FILE_NOT_FOUND;
    LSTATUS ngx_registry_32_status = ERROR_FILE_NOT_FOUND;
    BOOL ngx_exports_ready = FALSE;
    ATOM window_class = 0;
    HWND window = NULL;
    FILE *output;

    if (argc != 2) return 20;
    output = _wfopen(argv[1], L"wb");
    if (!output) return 21;
    setvbuf(output, NULL, _IONBF, 0);

    fprintf(output, "probe_architecture=64\n");
    write_environment(output, L"FORGEPLAY_GAME_RENDERER_ACTIVE");
    write_environment(output, L"FORGEPLAY_GAME_RENDERER_REQUESTED");
    write_environment(output, L"FORGEPLAY_GAME_RENDERER_APPLIED");
    write_environment(output, L"FORGEPLAY_GAME_RENDERER_PROFILE");
    write_environment(output, L"FORGEPLAY_GAME_RENDERER_D3DMETAL_BRIDGE_REQUIRED");
    write_environment(output, L"FORGEPLAY_D3DMETAL_NATIVE_THREAD_CONTEXT");
    write_environment(output, L"FORGEPLAY_D3DMETAL_BRIDGE");
    write_environment(output, L"FORGEPLAY_D3DMETAL_TARGET");
    write_environment(output, L"D3DM_ENABLE_METALFX");
    write_environment(output, L"D3DM_NVNGX_PATH");
    write_environment(output, L"FORGEPLAY_NVIDIA_IDENTITY_PROFILE");
    write_environment(output, L"FORGEPLAY_NVIDIA_IDENTITY_VENDOR_ID");
    write_environment(output, L"FORGEPLAY_NVIDIA_IDENTITY_DEVICE_ID");
    write_environment(output, L"FORGEPLAY_NVIDIA_IDENTITY_DEVICE_NAME");
    write_environment(output, L"FORGEPLAY_NVIDIA_IDENTITY_DRIVER_VERSION");
    write_environment(
        output,
        L"FORGEPLAY_NVIDIA_IDENTITY_DISPLAY_DRIVER_VERSION"
    );
    write_environment(
        output,
        L"FORGEPLAY_GAME_RENDERER_BASE_HELPER_SUFFIX_RULES_V1"
    );

    nvidia_compatibility_requested =
        GetEnvironmentVariableW(
            L"D3DM_ENABLE_METALFX",
            metalfx_value,
            ARRAYSIZE(metalfx_value)
        ) == 1 &&
        metalfx_value[0] == L'1';
    headless_probe =
        GetEnvironmentVariableW(
            L"FORGEPLAY_D3DMETAL_HEADLESS_PROBE",
            headless_probe_value,
            ARRAYSIZE(headless_probe_value)
        ) == 1 &&
        headless_probe_value[0] == L'1';

    write_module_path(output, "dxgi", GetModuleHandleW(L"dxgi.dll"));
    write_module_path(output, "d3d11", GetModuleHandleW(L"d3d11.dll"));
    write_module_path(output, "d3d12", GetModuleHandleW(L"d3d12.dll"));

    /* Match normal game startup ordering: establish the Win32 surface before
     * initializing renderer-specific device and NGX state. */
    if (!headless_probe)
    {
        window = create_probe_window(output, &window_class);
        if (!window) goto done;
        pump_window_messages();
    }

    if (nvidia_compatibility_requested)
    {
        WCHAR nvapi_debug_pause[2];

        nvapi_module = LoadLibraryW(L"nvapi64.dll");
        write_module_path(output, "nvapi64", nvapi_module);
        if (GetEnvironmentVariableW(
                L"FORGEPLAY_NVAPI_DEBUG_PAUSE",
                nvapi_debug_pause,
                ARRAYSIZE(nvapi_debug_pause)
            ) == 1 &&
            nvapi_debug_pause[0] == L'1')
        {
            fprintf(output, "nvapi_debug_pause_pid=%lu\n", GetCurrentProcessId());
            Sleep(15000);
        }
        if (nvapi_module)
        {
            nvapi_exports_ready = load_procedure(
                nvapi_module,
                "nvapi_QueryInterface",
                &nvapi_query_interface,
                sizeof(nvapi_query_interface)
            );
        }
        if (nvapi_exports_ready)
        {
            void *initialize_procedure =
                nvapi_query_interface(FORGEPLAY_NVAPI_INITIALIZE_ID);
            void *enum_procedure =
                nvapi_query_interface(FORGEPLAY_NVAPI_ENUM_PHYSICAL_GPUS_ID);
            void *driver_version_procedure = nvapi_query_interface(
                FORGEPLAY_NVAPI_SYS_GET_DRIVER_AND_BRANCH_VERSION_ID
            );

            if (sizeof(nvapi_initialize) != sizeof(initialize_procedure) ||
                sizeof(nvapi_enum_physical_gpus) != sizeof(enum_procedure) ||
                sizeof(nvapi_get_driver_and_branch_version) !=
                    sizeof(driver_version_procedure))
                nvapi_exports_ready = FALSE;
            else
            {
                memcpy(
                    &nvapi_initialize,
                    &initialize_procedure,
                    sizeof(nvapi_initialize)
                );
                memcpy(
                    &nvapi_enum_physical_gpus,
                    &enum_procedure,
                    sizeof(nvapi_enum_physical_gpus)
                );
                memcpy(
                    &nvapi_get_driver_and_branch_version,
                    &driver_version_procedure,
                    sizeof(nvapi_get_driver_and_branch_version)
                );
                nvapi_exports_ready =
                    nvapi_initialize != NULL &&
                    nvapi_enum_physical_gpus != NULL &&
                    nvapi_get_driver_and_branch_version != NULL;
            }
        }
        if (nvapi_exports_ready)
        {
            nvapi_initialize_result = nvapi_initialize();
            if (nvapi_initialize_result == FORGEPLAY_NVAPI_OK)
            {
                nvapi_enum_after_initialize = nvapi_enum_physical_gpus(
                    nvapi_physical_gpus,
                    &nvapi_physical_gpu_count
                );
                nvapi_driver_version_result =
                    nvapi_get_driver_and_branch_version(
                        &nvapi_driver_version,
                        nvapi_driver_branch
                    );
            }
        }
    }
    fprintf(output, "nvapi_exports_ready=%u\n", nvapi_exports_ready ? 1u : 0u);
    fprintf(output, "nvapi_initialize_result=%d\n", nvapi_initialize_result);
    fprintf(
        output,
        "nvapi_enum_after_initialize=%d\n",
        nvapi_enum_after_initialize
    );
    fprintf(
        output,
        "nvapi_physical_gpu_count=%u\n",
        nvapi_physical_gpu_count
    );
    fprintf(
        output,
        "nvapi_driver_version_result=%d\n",
        nvapi_driver_version_result
    );
    fprintf(output, "nvapi_driver_version=%u\n", nvapi_driver_version);
    fprintf(output, "nvapi_driver_branch=%s\n", nvapi_driver_branch);

    factory_hr = CreateDXGIFactory1(&forgeplay_iid_idxgi_factory1, (void **)&factory);
    fprintf(output, "create_factory_hresult=0x%08lx\n", (unsigned long)factory_hr);
    if (FAILED(factory_hr)) goto done;

    adapter_hr = IDXGIFactory1_EnumAdapters1(factory, 0, &adapter);
    fprintf(output, "enum_adapter_hresult=0x%08lx\n", (unsigned long)adapter_hr);
    if (FAILED(adapter_hr)) goto done;

    ZeroMemory(
        &dxgi_interface_driver_version,
        sizeof(dxgi_interface_driver_version)
    );
    dxgi_interface_support_hr = IDXGIAdapter1_CheckInterfaceSupport(
        adapter,
        &forgeplay_iid_idxgi_device,
        &dxgi_interface_driver_version
    );
    fprintf(
        output,
        "dxgi_check_interface_support_hresult=0x%08lx\n",
        (unsigned long)dxgi_interface_support_hr
    );
    if (SUCCEEDED(dxgi_interface_support_hr))
    {
        fprintf(
            output,
            "dxgi_interface_driver_version_high=0x%08lx\n",
            (unsigned long)dxgi_interface_driver_version.HighPart
        );
        fprintf(
            output,
            "dxgi_interface_driver_version_low=0x%08lx\n",
            (unsigned long)dxgi_interface_driver_version.LowPart
        );
    }

    ZeroMemory(
        &d3d11_interface_driver_version,
        sizeof(d3d11_interface_driver_version)
    );
    d3d11_interface_support_hr = IDXGIAdapter1_CheckInterfaceSupport(
        adapter,
        &forgeplay_iid_id3d11_device,
        &d3d11_interface_driver_version
    );
    fprintf(
        output,
        "d3d11_check_interface_support_hresult=0x%08lx\n",
        (unsigned long)d3d11_interface_support_hr
    );
    if (SUCCEEDED(d3d11_interface_support_hr))
    {
        fprintf(
            output,
            "d3d11_interface_driver_version_high=0x%08lx\n",
            (unsigned long)d3d11_interface_driver_version.HighPart
        );
        fprintf(
            output,
            "d3d11_interface_driver_version_low=0x%08lx\n",
            (unsigned long)d3d11_interface_driver_version.LowPart
        );
    }

    ZeroMemory(&adapter_description, sizeof(adapter_description));
    if (SUCCEEDED(IDXGIAdapter1_GetDesc1(adapter, &adapter_description)))
    {
        write_adapter_description(output, &adapter_description);
        fprintf(output, "adapter_vendor_id=0x%04x\n", adapter_description.VendorId);
        fprintf(output, "adapter_device_id=0x%04x\n", adapter_description.DeviceId);
        fprintf(output, "adapter_flags=0x%08x\n", adapter_description.Flags);
        fprintf(
            output,
            "dedicated_video_memory=%" PRIu64 "\n",
            (uint64_t)adapter_description.DedicatedVideoMemory
        );
        fprintf(
            output,
            "shared_system_memory=%" PRIu64 "\n",
            (uint64_t)adapter_description.SharedSystemMemory
        );
    }
    write_setupapi_display_identity(output);

    device12_hr = D3D12CreateDevice(
        (IUnknown *)adapter,
        D3D_FEATURE_LEVEL_11_0,
        &forgeplay_iid_id3d12_device,
        (void **)&device12
    );
    fprintf(output, "create_d3d12_device_hresult=0x%08lx\n", (unsigned long)device12_hr);
    if (SUCCEEDED(device12_hr))
    {
        ID3D12Device_Release(device12);
        device12 = NULL;
    }
    device12_fl12_hr = D3D12CreateDevice(
        (IUnknown *)adapter,
        D3D_FEATURE_LEVEL_12_0,
        &forgeplay_iid_id3d12_device,
        (void **)&device12
    );
    fprintf(
        output,
        "create_d3d12_fl12_0_hresult=0x%08lx\n",
        (unsigned long)device12_fl12_hr
    );
    ngx_driver_registry_status = query_registry_string(
        output,
        "ngx_driver_registry",
        FORGEPLAY_NGX_DRIVER_REGISTRY_PATH,
        FORGEPLAY_NGX_DRIVER_PATH_VALUE,
        KEY_WOW64_64KEY,
        ngx_driver_registry_path,
        ARRAYSIZE(ngx_driver_registry_path)
    );
    ngx_registry_default_status = query_registry_string(
        output,
        "ngx_registry_default",
        FORGEPLAY_NGXCORE_REGISTRY_PATH,
        FORGEPLAY_NGXCORE_FULL_PATH_VALUE,
        0,
        ngx_registry_path_default,
        ARRAYSIZE(ngx_registry_path_default)
    );
    ngx_registry_32_status = query_registry_string(
        output,
        "ngx_registry_32",
        FORGEPLAY_NGXCORE_REGISTRY_PATH,
        FORGEPLAY_NGXCORE_FULL_PATH_VALUE,
        KEY_WOW64_32KEY,
        ngx_registry_path_32,
        ARRAYSIZE(ngx_registry_path_32)
    );
    query_registry_string(
        output,
        "ngx_registry_64",
        FORGEPLAY_NGXCORE_REGISTRY_PATH,
        FORGEPLAY_NGXCORE_FULL_PATH_VALUE,
        KEY_WOW64_64KEY,
        ngx_registry_path_64,
        ARRAYSIZE(ngx_registry_path_64)
    );
    if (ngx_driver_registry_status == ERROR_SUCCESS &&
        ngx_driver_registry_path[0] != 0)
    {
        ngx_discovered_registry_path = ngx_driver_registry_path;
        ngx_discovery_label = "driverRegistry";
    }
    else if (ngx_registry_default_status == ERROR_SUCCESS &&
        ngx_registry_path_default[0] != 0)
    {
        ngx_discovered_registry_path = ngx_registry_path_default;
        ngx_discovery_label = "registryDefault";
    }
    else if (ngx_registry_32_status == ERROR_SUCCESS &&
        ngx_registry_path_32[0] != 0)
    {
        ngx_discovered_registry_path = ngx_registry_path_32;
        ngx_discovery_label = "registry32";
    }
    if (nvidia_compatibility_requested &&
        ngx_discovered_registry_path != NULL &&
        swprintf(
            ngx_registry_module_path,
            ARRAYSIZE(ngx_registry_module_path),
            L"%ls%lsnvngx.dll",
            ngx_discovered_registry_path,
            ngx_discovered_registry_path[
                wcslen(ngx_discovered_registry_path) - 1
            ] == L'\\'
                ? L""
                : L"\\"
        ) > 0)
    {
        write_wide_value(
            output,
            "ngx_registry_module_requested",
            ngx_registry_module_path
        );
        ngx_module = LoadLibraryExW(
            ngx_registry_module_path,
            NULL,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
        );
        fprintf(output, "ngx_discovery=%s\n", ngx_discovery_label);
        write_module_path(output, "nvngx_registry_full_path", ngx_module);
    }
    else
    {
        ngx_module = LoadLibraryW(L"nvngx.dll");
        fprintf(output, "ngx_discovery=basename\n");
        write_module_path(output, "nvngx_basename", ngx_module);
    }
    if (nvidia_compatibility_requested)
    {
        ngx_alias_module = LoadLibraryExW(
            L"C:\\windows\\system32\\_nvngx.dll",
            NULL,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
        );
        write_module_path(output, "_nvngx_full_path", ngx_alias_module);
    }
    if (ngx_module)
    {
        ngx_exports_ready =
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D12_Init_ProjectID",
                &ngx_init_project_id,
                sizeof(ngx_init_project_id)
            ) &&
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D12_GetCapabilityParameters",
                &ngx_get_capability_parameters,
                sizeof(ngx_get_capability_parameters)
            ) &&
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D12_DestroyParameters",
                &ngx_destroy_parameters,
                sizeof(ngx_destroy_parameters)
            ) &&
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D12_Shutdown1",
                &ngx_shutdown,
                sizeof(ngx_shutdown)
            ) &&
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D11_Init_ProjectID",
                &ngx_d3d11_init_project_id,
                sizeof(ngx_d3d11_init_project_id)
            ) &&
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D11_GetCapabilityParameters",
                &ngx_d3d11_get_capability_parameters,
                sizeof(ngx_d3d11_get_capability_parameters)
            ) &&
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D11_DestroyParameters",
                &ngx_d3d11_destroy_parameters,
                sizeof(ngx_d3d11_destroy_parameters)
            ) &&
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D11_CreateFeature",
                &ngx_d3d11_create_feature,
                sizeof(ngx_d3d11_create_feature)
            ) &&
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D11_EvaluateFeature",
                &ngx_d3d11_evaluate_feature,
                sizeof(ngx_d3d11_evaluate_feature)
            ) &&
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D11_ReleaseFeature",
                &ngx_release_feature,
                sizeof(ngx_release_feature)
            ) &&
            load_procedure(
                ngx_module,
                "NVSDK_NGX_D3D11_Shutdown1",
                &ngx_d3d11_shutdown,
                sizeof(ngx_d3d11_shutdown)
            );
    }
    fprintf(output, "ngx_exports_ready=%u\n", ngx_exports_ready ? 1u : 0u);
    fprintf(output, "ngx_application_identity=project-id-diagnostic\n");
    fprintf(
        output,
        "ngx_project_id=%s\n",
        FORGEPLAY_NGX_DIAGNOSTIC_PROJECT_ID
    );
    if (headless_probe) goto run_ngx;

    device_hr = D3D11CreateDevice(
        (IDXGIAdapter *)adapter,
        D3D_DRIVER_TYPE_UNKNOWN,
        NULL,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        feature_levels,
        ARRAYSIZE(feature_levels),
        D3D11_SDK_VERSION,
        &device,
        &selected_feature_level,
        &device_context
    );
    fprintf(output, "create_d3d11_device_hresult=0x%08lx\n", (unsigned long)device_hr);
    fprintf(output, "d3d_feature_level=0x%04x\n", (unsigned int)selected_feature_level);
    if (FAILED(device_hr)) goto done;

    ZeroMemory(&swap_chain_description, sizeof(swap_chain_description));
    swap_chain_description.BufferDesc.Width = 640;
    swap_chain_description.BufferDesc.Height = 360;
    swap_chain_description.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap_chain_description.SampleDesc.Count = 1;
    swap_chain_description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_chain_description.BufferCount = 2;
    swap_chain_description.OutputWindow = window;
    swap_chain_description.Windowed = TRUE;
    swap_chain_description.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    swap_chain_hr = IDXGIFactory1_CreateSwapChain(
        factory,
        (IUnknown *)device,
        &swap_chain_description,
        &swap_chain
    );
    fprintf(output, "create_swap_chain_hresult=0x%08lx\n", (unsigned long)swap_chain_hr);
    if (FAILED(swap_chain_hr) || !swap_chain) goto done;

    present_hr = IDXGISwapChain_Present(swap_chain, 0, 0);
    fprintf(output, "present_hresult=0x%08lx\n", (unsigned long)present_hr);
    pump_window_messages();
    Sleep(250);

run_ngx:
    if (ngx_exports_ready && SUCCEEDED(device12_fl12_hr) && device12)
    {
        if (!GetTempPathW(
                ARRAYSIZE(ngx_application_data_path),
                ngx_application_data_path
            ))
            ngx_application_data_path[0] = 0;
        ngx_init_result = ngx_init_project_id(
            FORGEPLAY_NGX_DIAGNOSTIC_PROJECT_ID,
            FORGEPLAY_NGX_ENGINE_TYPE_CUSTOM,
            FORGEPLAY_NGX_DIAGNOSTIC_ENGINE_VERSION,
            ngx_application_data_path,
            device12,
            NULL,
            FORGEPLAY_NGX_VERSION_API
        );
        if (ngx_init_result == FORGEPLAY_NGX_RESULT_SUCCESS)
        {
            ngx_capability_result = ngx_get_capability_parameters(
                &ngx_parameters
            );
            if (ngx_parameters)
            {
                ngx_destroy_result = ngx_destroy_parameters(ngx_parameters);
                ngx_parameters = NULL;
            }
            ngx_shutdown_result = ngx_shutdown(device12);
        }
    }
    if (ngx_exports_ready && device && device_context)
    {
        const UINT output_width = 640;
        const UINT output_height = 360;
        UINT x, y;

        if (!GetTempPathW(
                ARRAYSIZE(ngx_application_data_path),
                ngx_application_data_path
            ))
            ngx_application_data_path[0] = 0;
        ngx_d3d11_init_result = ngx_d3d11_init_project_id(
            FORGEPLAY_NGX_DIAGNOSTIC_PROJECT_ID,
            FORGEPLAY_NGX_ENGINE_TYPE_CUSTOM,
            FORGEPLAY_NGX_DIAGNOSTIC_ENGINE_VERSION,
            ngx_application_data_path,
            device,
            NULL,
            FORGEPLAY_NGX_VERSION_API
        );
        if (ngx_d3d11_init_result == FORGEPLAY_NGX_RESULT_SUCCESS)
            ngx_d3d11_capability_result =
                ngx_d3d11_get_capability_parameters(&ngx_parameters);
        if (ngx_d3d11_capability_result == FORGEPLAY_NGX_RESULT_SUCCESS &&
            ngx_parameters &&
            ((forgeplay_ngx_parameter *)ngx_parameters)->methods)
        {
            forgeplay_ngx_parameter *parameters =
                (forgeplay_ngx_parameter *)ngx_parameters;
            const forgeplay_ngx_parameter_vtable *methods = parameters->methods;
            SIZE_T input_pixel_count;
            const SIZE_T output_pixel_count =
                (SIZE_T)output_width * output_height;
            D3D11_MAPPED_SUBRESOURCE mapped;

            if (methods->get_int)
            {
                ngx_super_sampling_available_query_result = methods->get_int(
                    parameters,
                    "SuperSampling.Available",
                    &ngx_super_sampling_available
                );
                ngx_super_sampling_feature_init_query_result = methods->get_int(
                    parameters,
                    "SuperSampling.FeatureInitResult",
                    &ngx_super_sampling_feature_init_result
                );
                if (ngx_super_sampling_available_query_result ==
                        FORGEPLAY_NGX_RESULT_SUCCESS &&
                    !ngx_super_sampling_available)
                    ngx_super_sampling_capability_allows_evaluation = FALSE;
            }
            if (ngx_super_sampling_capability_allows_evaluation)
                ngx_optimal_settings_used = query_ngx_dlss_optimal_render_size(
                    parameters,
                    methods,
                    output_width,
                    output_height,
                    FORGEPLAY_NGX_PERF_QUALITY_MAX_PERFORMANCE,
                    &ngx_input_width,
                    &ngx_input_height,
                    &ngx_optimal_settings_callback_query_result,
                    &ngx_optimal_settings_result
                );
            input_pixel_count = (SIZE_T)ngx_input_width * ngx_input_height;
            ngx_color_data = HeapAlloc(
                GetProcessHeap(), 0,
                input_pixel_count * 4 * sizeof(*ngx_color_data));
            ngx_output_data = HeapAlloc(
                GetProcessHeap(), HEAP_ZERO_MEMORY,
                output_pixel_count * 4 * sizeof(*ngx_output_data));
            ngx_depth_data = HeapAlloc(
                GetProcessHeap(), 0, input_pixel_count * sizeof(*ngx_depth_data));
            ngx_motion_data = HeapAlloc(
                GetProcessHeap(), HEAP_ZERO_MEMORY,
                input_pixel_count * 2 * sizeof(*ngx_motion_data));
            if (ngx_color_data && ngx_output_data && ngx_depth_data &&
                ngx_motion_data && methods->set_unsigned_int &&
                methods->set_int && methods->set_float &&
                methods->set_d3d11_resource &&
                ngx_super_sampling_capability_allows_evaluation)
            {
                for (y = 0; y < ngx_input_height; ++y)
                {
                    for (x = 0; x < ngx_input_width; ++x)
                    {
                        SIZE_T offset =
                            ((SIZE_T)y * ngx_input_width + x) * 4;
                        /* IEEE-754 binary16 values: 0.25, 0.5, 0.75, 1.0. */
                        ngx_color_data[offset] = 0x3400u;
                        ngx_color_data[offset + 1] = 0x3800u;
                        ngx_color_data[offset + 2] = 0x3a00u;
                        ngx_color_data[offset + 3] = 0x3c00u;
                        ngx_depth_data[
                            (SIZE_T)y * ngx_input_width + x
                        ] = 1.0f;
                    }
                }
                ngx_color = create_ngx_texture(
                    device, ngx_input_width, ngx_input_height,
                    DXGI_FORMAT_R16G16B16A16_FLOAT,
                    D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE,
                    ngx_color_data,
                    ngx_input_width * 4 * sizeof(*ngx_color_data));
                ngx_depth = create_ngx_texture(
                    device, ngx_input_width, ngx_input_height,
                    DXGI_FORMAT_R32_FLOAT,
                    D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE,
                    ngx_depth_data,
                    ngx_input_width * sizeof(*ngx_depth_data));
                ngx_motion = create_ngx_texture(
                    device, ngx_input_width, ngx_input_height,
                    DXGI_FORMAT_R16G16_FLOAT,
                    D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE,
                    ngx_motion_data,
                    ngx_input_width * 2 * sizeof(*ngx_motion_data));
                ngx_output = create_ngx_texture(
                    device, output_width, output_height,
                    DXGI_FORMAT_R16G16B16A16_FLOAT,
                    D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE |
                        D3D11_BIND_UNORDERED_ACCESS,
                    ngx_output_data,
                    output_width * 4 * sizeof(*ngx_output_data));
                if (ngx_color && ngx_depth && ngx_motion && ngx_output)
                {
                    methods->set_unsigned_int(
                        parameters, "Width", ngx_input_width);
                    methods->set_unsigned_int(
                        parameters, "Height", ngx_input_height);
                    methods->set_unsigned_int(parameters, "OutWidth", output_width);
                    methods->set_unsigned_int(parameters, "OutHeight", output_height);
                    methods->set_int(
                        parameters,
                        "PerfQualityValue",
                        FORGEPLAY_NGX_PERF_QUALITY_MAX_PERFORMANCE
                    );
                    methods->set_int(
                        parameters,
                        "DLSS.Feature.Create.Flags",
                        FORGEPLAY_NGX_DLSS_FEATURE_FLAG_MV_LOW_RES
                    );
                    methods->set_int(parameters, "DLSS.Enable.Output.Subrects", 0);
                    ngx_create_result = ngx_d3d11_create_feature(
                        device_context,
                        FORGEPLAY_NGX_FEATURE_SUPER_SAMPLING,
                        parameters,
                        &ngx_feature
                    );
                    if (ngx_create_result == FORGEPLAY_NGX_RESULT_SUCCESS &&
                        ngx_feature)
                    {
                        methods->set_d3d11_resource(
                            parameters, "Color", (ID3D11Resource *)ngx_color);
                        methods->set_d3d11_resource(
                            parameters, "Output", (ID3D11Resource *)ngx_output);
                        methods->set_d3d11_resource(
                            parameters, "Depth", (ID3D11Resource *)ngx_depth);
                        methods->set_d3d11_resource(
                            parameters, "MotionVectors",
                            (ID3D11Resource *)ngx_motion);
                        {
                            static const char *optional_resources[] = {
                                "TransparencyMask",
                                "ExposureTexture",
                                "DLSS.Input.Bias.Current.Color.Mask",
                                "GBuffer.Albedo",
                                "GBuffer.Roughness",
                                "GBuffer.Metallic",
                                "GBuffer.Specular",
                                "GBuffer.Subsurface",
                                "GBuffer.Normals",
                                "GBuffer.ShadingModelId",
                                "GBuffer.MaterialId",
                                "GBuffer.Attrib.8",
                                "GBuffer.Attrib.9",
                                "GBuffer.Attrib.10",
                                "GBuffer.Attrib.11",
                                "GBuffer.Attrib.12",
                                "GBuffer.Attrib.13",
                                "GBuffer.Attrib.14",
                                "GBuffer.Attrib.15",
                                "MotionVectors3D",
                                "IsParticleMask",
                                "AnimatedTextureMask",
                                "DepthHighRes",
                                "Position.ViewSpace",
                                "RayTracingHitDistance",
                                "MotionVectorsReflection"
                            };
                            static const char *zero_unsigned_parameters[] = {
                                "TonemapperType",
                                "DLSS.Input.Color.Subrect.Base.X",
                                "DLSS.Input.Color.Subrect.Base.Y",
                                "DLSS.Input.Depth.Subrect.Base.X",
                                "DLSS.Input.Depth.Subrect.Base.Y",
                                "DLSS.Input.MV.Subrect.Base.X",
                                "DLSS.Input.MV.Subrect.Base.Y",
                                "DLSS.Input.Translucency.Subrect.Base.X",
                                "DLSS.Input.Translucency.Subrect.Base.Y",
                                "DLSS.Input.Bias.Current.Color.Subrect.Base.X",
                                "DLSS.Input.Bias.Current.Color.Subrect.Base.Y",
                                "DLSS.Output.Subrect.Base.X",
                                "DLSS.Output.Subrect.Base.Y"
                            };
                            UINT parameter_index;

                            for (parameter_index = 0;
                                 parameter_index < ARRAYSIZE(optional_resources);
                                 ++parameter_index)
                                methods->set_d3d11_resource(
                                    parameters,
                                    optional_resources[parameter_index],
                                    NULL
                                );
                            for (parameter_index = 0;
                                 parameter_index <
                                    ARRAYSIZE(zero_unsigned_parameters);
                                 ++parameter_index)
                                methods->set_unsigned_int(
                                    parameters,
                                    zero_unsigned_parameters[parameter_index],
                                    0
                                );
                        }
                        methods->set_float(parameters, "Jitter.Offset.X", 0.0f);
                        methods->set_float(parameters, "Jitter.Offset.Y", 0.0f);
                        methods->set_float(parameters, "Sharpness", 0.0f);
                        methods->set_int(parameters, "Reset", 1);
                        methods->set_float(parameters, "MV.Scale.X", 1.0f);
                        methods->set_float(parameters, "MV.Scale.Y", 1.0f);
                        methods->set_unsigned_int(
                            parameters,
                            "DLSS.Render.Subrect.Dimensions.Width",
                            ngx_input_width
                        );
                        methods->set_unsigned_int(
                            parameters,
                            "DLSS.Render.Subrect.Dimensions.Height",
                            ngx_input_height
                        );
                        methods->set_float(parameters, "DLSS.Pre.Exposure", 1.0f);
                        methods->set_float(parameters, "DLSS.Exposure.Scale", 1.0f);
                        methods->set_float(parameters, "FrameTimeDeltaInMsec", 0.0f);
                        methods->set_int(parameters, "DLSS.Indicator.Invert.X.Axis", 0);
                        methods->set_int(parameters, "DLSS.Indicator.Invert.Y.Axis", 0);
                        ngx_evaluate_invoked = TRUE;
                        ngx_evaluate_result = ngx_d3d11_evaluate_feature(
                            device_context,
                            ngx_feature,
                            parameters,
                            NULL
                        );
                        if (ngx_evaluate_result == FORGEPLAY_NGX_RESULT_SUCCESS)
                        {
                            ngx_readback = create_ngx_readback_texture(
                                device, ngx_output);
                            if (ngx_readback)
                            {
                                ID3D11DeviceContext_CopyResource(
                                    device_context,
                                    (ID3D11Resource *)ngx_readback,
                                    (ID3D11Resource *)ngx_output
                                );
                                ID3D11DeviceContext_Flush(device_context);
                                ZeroMemory(&mapped, sizeof(mapped));
                                if (SUCCEEDED(ID3D11DeviceContext_Map(
                                        device_context,
                                        (ID3D11Resource *)ngx_readback,
                                        0,
                                        D3D11_MAP_READ,
                                        0,
                                        &mapped
                                    )))
                                {
                                    for (y = 0; y < output_height; ++y)
                                    {
                                        const BYTE *row =
                                            (const BYTE *)mapped.pData +
                                            (SIZE_T)y * mapped.RowPitch;
                                        for (x = 0;
                                             x < output_width * 4 *
                                                sizeof(*ngx_output_data);
                                             ++x)
                                        {
                                            ngx_output_checksum += row[x];
                                            if (row[x]) ngx_output_nonzero = TRUE;
                                        }
                                    }
                                    ID3D11DeviceContext_Unmap(
                                        device_context,
                                        (ID3D11Resource *)ngx_readback,
                                        0
                                    );
                                }
                            }
                        }
                        ngx_release_result = ngx_release_feature(ngx_feature);
                        ngx_feature = NULL;
                    }
                }
            }
        }
        if (ngx_parameters)
        {
            ngx_d3d11_destroy_result =
                ngx_d3d11_destroy_parameters(ngx_parameters);
            ngx_parameters = NULL;
        }
        ngx_d3d11_shutdown_result = ngx_d3d11_shutdown(device);
    }
    fprintf(output, "ngx_init_result=0x%08x\n", ngx_init_result);
    fprintf(
        output,
        "ngx_capability_result=0x%08x\n",
        ngx_capability_result
    );
    fprintf(output, "ngx_destroy_result=0x%08x\n", ngx_destroy_result);
    fprintf(output, "ngx_shutdown_result=0x%08x\n", ngx_shutdown_result);
    fprintf(output, "ngx_d3d11_init_result=0x%08x\n", ngx_d3d11_init_result);
    fprintf(
        output,
        "ngx_d3d11_capability_result=0x%08x\n",
        ngx_d3d11_capability_result
    );
    fprintf(
        output,
        "ngx_super_sampling_available_query_result=0x%08x\n",
        ngx_super_sampling_available_query_result
    );
    fprintf(
        output,
        "ngx_super_sampling_available=%d\n",
        ngx_super_sampling_available
    );
    fprintf(
        output,
        "ngx_super_sampling_feature_init_query_result=0x%08x\n",
        ngx_super_sampling_feature_init_query_result
    );
    fprintf(
        output,
        "ngx_super_sampling_feature_init_result=0x%08x\n",
        (unsigned int)ngx_super_sampling_feature_init_result
    );
    fprintf(
        output,
        "ngx_super_sampling_capability_allows_evaluation=%u\n",
        ngx_super_sampling_capability_allows_evaluation ? 1u : 0u
    );
    fprintf(
        output,
        "ngx_optimal_settings_callback_query_result=0x%08x\n",
        ngx_optimal_settings_callback_query_result
    );
    fprintf(
        output,
        "ngx_optimal_settings_result=0x%08x\n",
        ngx_optimal_settings_result
    );
    fprintf(
        output,
        "ngx_optimal_settings_used=%u\n",
        ngx_optimal_settings_used ? 1u : 0u
    );
    fprintf(output, "ngx_input_width=%u\n", ngx_input_width);
    fprintf(output, "ngx_input_height=%u\n", ngx_input_height);
    fprintf(output, "ngx_create_result=0x%08x\n", ngx_create_result);
    fprintf(
        output,
        "ngx_evaluate_invoked=%u\n",
        ngx_evaluate_invoked ? 1u : 0u
    );
    fprintf(output, "ngx_evaluate_result=0x%08x\n", ngx_evaluate_result);
    fprintf(output, "ngx_release_result=0x%08x\n", ngx_release_result);
    fprintf(
        output,
        "ngx_d3d11_destroy_result=0x%08x\n",
        ngx_d3d11_destroy_result
    );
    fprintf(
        output,
        "ngx_d3d11_shutdown_result=0x%08x\n",
        ngx_d3d11_shutdown_result
    );
    fprintf(output, "ngx_output_nonzero=%u\n", ngx_output_nonzero ? 1u : 0u);
    fprintf(output, "ngx_output_checksum=%" PRIu64 "\n", ngx_output_checksum);

done:
    if (ngx_feature && ngx_release_feature) ngx_release_feature(ngx_feature);
    if (ngx_parameters && ngx_d3d11_destroy_parameters)
        ngx_d3d11_destroy_parameters(ngx_parameters);
    if (ngx_readback) ID3D11Texture2D_Release(ngx_readback);
    if (ngx_output) ID3D11Texture2D_Release(ngx_output);
    if (ngx_motion) ID3D11Texture2D_Release(ngx_motion);
    if (ngx_depth) ID3D11Texture2D_Release(ngx_depth);
    if (ngx_color) ID3D11Texture2D_Release(ngx_color);
    if (ngx_motion_data) HeapFree(GetProcessHeap(), 0, ngx_motion_data);
    if (ngx_depth_data) HeapFree(GetProcessHeap(), 0, ngx_depth_data);
    if (ngx_output_data) HeapFree(GetProcessHeap(), 0, ngx_output_data);
    if (ngx_color_data) HeapFree(GetProcessHeap(), 0, ngx_color_data);
    if (swap_chain) IDXGISwapChain_Release(swap_chain);
    if (device12) ID3D12Device_Release(device12);
    if (device_context) ID3D11DeviceContext_Release(device_context);
    if (device) ID3D11Device_Release(device);
    if (adapter) IDXGIAdapter1_Release(adapter);
    if (factory) IDXGIFactory1_Release(factory);
    if (window) DestroyWindow(window);
    if (window_class)
        UnregisterClassW(
            L"ForgePlayD3DMetalSwapChainProbe",
            GetModuleHandleW(NULL)
        );
    if (nvapi_module) FreeLibrary(nvapi_module);
    if (ngx_module) FreeLibrary(ngx_module);
    if (ngx_alias_module) FreeLibrary(ngx_alias_module);
    fclose(output);

    if (FAILED(factory_hr)) return 22;
    if (FAILED(adapter_hr)) return 23;
    if (FAILED(device12_hr)) return 28;
    if (FAILED(device12_fl12_hr)) return 29;
    if (nvidia_compatibility_requested)
    {
        if (!nvapi_module || !nvapi_exports_ready) return 35;
        if (nvapi_initialize_result != FORGEPLAY_NVAPI_OK) return 36;
        if (nvapi_enum_after_initialize != FORGEPLAY_NVAPI_OK) return 37;
        if (!nvapi_physical_gpu_count) return 38;
        if (!ngx_module || !ngx_exports_ready) return 30;
        if (ngx_init_result != FORGEPLAY_NGX_RESULT_SUCCESS) return 31;
        if (ngx_capability_result != FORGEPLAY_NGX_RESULT_SUCCESS) return 32;
        if (ngx_destroy_result != FORGEPLAY_NGX_RESULT_SUCCESS) return 33;
        if (ngx_shutdown_result != FORGEPLAY_NGX_RESULT_SUCCESS) return 34;
        if (!ngx_alias_module) return 39;
    }
    if (headless_probe) return 0;
    if (FAILED(device_hr)) return 24;
    if (!window) return 25;
    if (FAILED(swap_chain_hr)) return 26;
    if (FAILED(present_hr)) return 27;
    return 0;
}
