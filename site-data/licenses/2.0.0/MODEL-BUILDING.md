# Neural Rendering model source and rebuild

## Source, license and changes

- Upstream: https://github.com/stefanos50/HyPER-GAN
- Commit: `5a7e8afb802e2f28e78a29884d5164b805a05e49`.
- Copyright (c) 2026 Stefanos Pasios; MIT. Preserve `LICENSES/HyPERGAN/LICENSE`.
- `gta2cs.pth`: SHA-256 `db535f7b34b722dc83a9d02db5d86dd59530c06d7eb77b96c8455c9aa14d0185`.
- `gta2vistas.pth`: SHA-256 `1b1dc321068af189d5834fb14b703447e67a7da954f35aa1651681ffc4418412`.
- Each checkpoint has 6,172,291 trained parameters. The supplied checkpoint
  and generator bytes are unchanged. No new training or NVIDIA model is used.
- ForgePlay maps the original generator to a canonical NHWC/OHWI layout,
  emits a Core AI graph, and converts deployment weights/IO to FP16.
  Instance-normalization reductions are represented with FP32 arithmetic.
  The topology and original learned parameters are not replaced by a new model.

`Upstream/HyPERGAN/` contains the pinned upstream files, both original
checkpoints, canonical FP32/FP16 Safetensors and their hash manifest.
`Resources/NeuralModels/HyPERGAN/*.sha256.json` are the six manifests copied
from the signed app. They identify the shipped model bytes; compiled model
assets can be obtained from the matching app, not from this source archive.

Required conversion/validation code is in `Tools/NeuralRendering/`.
The author's additions have the GPL scope in the 2.0 notice; this does not
replace the upstream MIT license on generator/weights/derived model material.
No checkpoint-specific license was found in the pinned upstream snapshot;
dataset names are not a license grant for the underlying datasets.

## Environment

Use Apple Silicon, macOS 27, Xcode 27 and a compatible Python environment.
Install the exact development versions in `Tools/NeuralRendering/requirements.txt`:
Core AI Python authoring 1.0.0b2, MLX/MLX Metal 0.32.2, NumPy 2.5.3,
Safetensors 0.8.0 and PyTorch 2.14.0. Obtain Apple's authoring package under
Apple's own distribution/license terms. These Python packages are development
dependencies and are not bundled into the game runtime.

## Example: gta2cs at 1280×720

Run from the extracted source root with those dependencies installed. Use a
fresh output directory for each command. The included canonical bundle can
be used offline; `import_weights.py --output <new-directory>` can independently
fetch and verify the pinned upstream Git blobs and regenerate that bundle.

```sh
python3 Tools/NeuralRendering/parity.py \
  --bundle Upstream/HyPERGAN --model gta2cs --height 720 --width 1280 \
  --output Artifacts/Builds/model-rebuild/parity

python3 Tools/NeuralRendering/export_coreai.py \
  --bundle Upstream/HyPERGAN --model gta2cs --height 720 --width 1280 \
  --precision fp16 --output Artifacts/Builds/model-rebuild/export

USE_OS_COREAI=1 python3 Tools/NeuralRendering/probe_coreai.py \
  --export Artifacts/Builds/model-rebuild/export \
  --fixtures Artifacts/Builds/model-rebuild/parity \
  --output Artifacts/Builds/model-rebuild/probe

python3 Tools/NeuralRendering/package_model.py \
  --export Artifacts/Builds/model-rebuild/export \
  --parity Artifacts/Builds/model-rebuild/parity \
  --probe Artifacts/Builds/model-rebuild/probe \
  --destination Artifacts/Builds/model-rebuild/Models/HyPERGAN
```

Repeat for `gta2cs` and `gta2vistas` at 960×544, 1280×720 and 1920×1080 with
distinct output directories. Do not use `--optimize` to substitute a different
graph for the recorded release inputs. Compare regenerated graph/weight hashes
with the shipped manifests; compiler/platform variation may prevent a
byte-identical asset. Do not describe a new output as byte-identical unless
the comparison actually passes. The numeric fixtures verify model behavior,
not a guarantee of in-game quality, performance or NPU placement.

## Replacing covered native components

Build the GPL native proxy, Game Mode host and inference helper using
`BUILDING.md`. The inference helper uses the macOS Core AI system framework;
it is not the private Swift UI. Replace only matching components in a copy
of the app, use the matching model manifests and runtime identities, and
sign the modified copy with your own authorized signing/App Group settings.
Changes invalidate the original signature/notarization. Keep identity and
validation contracts intact; never use the original developer's keys or
claim that the modified build remains the original notarized distribution.
