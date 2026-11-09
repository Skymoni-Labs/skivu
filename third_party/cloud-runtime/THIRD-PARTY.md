# Third-party software and corresponding source

This distribution combines separately licensed components. Skivu's original
service, JNI runner, adapters and entry plugin are GPL-3.0-only. This does not
replace licenses of the engine, tools or libraries.

- DeepSeek Harness 0.2.1-rc.2 and its npm dependencies: exact versions and
  registry integrity values are in `tools/npm/package-lock.json`; additional
  package licenses/repositories are inventoried in `provenance/npm-packages.json`.
  The runtime preserves the installed packages' LICENSE, NOTICE, COPYING,
  copyright files and source maps where supplied upstream. Corresponding npm
  distributions are available from the lockfile's exact registry URLs.
- DSHA: https://github.com/DSH-APP/DSHA (MIT). Its locked npm runtime distribution
  was the starting point. The Android transport and service here are separate
  Skivu implementations; there is no redistribution of the DSHA APK.
- PRoot: `third_party/proot`, GPL-2.0-or-later; upstream Termux/PRoot and the
  Operit2 source tree at commit `6d1f96ee741b068f153f569e4ea69ca9f62c68b6`.
  All distributed modifications are included in this repository. Namespace,
  mount and tracing-breaking operations fail; no successful sandbox setup is
  claimed. `tools/build-native.sh` is the build recipe.
- talloc 2.4.3: `third_party/talloc`, LGPL-3.0-or-later; preserved full source,
  headers, license and the Android configuration used to build it. The PRoot
  executable can be rebuilt and replaced by users in their own build.
- Node 24.18.1: https://nodejs.org/dist/v24.18.1/ ; MIT and bundled third-party
  licenses in the Node distribution. Its source archive accompanies the Release
  sources. Skivu does not modify Node.
- Ubuntu 24.04 base: package-specific licenses preserved in
  `/usr/share/doc/*/copyright` and `/usr/share/common-licenses` in the runtime.
  `provenance/ubuntu-packages-*.json` records exact installed package versions.
  `provenance/ubuntu-source-files.json` records complete source package files,
  canonical Ubuntu/Launchpad URLs and SHA-256 values. The Release includes those
  files as a corresponding-source archive; use `dpkg-source -x` on each `.dsc`.
- libvips and its bundled native dependencies: the sharp-libvips 1.3.4
  distribution retains its LGPL license and third-party notices. Its unmodified
  build recipe, pinned versions and exact source archive/patch downloads are
  recorded in `provenance/sharp-libvips-*` and `extra-source-files.json`.
  The Release source archive includes these inputs. Users may replace/relink
  these libraries in a modified runtime and rebuild/sign/install the component.

Source archives are offered beside the binary APKs, without a separate fee,
from https://github.com/skyjjgw/skivu-dsh-runtime/releases . They contain the
matching source inputs and patches rather than private user data, credentials,
signing keys or operational configuration. Build tools themselves are obtained
from their official distributors. No restriction on debugging modified LGPL
libraries or replacing the worker is imposed by this source distribution;
an independently signed build must use a correspondingly configured trusted
host because Android signature permissions enforce the caller boundary.
