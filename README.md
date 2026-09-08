# Tagentra

Tagentra is a cross-platform RFID device workbench for compatible Proxmark3
and Chameleon devices. The application is being developed in Flutter. The
first native milestone validates that several RRG Proxmark3 client revisions
can be packaged for iOS behind a small, stable C ABI.

## Apple PM3 core proof of concept

`TagentraPM3Core.xcframework` is generated from RRG's experimental `LIBPM3`
target plus the shim in `native/pm3_apple_shim`. It is not checked into the
repository. The build produces these slices:

- iOS device: arm64
- iOS Simulator: arm64 and x86_64
- minimum deployment target: iOS 15.0

The checked compatibility matrix pins four upstream releases in
`tool/pm3_apple/refs.json`. Every matrix job builds the framework, links a
minimal consumer, boots an iOS Simulator, and calls ABI version, revision,
initialization, `help`, invalid input, cancellation, and shutdown paths. A
separate weekly workflow probes current RRG `master` so upstream breakage is
visible before a pinned upgrade.

Cancellation is cooperative. It interrupts RRG command loops that poll the
client's keyboard-abort hook; a command blocked elsewhere returns when that
upstream operation next reaches an abort point or timeout.

On a Mac with Xcode, CMake, Git, and Python 3 installed:

```sh
./tool/pm3_apple/doctor.sh
./tool/pm3_apple/build.sh --ref v4.21611
revision="$(python3 -c 'import json; print(json.load(open("artifacts/TagentraPM3Core-build.json"))["upstream_revision"])')"
./tool/pm3_apple/smoke_test.sh artifacts/TagentraPM3Core.xcframework "$revision"
```

The public ABI is declared in
`native/pm3_apple_shim/include/TagentraPM3Core.h`. Phase one deliberately does
not implement BLE transport, device communication, or Flutter FFI. Offline
commands are enough to verify compilation, linking, loading, and lifecycle
behavior across upstream revisions.

## Updating RRG

Add a release and its full commit SHA to `tool/pm3_apple/refs.json`, then add
the release to the workflow matrix. The preparation script checks the RRG API
and every CMake edit before changing the temporary checkout. If upstream moves
or removes an expected integration point, the build stops with a focused
error rather than applying a partial patch.

## License

Tagentra is licensed under `GPL-3.0-or-later`. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Generated PM3 binaries are
derived from RRG Proxmark3; preserve the corresponding-source obligations
when distributing them.
