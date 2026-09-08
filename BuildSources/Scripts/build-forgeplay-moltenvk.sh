#!/bin/bash
# Build the reviewed MoltenVK sources entirely inside a fresh workspace run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 - "$SCRIPT_DIR/.." "$@" <<'PY'
from pathlib import Path, PurePosixPath
import hashlib
import json
import os
import posixpath
import shutil
import subprocess
import sys
import tarfile

repository = Path(sys.argv[1]).resolve()
if len(sys.argv) != 4:
    raise SystemExit("usage: build-forgeplay-moltenvk.sh <locked-archives-directory> <fresh-build-run>")
archives = Path(sys.argv[2]).resolve(strict=True)
output = Path(sys.argv[3]).resolve()
if repository not in archives.parents or not archives.is_dir():
    raise SystemExit("source archives must belong to the ForgePlay workspace")
if (repository / "Artifacts/Builds") not in output.parents or output.exists():
    raise SystemExit("output must be a fresh directory under workspace Artifacts/Builds")
jobs = int(os.environ.get("FORGEPLAY_MOLTENVK_BUILD_JOBS", "3"))
if not 1 <= jobs <= 16:
    raise SystemExit("FORGEPLAY_MOLTENVK_BUILD_JOBS must be between 1 and 16")
lock_path = repository / "Config/ForgePlayMoltenVKSource.lock.json"
lock = json.loads(lock_path.read_text())
if lock.get("schemaVersion") != 1 or lock.get("architecture") != "x86_64":
    raise SystemExit("unsupported MoltenVK source lock")
patch = repository / lock["patch"]["path"]
if hashlib.sha256(patch.read_bytes()).hexdigest() != lock["patch"]["sha256"]:
    raise SystemExit("MoltenVK patch differs from its reviewed source lock")
for item in lock["components"]:
    archive = archives / item["archiveFile"]
    if archive.is_symlink() or not archive.is_file():
        raise SystemExit(f"missing regular archive: {archive}")
    if hashlib.sha256(archive.read_bytes()).hexdigest() != item["archiveSHA256"]:
        raise SystemExit(f"archive hash mismatch: {archive}")
output.mkdir(parents=True)
for directory in ("Source", "tmp", "build", "cache/cpm", "product/lib", "product/include/MoltenVK", "product/etc/vulkan/icd.d", "product/Legal"):
    (output / directory).mkdir(parents=True, exist_ok=True)
source_paths = {}
for item in lock["components"]:
    with tarfile.open(archives / item["archiveFile"]) as archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] != item["sourceDirectory"]:
                raise SystemExit(f"unsafe archive member: {member.name}")
            link_target = PurePosixPath(posixpath.normpath(str(path.parent / member.linkname))) if member.issym() else None
            if member.isdev() or member.islnk() or (link_target is not None and (link_target.is_absolute() or not link_target.parts or link_target.parts[0] != item["sourceDirectory"])):
                raise SystemExit(f"unsupported archive member: {member.name}")
        archive.extractall(output / "Source")
    source_paths[item["name"]] = output / "Source" / item["sourceDirectory"]
    legal = output / "product/Legal" / item["name"]
    legal.mkdir()
    for relative in item["licenseFiles"]:
        destination = legal / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_paths[item["name"]] / relative, destination)
source = source_paths["MoltenVK"]
environment = dict(os.environ, TMPDIR=str(output / "tmp"), PYTHONDONTWRITEBYTECODE="1",
                   CPM_SOURCE_CACHE=str(output / "cache"))
environment.pop("CCACHE_DIR", None)
environment["CCACHE_DISABLE"] = "1"

