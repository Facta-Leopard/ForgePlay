# ForgePlay D3DMetal bridge contract for Wine 11.12

This document records the clean-room contract used by the ForgePlay Wine patch.
It intentionally describes interfaces and observable behavior, not an implementation
from any third-party Wine distribution.

## Provenance of the upstream base

- Source archive: `https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz`
- Archive SHA-256: `d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc`
- Detached signature: `wine-11.12.tar.xz.sign`, verified against Wine release-key
  fingerprint `DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D`.
- Pristine-tree fingerprint:
  `5d0d476f2cd7179f48e47a7188a89afa4c367ad19ba6fbd7095d41bf256cbff4`.
  This is the SHA-256 of a lexicographically sorted manifest containing every
  extracted entry's type, permission mode, relative path, and either file SHA-256
  or symbolic-link target (13,781 entries). It is distinct from any downstream
  patched-tree fingerprint.

## Primary and observable ABI evidence

Apple's public `apple/homebrew-apple` repository, commit
`2bc44284e24d39ed64d6f492a0e1f4c47a5ced08`, publishes the interface types used
by the Apple supplemental renderer's documented Wine-facing ABI boundary:

```c
static bool (*supports_non_native_code_regions)(void);
static void (*register_non_native_code_region)(void *start, void *end);
```

The registration interval is half-open: `[start, end)`. Only these declarations
and the call shape are treated as evidence; no downstream implementation is used.

The Apple-signed x86_64 `libd3dshared.dylib` observed in the toolkit exports:

- `supports_non_native_code_regions`
- `register_non_native_code_region`
- `__wine_unix_call_funcs`

Its code-signing identifier is `com.apple.libd3dshared` and its full code-directory
SHA-256 is `726499610da4f62204d893d2a172e36eefc2640c348b19abf47728522043f6bb`.

The toolkit's observable PE front ends import `NtQueryVirtualMemory` from
`ntdll.dll`. Wine 11.12's public source defines `MemoryWineLoadUnixLib` and
related information classes for retrieving a Unix-library function table.
Wine's Unix-library ABI is:

```c
typedef NTSTATUS (*unixlib_entry_t)(void *args);
extern const unixlib_entry_t __wine_unix_call_funcs[];
```

Therefore the exact external call boundary is Wine's existing
`__wine_unix_call_funcs` table obtained through `NtQueryVirtualMemory`; ForgePlay
must not substitute another table shape, call table entries directly, or invent a
parallel dispatcher.

## Activation contract

The compatibility path is opt-in per PE main image. Both variables are required:

- `FORGEPLAY_D3DMETAL_BRIDGE=1`
- `FORGEPLAY_D3DMETAL_TARGET=<main-image-basename>`

`FORGEPLAY_D3DMETAL_TARGET` is compared case-insensitively with the basename of
the main PE image. It must itself be a basename, not a path. The bridge remains
inactive for every non-matching process, even when it inherited the variables.
This ensures a launcher and unrelated renderer children retain pristine Wine
behavior.

The child-process renderer policy owns these selectors. For each routed game
child it first removes both variables from the cloned environment. It adds them
back only when the resolved renderer route is D3DMetal, using `1` and the actual
`app_name` basename respectively. The Wine Unix environment handoff copies both
variables from that sanitized child environment; it does not infer activation
from a renderer marker or from the presence of a D3DMetal library.

`FORGEPLAY_GAME_RENDERER_D3DMETAL_BRIDGE_REQUIRED` is diagnostic route evidence,
not an independent activation input. In the final runtime it is `1` only for a
manually selected exact D3DMetal session and `0` for exact D9VK, DXVK, and DXMT.
The manual-selection patch removes loader-stage routing. The two scoped
selectors above remain the only bridge activation inputs.

`FORGEPLAY_D3DMETAL_SHARED_LIBRARY` may name an absolute path to the selected
runtime's `libd3dshared.dylib`. If omitted, the bridge uses the already loaded
image (if any) and then the dynamic loader's `libd3dshared.dylib` search. It never
loads the library before the main-image selector matches.

## Non-native image registration contract

After activation, the bridge resolves both capability symbols dynamically. It
registers a range only when both symbols exist and
`supports_non_native_code_regions()` returns true.

Every successful, complete PE image mapping is registered exactly once at the
mapping boundary as `[mapped_base, mapped_base + mapped_size)`. The main image,
which is mapped before selector evaluation, is registered immediately after
activation. Partial section views and non-image mappings are not registered.

The published interface has no unregister operation. The bridge consequently
does not invent one and does not retain ownership of mapped memory.

## TEB, TLS, and transition contract

The selected D3DMetal host libraries directly import public pthread functions.
Those functions require Darwin's native pthread thread context to remain
addressable while native renderer code executes. Wine's normal macOS/x86_64
translated-code path instead places the Windows TEB at the GS base. Calling a
pthread function from that state makes libSystem read Windows TEB data as
Darwin pthread data.

The child-process policy therefore adds
`FORGEPLAY_D3DMETAL_NATIVE_THREAD_CONTEXT=1` only to a manually selected exact
D3DMetal route. It removes an inherited value before every route decision and
copies the selected value through the Wine Unix environment handoff. Exact
D9VK, DXMT, DXVK, deferred launchers, Steam, and Steam WebHelper never receive
this selector.

