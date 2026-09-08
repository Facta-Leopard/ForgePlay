# ForgePlay modifications to Wine 11.12

ForgePlay distributes a modified Wine 11.12 source and binary copy. This
notice records the license boundary and exact modification identity for that
copy; it does not replace Wine's upstream notices or the license texts shipped
with the Runtime.

## Exact modification snapshot

- Modification snapshot date: 2026-09-09
- Upstream release: Wine 11.12
- Upstream archive SHA-256:
  `d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc`
- Ordered patch count: 40
- Patch-set SHA-256:
  `d8545f36ab0b13399182171c0c1f6e899fbb7245d7be57f793b060b20bb2fb0f`
- Patched source-tree SHA-256:
  `ef83e1a9c2c31db1c712b12a6253676f61e316f2c6373e0702ef57926291aa32`

The complete preferred form of the ForgePlay changes is the ordered patch set
shipped under `Patches/`. `SOURCE-AVAILABILITY.md` gives the reconstruction
procedure and exact order. Omitting or reordering a patch does not reconstruct
the distributed Wine copy.

The WoW64 Vulkan host-memory ownership patch updates `dlls/win32u/vulkan.c`
to release backing memory allocated by Wine after host Vulkan destruction,
including allocation-failure cleanup. It preserves driver map/unmap visibility
and caller-owned host imports. This file retains its existing
LGPL-2.1-or-later terms and Roderick Colenbrander's upstream copyright; the
existing combined-copy Game Mode license boundary below is unchanged.

The XInput capability-resolution patch updates six assignments in
`dlls/xinput1_3/main.c` so existing trigger and thumbstick controls report
full-field resolution masks. Missing controls remain zero. Actual input state,
trigger thresholds and HID mapping are unchanged; this does not establish
remediation of reported repeated-trigger input. The existing source copyrights
of Andrew Fenn, Aric Stewart and Rémi Bernon for CodeWeavers, and
LGPL-2.1-or-later terms, are retained.

The renderer module-load diagnostic in `dlls/ntdll/loader.c` now checks the
requested DLL name before querying the active renderer environment and delays
its additional basename scan until the report is needed. Renderer allowlists,
load decisions, diagnostic format and applicable licenses remain unchanged.

The dynamic unwind-registration cache in `dlls/ntdll/unwind.c` retains only
one live, non-callback registration selection for the same program counter.
The existing lock protects its lifetime; registration changes invalidate it,
and caller-owned function-table contents are searched afresh. Opt-out
configuration is fixed at first lookup; environment queries occur outside the
registration lock. Callback results are not cached. The original file copyrights of Alexandre Julliard and
Martin Storsjö and LGPL-2.1-or-later terms are retained; the combined-copy
Game Mode license boundary below is unchanged.

The builtin WineD3D process-policy patch replaces the active D9VK selection
with the explicit `wined3d` policy in `dlls/kernelbase/process.c` and
`dlls/ntdll/loader.c`. It retains process activation and lineage while allowing
absent external component and DLL directories only for the builtin policy.
Loader observations distinguish a Wine builtin image from an externally
allowlisted module; a builtin marker does not establish prefix-file hash
ownership. Existing process restoration and external renderer validation
remain in place.

The OpenGL frame-generation hook patch updates
`dlls/winemac.drv/cocoa_opengl.m` and `metal_surface_contract.c`, with the new
project-authored declaration header `metal_surface_contract.h`. It connects the
OpenGL drawable lifecycle to the optional ForgePlay adapter and preserves
ordinary presentation when the option is disabled or unavailable. The hook
uses bounded failure diagnostics and does not change the existing Metal
adapter interface. The new declaration header is provided under
LGPL-2.1-or-later, consistent with its implementation file.

The macOS OpenGL profile-sharing patch updates `include/wine/opengl_driver.h`,
`dlls/winemac.drv/opengl.c`, `dlls/win32u/opengl.c`, and the PE/Unix WGL
implementations in `dlls/opengl32/`. It respects CGL legacy/core native sharing
domains, keeps same-domain object sharing, and selects the owning native context
and Wine dispatch state while deleting context-owned objects. The internal
OpenGL driver interface advances to version 39; its compiled participants must
be updated together. These patches retain the existing source notices of
Alexandre Julliard, Dmitry Timoshkov, Ken Thomases, Rémi Bernon, Lionel Ulmer,
Raphael Junqueira, CodeWeavers, and ForgePlay contributors, and their applicable
LGPL-2.1-or-later terms. The combined-copy Game Mode boundary below is unchanged.

The builtin WineD3D Vulkan-policy patch updates `dlls/kernelbase/process.c`
and `dlls/ntdll/loader.c`. The explicit `wined3d` game-child policy now selects
`renderer=vulkan` and preserves that choice in its descendant environment
projection. Base-helper restoration, other renderer policies, builtin module
isolation, and the distinction between builtin observations and verified
external-module ownership remain unchanged. The currently verified target
is 32-bit Direct3D 9 / Shader Model 3 through the existing WineVulkan and
MoltenVK payload; 64-bit compatibility is not claimed. Optional frame generation uses the existing Vulkan-to-Metal source
command-buffer and presentation path. No new third-party dependency or Wine
version is introduced. Earlier OpenGL patches remain in the reconstruction
history and internal Wine libraries; they do not define this profile's backend.
Existing copyrights and license boundaries are retained.