def run(arguments, log_name, cwd=output):
    print("Running:", " ".join(map(str, arguments)), flush=True)
    with (output / log_name).open("w") as log:
        result = subprocess.run(list(map(str, arguments)), cwd=cwd, env=environment, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((output / log_name).read_text()[-20000:], file=sys.stderr)
        raise SystemExit(result.returncode)

run(["patch", "-p1", "--batch", "-i", patch], "patch.log", source)
shutil.copyfile(source_paths["CPM.cmake"] / "cmake/CPM.cmake", output / "cache/cpm/CPM_0.40.8.cmake")
cmake = shutil.which("cmake")
ninja = shutil.which("ninja")
if not cmake or not ninja:
    raise SystemExit("existing cmake and ninja are required; this builder installs no tools")
clang = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
clangxx = subprocess.check_output(["xcrun", "--find", "clang++"], text=True).strip()
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
revision = lock["components"][0]["revision"][:12] + "+forgeplay-fg-query1"
flags = f"-ffile-prefix-map={output}=/forgeplay-moltenvk"
configure = [cmake, "-S", source, "-B", output / "build", "-G", "Ninja",
             f"-DCMAKE_MAKE_PROGRAM={ninja}", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=x86_64",
             f"-DCMAKE_OSX_DEPLOYMENT_TARGET={lock['deploymentTarget']}", f"-DCMAKE_OSX_SYSROOT={sdk}",
             f"-DCMAKE_C_COMPILER={clang}", f"-DCMAKE_CXX_COMPILER={clangxx}",
             f"-DCMAKE_OBJC_COMPILER={clang}", f"-DCMAKE_OBJCXX_COMPILER={clangxx}",
             f"-DCMAKE_INSTALL_PREFIX={output / 'stage'}", f"-DMVK_GIT_REV={revision}",
             "-DMOLTEN_VK_WITH_CCACHE=OFF", "-DMVK_USE_METAL_PRIVATE_API=OFF", "-DMVK_CONFIG_LOG_LEVEL=info",
             "-DMVK_EXCLUDE_CEREAL=OFF", "-DMVK_EXCLUDE_SPIRV_TOOLS=OFF", "-DMVK_BUILD_SHADER_CONVERTER_TOOL=OFF",
             "-DSPIRV_SKIP_EXECUTABLES=ON", "-DSPIRV_SKIP_TESTS=ON", "-DSPIRV_WERROR=OFF", "-DBUILD_TESTS=OFF",
             "-DFETCHCONTENT_FULLY_DISCONNECTED=ON", "-DFETCHCONTENT_UPDATES_DISCONNECTED=ON",
             "-DCPM_LOCAL_PACKAGES_ONLY=ON", f"-DCPM_SOURCE_CACHE={output / 'cache'}"]
for language in ("C", "CXX", "OBJC", "OBJCXX"):
    configure.append(f"-DCMAKE_{language}_FLAGS={flags}")
for name in ("SPIRV-Cross", "SPIRV-Headers", "SPIRV-Tools", "Vulkan-Headers", "cereal"):
    configure.append(f"-DCPM_{name}_SOURCE={source_paths[name]}")
run(configure, "configure.log")
run([cmake, "--build", output / "build", "--target", "MoltenVK", "--parallel", str(jobs)], "build.log")
library = output / "product/lib/libMoltenVK.dylib"
shutil.copyfile(output / "build/MoltenVK/libMoltenVK.1.4.1.dylib", library)
run(["install_name_tool", "-id", "@rpath/libMoltenVK.dylib", library], "install-name.log")
run(["codesign", "--force", "--sign", "-", library], "adhoc-sign.log")
run(["lipo", library, "-verify_arch", "x86_64"], "architecture.log")
run(["otool", "-L", library], "dependencies.log")
run(["nm", "-gU", library], "exports.log")
for name in ("_vkGetInstanceProcAddr", "_vkCreateInstance"):
    if name not in (output / "exports.log").read_text():
        raise SystemExit(f"built MoltenVK is missing public export: {name}")
for header in (source / "MoltenVK/include/MoltenVK").glob("*.h"):
    shutil.copyfile(header, output / "product/include/MoltenVK" / header.name)
icd = {"file_format_version":"1.0.0", "ICD":{"library_path":"../../../lib/libMoltenVK.dylib", "api_version":"1.4.0", "is_portability_driver":True}}
(output / "product/etc/vulkan/icd.d/MoltenVK_icd.json").write_text(json.dumps(icd, indent=2) + "\n")
shutil.copyfile(lock_path, output / "product/Legal/ForgePlayMoltenVKSource.lock.json")
shutil.copyfile(patch, output / "product/Legal" / patch.name)
notices = ["# ForgePlay MoltenVK build\n", "MoltenVK 1.4.1 is modified by ForgePlay contributors under Apache-2.0.\n",
           "The optional bridge associates a tracked source drawable with its existing command buffer before submission. Original scheduled presentation is preserved.\n",
           "The archive build supplies its pinned upstream revision plus a ForgePlay modification suffix.\n",
           "When debugMode is enabled, terminal command-buffer errors additionally report bounded NSError identifiers and actual Metal error-option/encoder-info availability. No raw userInfo values or resource contents are logged; normal rendering and device-loss handling are unchanged. This instrumentation does not fix a GPU error.\n",
           "Occlusion-query wrap-baseline correction is backported from upstream commit c8a9b178383e8a2a35283409ab29b65b7066761e by As Cold As Ice (BXYMartin), Apache-2.0: https://github.com/KhronosGroup/MoltenVK/commit/c8a9b178383e8a2a35283409ab29b65b7066761e . ForgePlay additionally corrects visibility-buffer half-fence selection and records read-completion fences after accumulation dispatches. These corrections do not establish L4D2 compatibility.\n",
           "All included license texts and attribution files must accompany redistributed binaries. Apache-2.0 components retain their copyright and patent-license terms.\n"]
for item in lock["components"]:
    notices.append(f"- {item['name']}: {item['revision']}; {item['copyright']}; {item['licenseExpression']}; {item['repository']}.\n")
(output / "product/Legal/NOTICE-ForgePlay.md").write_text("\n".join(notices))
receipt = {"schemaVersion":1, "architecture":"x86_64", "sourceLockSHA256":hashlib.sha256(lock_path.read_bytes()).hexdigest(),
           "patchSHA256":lock["patch"]["sha256"], "librarySHA256":hashlib.sha256(library.read_bytes()).hexdigest(),
           "sourceRevision":revision, "buildJobs":jobs, "buildCommand":list(map(str, configure)),
           "xcodeVersion":subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
           "gameRenderingVerified":False}
(output / "build-receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
public_record = {key: receipt[key] for key in ("schemaVersion", "architecture", "sourceLockSHA256", "patchSHA256", "librarySHA256", "sourceRevision", "xcodeVersion", "gameRenderingVerified")}
public_record.update({"producer":"ForgePlay", "upstreamVersion":"1.4.1", "deploymentTarget":lock["deploymentTarget"],
                      "buildScriptSHA256":hashlib.sha256((repository / "Scripts/build-forgeplay-moltenvk.sh").read_bytes()).hexdigest(),
                      "configuration":"Release", "metalPrivateAPI":False, "buildTimeDownloads":False})
(output / "product/Legal/SourceBuildRecord.json").write_text(json.dumps(public_record, indent=2, sort_keys=True) + "\n")
print(f"Built {library}\nSHA-256: {receipt['librarySHA256']}", flush=True)
PY
