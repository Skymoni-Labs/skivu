# In-app updates

Users update in **Settings → Check for updates**. A release is complete only
when its signed assets and the live `/api/app-update/latest` registry agree,
and an installed older app downloads, verifies, installs and reopens it.
ADB installation is suitable for creating an isolated starting fixture; it is
not evidence that the in-app upgrade itself works.

## 0.2.96 → 0.2.97 bridge

0.2.96 rejects APK metadata above 262144000 bytes. Its complete bundled APK
exceeds this value, so merely publishing another large APK cannot upgrade that
installed client. 0.2.97 ships the host and signed-in-build runtime identity in
the APK. The complete, unchanged Linux archive is downloaded on first use from
the exact `skymoni.com/skivu-runtime/cloud/<sha>/<abi>/runtime.bin` URL pinned
in that metadata. Existing installed roots with the same SHA are reused before
any download. This retains the app-owned PRoot/Node environment, projects,
dependencies and home data without an independent provider application.

Downloads stream to a private partial file, resume only with a matching HTTP
range and total size, verify complete size and SHA-256, and publish atomically.
Cancellation preserves incomplete downloads. Invalid origins, ranges and
hashes never install an archive. The existing safe tar extraction and staged
root publication remain in use. The workspace shows first-use download
progress. Failed initialization cannot dispatch a subsequent coding command.

The new updater accepts positive APK sizes without its former fixed ceiling;
package name, original signer, higher build code, ABI, SDK and full downloaded
hash/length checks remain mandatory. The corresponding server release
validator also removes its old 256 MiB ceiling. Runtime registry metadata stays
in the signed APK; plugins cannot choose its URL or checksum.

## Build and publish

Commit sources, then build each ABI sequentially with the existing E-drive
Flutter/Android toolchain:

```powershell
tools/build_update.ps1 -Abi arm64-v8a -Legacy096
tools/build_update.ps1 -Abi x86_64 -Legacy096
```

`-Legacy096` is an explicit compatibility check for this bridge, not an ongoing
product limit. The helper stages downloadable runtime metadata, refreshes
Flutter plugin registration, verifies the original production certificate and
normal package ID, and writes a source/hash manifest. The standalone staging
tool still offers `--delivery embedded` for complete offline builds.
The committed `tools/cloud-runtime-lock.json` lets a download-mode source build
run without the author's local runtime cache. Available local archives are
checked against the same lock before staging.

Publish the exact ABI-specific APKs to the official Skivu release, verify the
remote asset digests, and append both identities to the existing update
registry atomically. Preserve older releases. Verify both older-client
availability and same/newer-version non-availability. Keep TLS, source allowlist,
hash, signer and Android installation checks. Android may request unknown-source
permission and installation confirmation.

Use a dedicated emulator for update tests. Keep the old app installed through
the complete test and compare its UID, first install time and private file
hashes after upgrading. Never let Flutter drive or a test cleanup uninstall the
normal package. Native runtime acceptance uses the distinct `.updateqa` package
and its own test document-provider authority. Run classes explicitly; legacy
acceptance classes have different package guards and should not be run against
the normal package.

The bundled prompt plugin is the already-published 1.1.0 package, byte-for-byte.
Its prompt remains hidden; release validation inspects identity and checksums.
The legacy library plugin in `test/fixtures` is only a host-contract fixture and
is not bundled in the released app.