The Vulkan shader Reset patch updates `dlls/wined3d/shader_spirv.c`.
Device Reset retains shader objects while releasing their backend programs;
first use now rebuilds the required scan metadata before descriptor binding.
Existing metadata is reused, new metadata is published only after successful
allocation and scan, and binding failures retain the graphics or compute
failure path. The existing copyrights of Henri Verbeet and Józef Kucia for
CodeWeavers and LGPL-2.1-or-later terms are retained. The combined-copy Game
Mode license boundary below is unchanged.

The partial-varying initialization patch updates
`libs/vkd3d/libs/vkd3d-shader/ir.c` in Wine's bundled vkd3d 2.0.
For Shader Model 1-3, it initializes only output components that a following
shader expects but the vertex shader does not write, using the existing zero
value policy for uninitialized varyings. Written components, diffuse defaults,
return paths, Vulkan interface matching, and allocation-failure propagation
are preserved. An incomplete instruction is cleared before an operand-allocation
failure reaches diagnostic tracing. Existing copyrights of Conor McCarthy and Elizabeth Figura for
CodeWeavers, the vkd3d authors' notices, and LGPL-2.1-or-later terms are retained.
The combined-copy Game Mode license boundary below is unchanged.

The legacy vertex-interface patch updates `dlls/wined3d/context_vk.c`,
`adapter_vk.c`, and `shader_spirv.c`. Shader Model 1-3 and fixed-function
vertex inputs use supported Vulkan scaled formats for numeric conversion of
unnormalized integer attributes; Shader Model 4 and later retain typed inputs.
Scaled vertex-format support is checked when creating a new pipeline, and
unsupported UBYTE4 capability is not advertised. Pixel-shader changes revisit
the existing legacy vertex-variant cache so its output interface matches the
new pixel shader, including unbinding. Existing Reset and partial-varying
initialization fixes, resource lifetimes, and error propagation are retained.
The existing file copyrights and LGPL-2.1-or-later terms are preserved; the
combined-copy Game Mode license boundary below is unchanged.

The sRGB-read and luminance-view patch updates `dlls/wined3d/wined3d_vk.h`,
`texture_vk.c`, `context_vk.c`, `sampler.c`, and `utils.c`. Compatible Direct3D 9
images permit linear and sRGB views; the bound sampler selects a cached sRGB
sampling view while typed views from newer APIs retain their declared format.
The original view shape, texture bytes, alpha, and image lifetime are preserved,
including deferred view retirement. Native L8 textures use `VK_FORMAT_R8_UNORM`
with luminance replicated to RGB and opaque alpha. No CPU texture conversion or
sRGB-write behavior is introduced. The existing file copyrights and
LGPL-2.1-or-later terms are retained; the combined-copy Game Mode license boundary
below is unchanged.

The sRGB-read capability patch updates `dlls/wined3d/utils.c`,
`texture_vk.c`, `adapter_vk.c`, and `wined3d_vk.h`. Direct3D 9 advertises
sRGB-read support only for the mutable-view formats implemented by the shared
format lookup and supported for optimal-tiling sampling by the Vulkan device.
Typed views from newer APIs and formats without compatible counterparts retain
their existing behavior. sRGB-write queries remain unavailable, and the
unsupported post-blend sRGB-conversion capability is no longer advertised.
The existing file copyrights and LGPL-2.1-or-later terms are retained; the
combined-copy Game Mode license boundary below is unchanged.

## License boundary

Wine's unmodified material and ForgePlay modifications not expressly
converted below retain their applicable GNU Lesser General Public License,
version 2.1 or later (`LGPL-2.1-or-later`), notices, and copyrights. The
unmodified license text is shipped as `Legal/Wine/COPYING.LIB`.

The exact copies modified by these two Game Mode patches are designated for
conversion to GNU General Public License, version 3 only (`GPL-3.0-only`),
under LGPL 2.1 section 3:

- `Patches/wine-11.12-game-mode-process-host-routing.patch`
- `Patches/wine-11.12-game-mode-direct-target-scope.patch`

Those patches modify the distributed Wine copy directly. Their GPL effect is
not confined to the standalone patch files; a Wine copy containing those
changes must be conveyed consistently with GPLv3 as a combined derivative
work. Unmodified upstream Wine material retains its independent LGPL
permissions. The authoritative scope, file assignment, conversion basis, and
notices are shipped under `Legal/ForgePlayGameMode/`, including
`GAME_MODE_LICENSE_SCOPE.md`, `GAME_MODE_FILE_LICENSES.json`,
`GAME_MODE_NOTICE`, `GAME_MODE_SYMBOL_MANIFEST.md`, and the unmodified GPLv3
and LGPL 2.1 license texts.

All upstream Wine copyrights and attribution remain intact. This notice does
not relicense Apple D3DMetal, the bundled renderer payloads, GStreamer, fonts,
or any other separately identified third-party component; each retains its
own terms.
