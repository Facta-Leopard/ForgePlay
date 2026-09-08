# ForgePlay D3D9 source-build notice

This component is a modified build of DXVK v1.10.3, with only its Direct3D 9
frontend enabled. The ForgePlay version is `v1.10.3-forgeplay-d3d9.3`.

Upstream source: https://github.com/doitsujin/dxvk
Upstream commit: `e4fd5e9e8d335e8a2c0814829207cbd421f7e40e`
Upstream source archive SHA-256:
`c39ba4750a68b6e70c00d5306740b15112f3326779f5727f1e688284c5e55031`

Original DXVK copyrights:
- Copyright (c) 2017-2021 Philip Rebohle
- Copyright (c) 2019-2021 Joshua Ashton

Copyright (c) 2026 Facta-Leopard for the ForgePlay modifications.
DXVK and these modifications are provided under the zlib/libpng license in
`LICENSE`. The original license and attribution are retained verbatim.

The ForgePlay changes request geometryShader and shaderCullDistance only when
the Vulkan adapter supports them. Layered meta operations require either a
geometry shader or the existing vertex-layer alternative. The upstream GPU
software-vertex-processing path is enabled only when both geometry shaders and
vertex-stage stores/atomics are available; the same predicate controls vertex
buffer synchronization flags. Unsupported nonempty ProcessVertices requests
return an explicit error, and a valid zero-count request remains a no-op.
These changes add no new software vertex processing or geometry emulation.
Explicit fixed-width integer includes support GCC 15. An SDK type probe avoids
redeclaring D3DDEVINFO_RESOURCEMANAGER when the real definition is available.
The version suffix identifies this altered source build.

The accompanying finalized `SourceBuildRecord.json` and
`ForgePlayD9VKSource.lock.json` identify the source, patches, build inputs and
published binary hashes. Build reproducibility, complete Direct3D 9 conformance,
and remediation of the reported Left 4 Dead 2 device-lost failure are unverified.

## Included notices

- DXVK: zlib/libpng (`LICENSE`).
- Vendored OpenVR interface: Valve Corporation, BSD-3-Clause (`OpenVR-LICENSE`).
- Vendored Vulkan headers: Khronos Group, Apache-2.0
  (`Vulkan-Headers-Apache-2.0`, `Vulkan-Headers-NOTICE`).
- Vendored SPIR-V and GLSL.std.450 headers: the original Khronos permissive notices
  (`SPIRV-Headers-LICENSE`, `GLSL-std450-LICENSE`).
- MinGW-w64 14.0.0 runtime: original project and component notices, including ZPL,
  BSD/permissive and public-domain material (`MinGW-w64-COPYING`,
  `MinGW-w64-runtime-COPYING`, `MinGW-w64-AUTHORS`, `MinGW-w64-DISCLAIMER`,
  `MinGW-w64-DISCLAIMER-PD`).
- MinGW-w64 14.0.0 winpthreads: MIT and BSD-3-Clause (`Winpthreads-COPYING`).
- GCC 15.2.0 libgcc/libstdc++ runtime: Free Software Foundation and contributors,
  GPLv3 with GCC Runtime Library Exception 3.1 (`GCC-COPYING3`,
  `GCC-RUNTIME-EXCEPTION`). These runtime libraries and winpthreads are linked
  statically. Their original license texts and conditions are retained.

Meson, Ninja and glslangValidator are build tools; this component does not bundle
their executables or link their compiler implementations into the D3D9 DLLs.

The MoltenVK sampler-binding fix is adapted from Milosz Pira's zlib/libpng
licensed change `217f1c03e89bdcce5f31af442f58810f66d6556e` in
https://github.com/Gcenx/DXVK-macOS/pull/20 (not merged upstream at review).
It assigns separate bindings to 2D, volume, cube and comparison variants,
including per-variant bound state, sampler updates and unbinding/reset.
ForgePlay adapts the reset path to this source version and preserves raw
fixed-function depth sampling alongside programmable comparison sampling.
The auto mode detects the MoltenVK driver; no game-name rule or FG setting
is involved. This changes descriptor slots, not the number of frame buffers.
The original author and DXVK license are retained in patch 0004 and LICENSE.
The zlib license has no express patent grant; no additional dependencies
are introduced, and the existing binary/static-runtime distribution applies.

Version `v1.10.3-forgeplay-d3d9.3` also corrects the programmable and
fixed-function shader compilers to describe push-constant byte size using the
computed size, rather than the byte offset. A zero-offset pixel-shader range
must retain its nonzero size so fragment-stage fog and alpha-reference state
is declared in the pipeline layout and uploaded by the existing context path.
The change preserves state updates, command lifetimes and shader algorithms;
it adds no game-specific policy or dependency. The reported L4D2 failure is
consistent with the missing fragment binding, but a successful source build
alone does not verify that the real game is fixed.

This two-assignment correction is authored by Facta-Leopard from the
existing upstream source and observed public Vulkan/Metal binding behavior.
It retains the existing DXVK copyrights and Zlib terms stated above.
