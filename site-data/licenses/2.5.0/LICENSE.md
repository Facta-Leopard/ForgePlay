# ForgePlay Release License Manifest

Historical operative-notice version: `1.3.1 (5)`

Historical native/runtime source baseline: `1.3_Release`

Historical baseline source commit: `a2165f50afe3964b238cb0cb9ecdc96787db9c4c`

Copyright (C) 2026 Facta-Leopard  
Original source: https://github.com/Facta-Leopard/ForgePlay

ForgePlay is a multi-license distribution. This index identifies the operative
1.3 release notice and the preserved component notices throughout this app,
including its embedded helpers, native libraries, and bundled Wine runtime.
It does not apply one license to every file or third-party component.

The historical 1.3.1 maintenance notice remains the baseline for the separate
compiled-wrapper permission below. The dated component sections and the bundled
runtime's own manifest/source notices identify later additions and revisions;
the historical identifiers above do not describe the current binary payload.
No third-party license is changed by this index.

## Lupain integration (2026-10-22)

The author-owned Lupain files and integration additions identified in
[LICENSES/Lupain/SCOPE.json](LICENSES/Lupain/SCOPE.json) are GPL-3.0-only,
Copyright (C) 2026 Facta-Leopard. Their covered source must accompany distribution;
no previous compiled-wrapper exception is inferred for these additions.
SpoofDPI and its dependencies retain their original authorship and licenses.
See [Lupain scope and third-party notices](LICENSES/Lupain/README.md).

## Operative 1.3 release notice

The exact author-approved notice is
[LICENSES/ForgePlayRelease13/LICENSE.txt](LICENSES/ForgePlayRelease13/LICENSE.txt).
Its scope, additional terms, and separate Swift wrapper permission govern the
identified author-owned material for this release. Read it together with the
preserved [Wine-derived source notice](LICENSES/ForgePlayRelease13/WINE-GAME-MODE-NOTICE.txt).

The native ForgePlay Game Mode and native ForgePlay Frame Generation files
identified in that notice are licensed under GNU General Public License,
version 3 only (`GPL-3.0-only`), with the stated author-owned-material terms.
Preserve the applicable attribution:

ForgePlay Game Mode  
ForgePlay Frame Generation  
Copyright (C) 2026 Facta-Leopard  
Original source: https://github.com/Facta-Leopard/ForgePlay

Unmodified license texts:
[GPL-3.0-only](LICENSES/GPL-3.0-only.txt) and
[LGPL-2.1-or-later](LICENSES/LGPL-2.1-or-later.txt).

## Separate permission for the author-owned Swift wrapper

Section 3 of the operative notice grants alternative permission to distribute
the identified Facta-Leopard-owned Swift wrapper contributions in compiled
binary form without providing their Swift source. It includes the identified
Swift contributions previously designated as Game Mode GPL source.

For this separately authorized wrapper distribution, that permission
supersedes earlier Swift-publication and combined-wrapper-source requirements
only to the extent they arise solely from those author-owned Swift
contributions. It does not revoke prior GPL grants or recipients' existing
rights. It does not create an exception for native GPL code, Wine-derived
code, or another copyright holder's material, and it does not establish legal
independence merely from an IPC or process boundary.

## Coordinator-specific scope (2026-09-30)

Popple voice integration (2026-10-01) is included in this GPL source scope.
The separately supplied Supertonic2 model/style weights retain OpenRAIL-M and
its use/redistribution conditions, not GPL or MIT; see
[model license and terms](LICENSES/Supertonic2/README.md).
[ONNX Runtime](LICENSES/ONNXRuntime/README.md) retains MIT and its dependency notices.

The original AI Coordinator implementation listed in
[LICENSES/ForgePlayCoordinator/SCOPE.json](LICENSES/ForgePlayCoordinator/SCOPE.json)
is licensed under [GNU GPL version 3 only](LICENSES/ForgePlayCoordinator/LICENSE.txt).
The author replaces the Coordinator ND terms for this revision with GPL-3.0-only;
copying, modification and redistribution are allowed under that license.
The actual inference/control runtime, including its eight Swift worker/shared
files, retains its Corresponding Source obligations. The older 1.3 permission
does not by itself exclude that implementation. The role-specific
[host wrapper permission](LICENSES/ForgePlayWrapper/PERMISSION.txt) and its
[exact file list](LICENSES/ForgePlayWrapper/SCOPE.json) separately permit the
identified author-owned host UI/connection wrappers in compiled binary form
without their source. Its limited author-owned combination permission does not
exclude runtime source, waive third-party obligations or revoke prior GPL grants.
The [Korean explanation](LICENSES/ForgePlayCoordinator/LICENSE.ko.txt), usage notices,
and [source boundary record](LICENSES/ForgePlayCoordinator/README.md) accompany it.
Listed native adapters remain GPL-3.0-only; listed interoperability declarations
and initial policy data use the separate MIT contract notice. OWLv2 remains
Apache-2.0. Other third-party licenses and previously granted rights are unchanged.
Official-app game restrictions are product policy, not additional GPL license
conditions. Distribution must supply the applicable complete Corresponding Source;
an older runtime-only source package is not a complete source release for this
Coordinator-enabled application merely because both are ForgePlay builds.

