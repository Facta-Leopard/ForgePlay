#define COBJMACROS
#define WIN32_LEAN_AND_MEAN

#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void probe_socket_types(FILE *output)
{
    WSADATA winsock_data;
    SOCKET stream_socket = INVALID_SOCKET;
    SOCKET datagram_socket = INVALID_SOCKET;
    int stream_type = 0, datagram_type = 0;
    int option_length;

    if (WSAStartup(MAKEWORD(2, 2), &winsock_data))
    {
        fprintf(output, "winsock_started=0\n");
        return;
    }
    fprintf(output, "winsock_started=1\n");

    stream_socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    option_length = sizeof(stream_type);
    if (stream_socket != INVALID_SOCKET &&
        !getsockopt(stream_socket, SOL_SOCKET, SO_TYPE,
                    (char *)&stream_type, &option_length))
        fprintf(output, "stream_socket_type=%d\n", stream_type);
    else
        fprintf(output, "stream_socket_type=error\n");

    datagram_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    option_length = sizeof(datagram_type);
    if (datagram_socket != INVALID_SOCKET &&
        !getsockopt(datagram_socket, SOL_SOCKET, SO_TYPE,
                    (char *)&datagram_type, &option_length))
        fprintf(output, "datagram_socket_type=%d\n", datagram_type);
    else
        fprintf(output, "datagram_socket_type=error\n");

    if (stream_socket != INVALID_SOCKET) closesocket(stream_socket);
    if (datagram_socket != INVALID_SOCKET) closesocket(datagram_socket);
    WSACleanup();
}

static void probe_network_adapters(FILE *output)
{
    IP_ADAPTER_ADDRESSES *adapters = NULL, *adapter;
    ULONG buffer_size = 0;
    ULONG result;
    ULONG active_count = 0, matching_count = 0;
    ULONG expected_type = 0;
    char profile[32] = "";

    GetEnvironmentVariableA(
        "FORGEPLAY_NETWORK_PROFILE", profile, ARRAYSIZE(profile));
    fprintf(output, "network_profile=%s\n", profile);
    if (!strcmp(profile, "wifi-identity"))
        expected_type = IF_TYPE_IEEE80211;
    else if (!strcmp(profile, "ethernet-identity"))
        expected_type = IF_TYPE_ETHERNET_CSMACD;

    result = GetAdaptersAddresses(
        AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, NULL, NULL, &buffer_size);
    if (result != ERROR_BUFFER_OVERFLOW || !buffer_size)
    {
        fprintf(output, "adapter_query_result=%lu\n", result);
        return;
    }
    adapters = malloc(buffer_size);
    if (!adapters)
    {
        fprintf(output, "adapter_query_result=%lu\n",
                (ULONG)ERROR_NOT_ENOUGH_MEMORY);
        return;
    }

    result = GetAdaptersAddresses(
        AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, NULL, adapters, &buffer_size);
    fprintf(output, "adapter_query_result=%lu\n", result);
    if (result == NO_ERROR)
    {
        for (adapter = adapters; adapter; adapter = adapter->Next)
        {
            if (adapter->OperStatus != IfOperStatusUp ||
                adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK)
                continue;
            ++active_count;
            if (expected_type && adapter->IfType == expected_type)
                ++matching_count;
            fprintf(output, "active_adapter_type_%lu=%lu\n",
                    active_count, adapter->IfType);
        }
    }
    fprintf(output, "active_adapter_count=%lu\n", active_count);
    fprintf(output, "matching_adapter_count=%lu\n", matching_count);
    fprintf(output, "expected_adapter_type=%lu\n", expected_type);
    free(adapters);
}

static void probe_audio_endpoints(FILE *output)
{
    IMMDeviceEnumerator *enumerator = NULL;
    IMMDeviceCollection *collection = NULL;
    HRESULT initialize_result;
    HRESULT capture_result = E_FAIL;
    HRESULT render_result = E_FAIL;
    UINT capture_count = 0, render_count = 0;

    initialize_result = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    fprintf(output, "com_initialize_hresult=0x%08lx\n",
            (unsigned long)initialize_result);
    if (FAILED(initialize_result)) return;

    capture_result = CoCreateInstance(
        &CLSID_MMDeviceEnumerator, NULL, CLSCTX_INPROC_SERVER,
        &IID_IMMDeviceEnumerator, (void **)&enumerator);
    if (SUCCEEDED(capture_result))
    {
        capture_result = IMMDeviceEnumerator_EnumAudioEndpoints(
            enumerator, eCapture, DEVICE_STATE_ACTIVE, &collection);
        if (SUCCEEDED(capture_result))
            IMMDeviceCollection_GetCount(collection, &capture_count);
        if (collection)
        {
            IMMDeviceCollection_Release(collection);
            collection = NULL;
        }

        render_result = IMMDeviceEnumerator_EnumAudioEndpoints(
            enumerator, eRender, DEVICE_STATE_ACTIVE, &collection);
        if (SUCCEEDED(render_result))
            IMMDeviceCollection_GetCount(collection, &render_count);
    }
    fprintf(output, "capture_enum_hresult=0x%08lx\n",
            (unsigned long)capture_result);
    fprintf(output, "capture_endpoint_count=%u\n", capture_count);
    fprintf(output, "render_enum_hresult=0x%08lx\n",
            (unsigned long)render_result);
    fprintf(output, "render_endpoint_count=%u\n", render_count);

    if (collection) IMMDeviceCollection_Release(collection);
    if (enumerator) IMMDeviceEnumerator_Release(enumerator);
    CoUninitialize();
}

int wmain(int argc, WCHAR **argv)
{
    FILE *output;
    char audio_mode[32] = "";

    if (argc != 2) return 20;
    output = _wfopen(argv[1], L"wb");
    if (!output) return 21;

    GetEnvironmentVariableA(
        "FORGEPLAY_AUDIO_INPUT_MODE", audio_mode, ARRAYSIZE(audio_mode));
    fprintf(output, "audio_input_mode=%s\n", audio_mode);
    probe_socket_types(output);
    probe_network_adapters(output);
    probe_audio_endpoints(output);
    fclose(output);
    return 0;
}
