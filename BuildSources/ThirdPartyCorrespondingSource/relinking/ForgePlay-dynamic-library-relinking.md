# Replacing ForgePlay's Dynamically Linked Copyleft Libraries

This document accompanies the exact third-party source package for a ForgePlay
release. It explains how a recipient can replace the dynamically linked
LGPL/GPL-compatible libraries bundled under the ForgePlay Runtime without
requiring ForgePlay's private Apple signing credentials.

It is not a promise that an arbitrary modified library is ABI-compatible, and
it does not grant rights in Apple D3DMetal or any other separately licensed
component. The applicable license texts and component identities remain the
authority.

## 1. Identify the release and source set

Use only a source package whose receipt is bound to the same release manifest,
Runtime SBOM, dependency locks, and host-support payload fingerprint as the app
being modified. Verify the source archive and receipt with:

```sh
python3 Scripts/verify-copyleft-source-packages.py \
  --inventory Config/ForgePlayCopyleftSourcePackages.json \
  --dependency-lock Config/ForgePlayRuntimeDependencies.lock.json \
  --gstreamer-lock Config/ForgePlayGStreamerPayload.lock.json \
  --runtime-sbom Resources/Runners/ForgePlayRuntime/RuntimeSBOM.json \
  --archive ForgePlay-ThirdPartyCorrespondingSource.tar \
  --receipt ForgePlay-ThirdPartyCorrespondingSource.receipt.json
```

The filenames used by an actual release include the release version. Supply
those paths in place of the generic names above.

## 2. Rebuild a compatible replacement

The source package contains the exact upstream source archives and build
recipes identified in `Config/ForgePlayCopyleftSourcePackages.json`.

- GStreamer SDK libraries use the bundled Cerbero source and recipes for the
  recorded SDK release.
- Homebrew-sourced libraries use the exact formula revisions and upstream
  source archives recorded in the inventory.
- Apply the patches, configuration switches, architectures, and dependency
  versions from those recipes. Preserve the released library's public ABI,
  Mach-O architecture, install name, compatibility version, current version,
  and transitive dependency names.

ForgePlay currently runs its Wine host closure as x86_64 under Rosetta. A
replacement for a bundled x86_64 dynamic library must therefore remain
x86_64 and must not introduce a dependency outside the app's self-contained
Runtime closure.

Before installing a replacement, compare it with the shipped library:

```sh
file /path/to/replacement.dylib
lipo -archs /path/to/replacement.dylib
otool -D /path/to/replacement.dylib
otool -L /path/to/replacement.dylib
```

## 3. Install into a private copy of the app

Work on a copy of `ForgePlay.app`; do not modify an installed release in place.
Locate the library path from `RuntimeSBOM.json` and replace only that exact
regular file. Preserve the filename and install name. Do not add symlinks,
hardlinks, set-id files, extended-attribute payloads, or files outside the
recorded Runtime path.

After replacement, ad-hoc sign the modified app locally:

```sh
codesign --force --deep --sign - /path/to/Modified-ForgePlay.app
codesign --verify --deep --strict --verbose=2 /path/to/Modified-ForgePlay.app
```

Ad-hoc signing does not use, disclose, or require ForgePlay's Developer ID
private key. It changes the app's signature identity. A locally modified app
is not the original notarized release, its original notarization assurance no
longer applies to the modified bytes, and Gatekeeper or sandbox identity checks
may require the user to authorize the local build separately.

## 4. Validate the modified closure

Run the source tree's static Runtime and Mach-O closure verifiers against the
modified app where applicable. Then test the modified copy with a disposable
managed prefix before using valuable game data. At minimum verify:

- the replacement architecture and install name;
- every transitive dependency resolves inside the app or to an allowed macOS
  system library;
- the app passes `codesign --verify --deep --strict` after local signing;
- Steam startup, media playback, and a clean quit complete without loading the
  original replaced library from another path.

The official ForgePlay release signature and notarization receipt certify only
the unmodified release. Distribute a modified build only when you independently
satisfy every applicable third-party license, Apple platform rule, signature,
notice, source, and trademark obligation.
