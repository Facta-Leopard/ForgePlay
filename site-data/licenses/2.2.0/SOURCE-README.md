# ForgePlay public source

The exact release version/build is recorded in `SOURCE-BOUNDARIES.json`.

This kit separates ForgePlay implementation (`ForgePlay/`), Wine originals,
patches and derived adapters (`Wine/`), separately licensed upstream material
and identified adaptations (`ThirdParty/`), build inputs (`Build/`) and license
notices (`Notices/`). Directory names do not replace per-component licenses.

Read `Notices/LICENSE.md` and `Notices/LICENSES/ForgePlayVR/NOTICE.txt` with its
scope. The original Mac VR, Vision Pro and shared VR implementation is covered
by GPL-3.0-only. Wine-derived files keep their original attribution and
applicable LGPL/GPL terms; Valve ABI declarations keep BSD-3-Clause. This is
not a complete source release of the separately permitted Mac/Launcher wrappers.

Missing author copyright comments were added to the publication copy. Code
statements and original upstream notices are unchanged. `SOURCE-BOUNDARIES.json`
records both compiled-input and publication hashes; it does not assert that
different build environments produce byte-identical signed binaries. Strict
configuration files, patches and upstream archives were not rewritten to add
comments. Original licenses and already granted rights remain in force.

Restore the original relative build layout into a fresh directory:

```sh
python3 restore-layout.py --output /path/to/new/ForgePlaySources
```

Then follow `BUILDING.md` there. The restorer verifies hashes and paths and
does not run Wine, install software or modify an existing destination.
Brand artwork/model weights retain separate rights. Vision app archiving,
signing, App Store submission and publication of matching source links remain
separate release steps. See `README.ko.md` for the Korean guide.

Copyright (C) 2026 Facta-Leopard. Upstream rights remain with their authors.
Original project: https://github.com/Facta-Leopard/ForgePlay
