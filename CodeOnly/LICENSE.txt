ForgePlay 1.3_Release — source license and separate wrapper permission
Release source commit: a2165f50afe3964b238cb0cb9ecdc96787db9c4c
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay

This notice supplies the operative license scope for this release's native
source package and the separate permission below for the author-owned Swift
wrapper. Paths identify files in the release source tree; a package inventory
may record their corresponding archive paths. This is a multi-license package,
not a blanket license for every ForgePlay file or third-party component.

1. Native Game Mode and native Frame Generation: GPL-3.0-only

The following ForgePlay-authored native implementation and build material is
licensed under the GNU General Public License, version 3 only, with the
author-owned-material additional terms in section 2 of this notice. The full,
unmodified GPL-3.0-only license text accompanies this package. No separate
permission is needed for compliant use, including commercial use.

Native Game Mode files:
  Native/GameModeProcessHost/GameModeApplicationGroup.h
  Native/GameModeProcessHost/GameModeApplicationGroup.m
  Native/GameModeProcessHost/GameModeBuildIdentity.h
  Native/GameModeProcessHost/GameModeInheritedExecution.h
  Native/GameModeProcessHost/GameModeInheritedExecution.m
  Native/GameModeProcessHost/GameModeProcessHost.m
  Native/GameModeProcessHost/GameModeRuntimeIdentity.h
  Native/GameModeProcessHost/GameModeRuntimeIdentity.m
  Native/GameModeProcessHost/PrefixExecutionLease.h
  Native/GameModeProcessHost/PrefixExecutionLease.m

Native Frame Generation files:
  Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.m
  Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.h
  Native/D3DMetalFrameGenerationProxy/FrameGenerationStateMachine.c
  Native/D3DMetalFrameGenerationProxy/FrameGenerationStateMachine.h
  Native/D3DMetalFrameGenerationProxy/WineD3DOpenGLFrameGeneration.inc
  Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.exports

This code-only publication omits the private Swift wrapper, project tooling,
generated build projects and development/review documents. Source-code
publication is not itself a new binary distribution or a build verification.
The exclusion of project tools does not waive any build/installation-source
obligation applicable to a subsequent distribution of covered binaries.

The Wine-derived GameModeProcessHost.m copy remains GPL-3.0-only under the
existing LGPL 2.1 section 3 conversion. Its upstream copyright and source
provenance are preserved in WINE-GAME-MODE-NOTICE.txt. The grants for
ForgePlay-authored material do not replace the upstream copyright notices.

2. Additional terms for Facta-Leopard's covered native material

Under GPLv3 section 7, source distributions and legal notices accompanying
non-source distributions must preserve the applicable attribution:

  ForgePlay Game Mode
  ForgePlay Frame Generation
  Copyright (C) 2026 Facta-Leopard
  Original source: https://github.com/Facta-Leopard/ForgePlay

Use the component name or names corresponding to the conveyed material.
Where an interactive distribution provides an About, Legal, Credits, or
equivalent Appropriate Legal Notices interface, preserve that attribution
there as well. Reasonably mark modified versions as modified. Do not
misrepresent them as an official ForgePlay release or imply endorsement by
Facta-Leopard. No trademark rights in the ForgePlay name or logo are granted;
truthful origin identification is not prohibited. These terms apply only to
material for which Facta-Leopard holds the applicable copyright.

3. Separate permission for the author-owned Swift wrapper

Facta-Leopard identifies the ForgePlay-authored Swift wrapper contributions
at the release commit above as material owned by Facta-Leopard and grants an
alternative permission to use, copy, and distribute those contributions in
compiled binary form as part of the ForgePlay wrapper without providing their
Swift source. This permission includes the author-owned Swift contributions
previously designated as Game Mode GPL source, whether in dedicated Swift
files or in mixed application files. It is not limited to noncommercial use.

For this separately authorized wrapper distribution, this permission
supersedes the Swift-publication and combined-wrapper-source requirements in
Facta-Leopard's earlier Game Mode scope and related source-export notices to
the extent those requirements arise solely from the licensing of these
author-owned Swift contributions. The native-source package intentionally
does not contain Swift files and is not an archive of the complete Swift app.

This is an alternative copyright permission, not a revocation of any GPL
permission previously granted. Existing recipients retain their existing
GPL rights. No source-access right, trademark right, warranty, or right in
third-party material is created by this alternative permission. It is not an
exception for Wine-derived code, native GPL code, or any other third-party
code; it does not waive requirements arising independently from such code.
It does not assert that any particular IPC or process boundary establishes
legal independence. No proprietary permission for another copyright holder's
material is granted.

4. Wine source and patch boundary

These exact Game Mode patch copies retain their existing GPL-3.0-only
designation under LGPL 2.1 section 3:
  Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch
  Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch

Their version-matched bytes are not changed merely to insert license text.
This external notice records the designation. Conversion does not remove or
transfer Wine or other upstream copyrights. A Wine copy containing these
changes must be conveyed consistently with GPLv3 as a combined derivative
work; this obligation is not confined to the standalone patch files.

Unmodified Wine and non-Game-Mode Wine patch copies retain their independent
LGPL-2.1-or-later permissions and existing notices unless an applicable
per-file notice provides otherwise. This includes Wine's frame-generation
renderer, Metal-surface, and OpenGL hook integration; the project-authored
metal_surface_contract.h declaration header remains LGPL-2.1-or-later.
The complete applicable version-matched native and modified-Wine source,
necessary build and installation-control material, license texts, notices,
and source/patch identity information remain required when conveying their
covered binaries. Section 3 does not reduce these obligations.

5. Other separately licensed material

The MoltenVK 1.4.1 patch at
Native/MoltenVKFrameGeneration/moltenvk-1.4.1-frame-generation-capture.patch
retains Apache-2.0 terms for the modifications identified under that license.
MoltenVK and its dependencies retain their original applicable licenses,
copyrights, notices, and Apache patent terms. This notice does not convert
that patch or those dependencies to GPL-only.

Native/D9VK contains the ForgePlay derivative of DXVK v1.10.3's D3D9
frontend under the zlib/libpng license, with the original upstream notices
and separately licensed build-tool and dependency notices preserved.

Apple D3DMetal remains separately licensed Apple material, not GPL source.
No Apple binary or proprietary permission is supplied by this notice.
Other third-party material retains its own applicable terms. Preserve all
required upstream notices; the ForgePlay native GPL scope does not replace
them. Unrelated ForgePlay-authored material is not relicensed by inclusion
in this package or by this notice.

6. Warranty

Covered GPL material is supplied with the warranty disclaimer and limitation
of liability in GPLv3. The separately permitted author-owned Swift binary
contributions are supplied as is, without warranty of any kind, to the extent
permitted by applicable law. Nothing here removes rights that cannot lawfully
be excluded.