## Popple presentation source (2026-10-01)

The original mascot presentation code and asset-packing tool retain their prior
GPL-3.0-only grants. The two identified presentation wrappers additionally have
the exact author-owned binary permission above; the atlas-packing tool is not
an excluded wrapper.
[Popple provenance and scope](LICENSES/ForgePlayPopple/README.md) identify the files
and distinguish code permission from the mascot artwork and branding. This entry
does not create a new public artwork/branding license or change Wine/model terms.

## Optional Witcher 3 compatibility adapter (2026-10-03)

The optional title-specific FidelityFX forwarding adapter is adapted from
tholtman1-del's `witcher3-crossover-fix` under MIT. The original copyright notice,
license and exact source revision are preserved in
[LICENSES/Witcher3Compatibility/NOTICE.md](LICENSES/Witcher3Compatibility/NOTICE.md)
and [LICENSE.txt](LICENSES/Witcher3Compatibility/LICENSE.txt).
This separate component does not relicense ForgePlay's GPL components or claim
rights over the game's original FidelityFX loader. The original game DLL is
preserved locally when the user applies the workaround and is not redistributed
inside ForgePlay. The source-built adapter uses Windows system API imports;
the original repository's prebuilt DLL and installer scripts are not included.

## ForgePlay VR and ForgePlayVP implementation (2026-10-11)

The author-owned Mac VR runtime, Vision Pro application and shared VR
transport/media/input implementation are now licensed under `GPL-3.0-only`.
The [operative notice](LICENSES/ForgePlayVR/NOTICE.txt) and
[source scope](LICENSES/ForgePlayVR/SCOPE.json) replace the prior unpublished
Vision source policy and describe the limited existing host-wrapper permission.
Corresponding Source includes the covered Swift implementation and build code,
not only the native DLLs. Binary artwork and third-party components retain
their separate rights.

The Wine-derived `VRUnixBootstrap.cpp` remains LGPL-2.1-or-later with its
preserved additional linking permission and original authorship. Valve's
public OpenVR ABI declarations retain BSD-3-Clause. Project-authored VR
behavior is identified separately; this is not a claim of ownership of Wine,
SteamVR, the OpenVR SDK, Apple frameworks or games.

## Preserved earlier Game Mode records

The existing scope, inventory, symbol manifest, and related notices in
`LICENSES/ForgePlayGameMode/` and
`Runners/ForgePlayRuntime/Legal/ForgePlayGameMode/` remain preserved as records
of the earlier Game Mode GPL grant. References there to publication of the
author-owned Swift wrapper must be read with the operative 1.3 permission
above. Their preservation does not narrow previously granted rights or
replace the latest notice with the earlier Swift-publication requirement.
All applicable upstream copyrights and license notices remain in force.

## Wine and other separately licensed material

WebM playback uses the separately licensed GStreamer Matroska/libav and FFmpeg
components. Their exact versions, license locations and corresponding-source
materials are identified in [WebM playback notices](LICENSES/WebM/NOTICE.md).
The WebM container addition does not change the licenses of these components.

The native host's Wine-derived copy and the two Game Mode Wine patch copies
identified in the operative notice retain their GPL-3.0-only conversion under
LGPL 2.1 section 3. Preserve the Wine authorship, provenance, and applicable
complete source and build-material obligations. Unmodified Wine and other
non-converted copies retain their independent applicable LGPL permissions.
The separate Swift permission does not reduce these requirements.

Wine, MoltenVK, DXVK, renderers, fonts, and all other third-party material retain
their applicable licenses, notices, copyrights, and patent terms. Their
component notices remain in the app's existing legal and runtime directories.
D3DMetal remains a separately identified third-party runtime component under
its own Apple terms and is not relicensed under `GPL-3.0-only`. Its Apple
license, acknowledgements, framework license, and original Apple signatures
remain with that payload. This index grants no rights in third-party material
and does not expand Apple's terms.

Source publication is handled through separate release assets. The notices
inside this app do not replace applicable corresponding-source delivery,
build-material, or relinking obligations, and this index does not certify that
those separate obligations have been verified as complete.
