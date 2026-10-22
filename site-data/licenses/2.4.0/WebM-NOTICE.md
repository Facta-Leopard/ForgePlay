# WebM playback components

ForgePlay 2.2.1 includes Matroska/WebM container support through the unmodified
GStreamer Good Plug-ins 1.28.5 `libgstmatroska` module. This library is licensed
under GNU Library General Public License version 2 or, at your option, any later
version (`LGPL-2.0-or-later`). Copyright belongs to the GStreamer contributors;
the corresponding source preserves each file's author and copyright notices.

VP8/VP9 video decoding uses the existing GStreamer libav 1.28.5 and FFmpeg 7.1
libraries (libavcodec 61.19.100). GStreamer libav carries LGPL-2.0-or-later terms;
the distributed FFmpeg libraries carry LGPL-2.1-or-later terms. The WebM container
addition does not add a libvpx or libwebm binary or relicense any existing code.

Unmodified license texts and supplier notices are included in the app at:

- `Runners/ForgePlayRuntime/Legal/GStreamer/GStreamerGood/`
- `Runners/ForgePlayRuntime/Legal/GStreamer/GStreamerLibav/`
- `Runners/ForgePlayRuntime/Legal/GStreamer/FFmpeg/`

The matching ForgePlay source distribution includes the GStreamer Good/libav
1.28.5 and FFmpeg 7.1 source archives, the pinned Cerbero build recipes and the
dynamic-library relinking instructions. The runtime SBOM and source-package
inventory identify the exact files and hashes. Preserve these materials and
upstream notices when redistributing the application; a notice alone does not
replace corresponding-source or relinking obligations.

WebM is a container/codec ecosystem, not one license for every implementation.
The WebM Project publishes its software licenses, specification terms and
additional patent grants separately. This notice identifies ForgePlay's shipped
software licenses and does not change any upstream patent or trademark terms.

References:

- https://gstreamer.freedesktop.org/documentation/matroska/
- https://gitlab.freedesktop.org/gstreamer/gstreamer/-/tree/1.28.5/subprojects/gst-plugins-good/gst/matroska
- https://ffmpeg.org/legal.html
- https://www.webmproject.org/license/

## 한국어 안내

WebM 파일을 여는 구성요소는 GStreamer Good Plug-ins의 Matroska 모듈이며
LGPL-2.0-or-later가 적용됩니다. VP8/VP9 영상은 기존 GStreamer libav와 FFmpeg 경로로
재생하며, 동봉 FFmpeg 라이브러리에는 LGPL-2.1-or-later가 적용됩니다.
위 경로에 원문 라이선스와 공급자 고지가 포함되어 있습니다.

대응 공개 소스에는 해당 버전의 소스 압축파일, 빌드 자료와 라이브러리 교체 안내가
포함됩니다. 재배포 시 고지뿐 아니라 적용되는 소스 제공·재링크 조건도 보존해야 합니다.
WebM이라는 이름만으로 서로 다른 구현의 라이선스나 특허 조건을 하나로 취급하지 않습니다.