On macOS/x86_64, the scoped native-thread-context patch keeps Darwin's pthread
GS base active for that process and mirrors only the Windows TEB slots that
translated PE code and Wine's dispatchers read directly. The follow-up
thread-state synchronization patch treats those slots as a maintained boundary,
not a one-time copy: whenever the loader allocates, resizes, or clears a static
TLS vector, it mirrors the new `ThreadLocalStoragePointer` into the retained
Darwin GS context.

Apple's published pthread layout leaves native TSD slots 6 and 11 unused for
limited Win64 interoperability. Those slots correspond to Windows
`Tib.Self` and `ThreadLocalStoragePointer`. The patch records the retained
native GS base in an otherwise unused TEB instrumentation slot only while this
process-local contract is active. Windows dynamic `TlsAlloc` storage remains
owned by the actual TEB reached through `Tib.Self`; it is not mirrored into
Darwin TSD and is not forced into a different allocation range. The original
native slot values are saved before mirroring and restored before the Wine
pthread exits.

macOS non-reentrant `localtime`, `gmtime`, `ctime`, and `asctime` implementations
may use pthread-specific result storage. In particular, libc's fixed localtime
key occupies TSD slot 12, adjacent to the two Win64-reserved slots and equal to
the direct Windows PEB offset mirrored by the scoped context.
Wine's Apple Unix-side time conversions consequently use their public reentrant
counterparts with caller-owned storage. This change is global to the Apple Wine
Unix module and preserves the same converted values without adding another TLS
model. Signal, syscall, APC, and Unix-call transitions test the per-thread
selector instead of changing the GS base unconditionally. Non-selected
processes retain Wine 11.12's standard GS switching behavior.

PE-to-Unix calls still use Wine 11.12's `__wine_unix_call_dispatcher`; the
patch adjusts the scoped thread-context transitions around that dispatcher but
does not bypass it or introduce a parallel call table.

Unix-to-PE callbacks remain the responsibility of Wine's established callback
and entrypoint paths exposed through the Unix function table. The bridge does
not call PE code from a raw host function pointer and does not add a second TLS
model.

## Metal window-surface callback contract

The managed Metal renderers discover the `macdrv_functions` data symbol from
Wine's loaded macOS driver. ForgePlay owns this ten-pointer C ABI table; it is
renderer-neutral and does not expose Wine's private `macdrv_win_data` layout.
A controlled swapchain probe establishes the following observable sequence:

1. The renderer invokes the display-state callback with a Boolean force flag.
2. It acquires window data for the target `HWND`.
3. It reads the Cocoa window, root view, and client view from the stable
   four-pointer prefix of that acquired object.
4. It creates a Metal device and Metal view, obtains the `CAMetalLayer`, and
   releases the acquired Wine window data.

The display-state slot must never be null. For a normal initialization request,
ForgePlay enters Wine 11.12's public `NtUserGetDisplayConfigBufferSizes` path,
which initializes or refreshes the display cache without inventing another
monitor model. For a forced request, it uses Wine's existing
`NtUserCallNoParam_DisplayModeChanged` path. The final function-table slot is a
C ABI adapter to Wine's existing synchronous `OnMainThread` block dispatcher,
so native renderers never invoke AppKit window work on an arbitrary worker
thread.

The acquired renderer-facing window record owns one balanced Wine
`get_win_data` reference. Its release callback drops that reference and frees
only the adapter record. Compile-time offset assertions protect the public table
and four-pointer window prefix from accidental layout drift.

## Safety and failure behavior

- No executable page is modified.
- No host-private API is introduced.
- Capability absence is a supported state: registration is skipped and a
  diagnostic is emitted only for an explicitly selected process.
- A malformed selector or non-absolute explicit library path disables the bridge
  for that process.
- Unselected processes execute no extra dynamic-library or registration work.

## Verification requirements

1. Apply the patch to the authenticated pristine Wine 11.12 tree with zero fuzz.
2. Compile the affected `ntdll` Unix sources with warnings enabled.
3. Verify opt-in matching, inherited non-match, malformed selector, missing
   capability, capability-false, and `[start,end)` registration behavior with a
   test-only host library.
4. Verify child-process routing removes inherited selectors before route
   evaluation, emits them only for D3DMetal, and passes both through the Unix
   environment allowlist.
5. Verify the external Apple library exports all three required symbols and each
   D3DMetal PE front end imports `NtQueryVirtualMemory`.
6. Confirm the produced `ntdll` retains the upstream Unix-call dispatcher,
   contains the scoped native-thread-context marker, synchronizes the mutable
   static-TLS pointer through Darwin's Win64-reserved slot, leaves Windows
   dynamic TLS owned by the actual TEB, uses reentrant Apple time conversions,
   restores every saved Darwin slot before pthread exit, and introduces no
   text-patching or new host-private-API reference.
7. Create a real Win32 window through the selected D3DMetal route, then verify
   D3D11 device creation, DXGI swapchain creation, and `Present` complete
   without an access violation and with the selected renderer modules recorded.
