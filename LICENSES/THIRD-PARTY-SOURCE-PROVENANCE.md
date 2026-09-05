# ForgePlay 1.2 third-party source provenance

This source preparation is based on ForgePlay commit
`72a2598c99f0b649d1384ed0763a00037f5d1d2e`. It resolves five previously
unresolved source-material records in `Config/ForgePlayCopyleftSourcePackages.json`.
The baseline dependency locks, Runtime SBOM, runtime payload, license scopes,
and inventory consumer identities are unchanged. This is source preparation,
not evidence of a new application build, notarization, publication, or runtime test.

## GStreamer SDK source authority

The official [Cerbero 1.28.5 tag](https://gitlab.freedesktop.org/gstreamer/cerbero/-/tree/1.28.5)
resolves to commit `931c54b6eb1e5ba9287f38d5a7726f4ea87fe657`
(annotated tag object `9a3709ea852ac87d7f6990f45fc3f873b144350c`).
The uncompressed `git archive --format=tar` of that commit has SHA-256
`700e6c91506c2f13f927c8ac50363fb1e060e050472c923dca793e798540b544`.
It is delivered with all of its recipes and patches, including the FFmpeg,
GLib, and proxy-libintl build changes, not merely the three top-level recipes.

The recipes at that exact commit identify these upstream archives:

| Recipe | Source version | Source archive SHA-256 |
| --- | --- | --- |
| `recipes/ffmpeg.recipe` | 7.1 | `40973d44970dbc83ef302b0609f2e74982be2d85916dd2ee7472d30678a7abe6` |
| `recipes/glib.recipe` | 2.82.4 | `37dd0877fe964cd15e9a2710b044a1830fb1bd93652a6d0cb6b8b2dff187c709` |
| `recipes/proxy-libintl.recipe` | 0.5 | `f7a1cbd7579baaf575c66f9d99fb6295e9b0684a28b095967cfda17857595303` |

The inventory records these actual source versions, download authorities,
archive names, and hashes. FFmpeg's recorded runtime consumer version
`libavcodec-61.19.100` is a library version, not the FFmpeg source release name.
The relinking guide is the existing project-authored template, SHA-256
`5caec544918f5b747e29a32035f2b8103fc15adbb1d9393b94237088dfbd7373`.

## Preserved proxy-libintl metadata discrepancy

The baseline GStreamer lock and Runtime SBOM label the bundled proxy-libintl
consumer as **0.4**. The official GStreamer 1.28.5 Cerbero recipe instead
pins proxy-libintl source **0.5** and the archive hash shown above. These are
distinct fields: this preparation does not rename the source to 0.4 or claim
that the baseline consumer label is an authoritative upstream source version.

The exact SDK `lib/libintl.8.dylib` SHA-256 is
`d6506824bb269bab6c0bb85d96138c766304ac518d62afc0d3761ccc2cfc77d8`.
The baseline lock and Runtime SBOM both record that source-byte identity.
The associated SDK license and notice SHA-256 values are respectively
`b7993225104d90ddd8024fd838faf300bea5e83d91203eab98e29512acebd69c`
and `1b0ef316ea0204d4920b2695796f34683d3338a07a4db4d8597402ee54e83df7`.
The earlier ForgePlay source snapshot at
`f11ee94d626d96a6aecd60d607eb0b67dd81fb3a` labels those same three
byte-identical SDK inputs as 0.5; the relevant lock differences are only the
three version labels. The locally available SDK dylib hash was checked
against the baseline lock during this preparation.

Accordingly, `gst-proxy-libintl-source` delivers the actual **0.5** source
archive and retains **0.4** in `consumerBindings` solely to bind to the
unchanged baseline metadata. The shared Cerbero recipe and relinking-guide
bindings likewise retain that baseline consumer identity. No runtime bytes,
locks, SBOM fingerprints, or license texts are rewritten to conceal this
discrepancy. Recipients must use the supplied 0.5 source plus the supplied
Cerbero patches when tracing or rebuilding this SDK component.

The source-package verifier checks the declared source inventory, consumer
coverage, exact archive bytes, and receipt binding to the baseline locks and
SBOM. It does not independently prove a reproducible binary build or provide
a legal opinion.
