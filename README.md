# Tagentra

Tagentra is an offline-first RFID workbench for PM3 SE Hub Mini. The first
release targets iOS 15+ and is licensed under GPL-3.0-or-later.

The app now contains a Material device/workbench/card-library/settings shell,
an asynchronous Flutter plugin, a CoreBluetooth Nordic UART transport, a
loopback Network.framework TCP bridge, terminal streaming/cancellation, and an
atomic file-based card library. It does not contain accounts, network
authentication, announcements, analytics, or firmware updating.

## PM3 Core

`TagentraPM3Core.xcframework` is built from the pinned RRG Proxmark3 release in
`tool/pm3_apple/refs.json`. ABI v2 exposes explicit major/minor versions,
capabilities, offline and TCP initialization, resource-root configuration,
streamed output, cooperative cancellation, shutdown, and a copyable last-error
message. The overlay replaces RRG's process-terminating connection error on iOS
and checks every upstream edit point before changing the source.

The build produces iOS device arm64 and Simulator arm64/x86_64 slices with an
iOS 15.0 deployment target. Required RRG resources, dictionaries, Lua libraries,
and scripts are placed in each framework's `Resources/pm3` directory.

On macOS with Xcode, CMake, Git, and Python 3:

```sh
./tool/pm3_apple/build.sh --ref v4.21611
revision="$(python3 -c 'import json; print(json.load(open("artifacts/TagentraPM3Core-build.json"))["upstream_revision"])')"
./tool/pm3_apple/smoke_test.sh artifacts/TagentraPM3Core.xcframework "$revision"
./tool/pm3_apple/package_release.sh artifacts
```

Ordinary CI builds only `current`. The weekly upstream workflow queries the
latest stable RRG GitHub Release, builds and tests it as `candidate`, then opens
a review PR. It never follows `master` or promotes a release automatically.

## Immutable binary release and SwiftPM

Run the `Release PM3 Core` workflow manually for the first public binary. It
fails if `pm3core-v4.21611-t1` already exists and publishes the XCFramework ZIP,
corresponding source, build metadata, GPL license, third-party notices, and
SHA-256 sums.

The SwiftPM manifest is intentionally finalized only from the actual immutable
asset—there is no placeholder checksum accepted by the build:

```sh
curl -fLO https://github.com/fly6516/tagentra/releases/download/pm3core-v4.21611-t1/TagentraPM3Core.xcframework.zip
python3 tool/pm3_apple/configure_swiftpm.py TagentraPM3Core.xcframework.zip
swift package --package-path packages/tagentra_pm3/ios resolve
```

Commit the generated `packages/tagentra_pm3/ios/Package.swift` after its minimal
iOS consumer has downloaded, linked, and loaded the framework. Release tags and
assets are immutable; bump `adapter_revision` for any rebuilt adapter.

## Device transport

The iOS plugin scans Nordic UART service
`6e400001-b5a3-f393-e0a9-e50e24dcca9e`, records discovered characteristic
properties, enables notifications, then listens on a random loopback TCP port.
TCP writes are split using CoreBluetooth's maximum write length and paused when
write-without-response backpressure is active; notifications are returned to
the TCP client byte-for-byte. Only one PM3 command runs at a time.

Chameleon-to-PM3 uses `REBOOTPM3`. PM3-to-Chameleon deliberately reports an
unsupported error until the exact hardware command is captured and reviewed.
See [the hardware validation runbook](docs/ios-hardware-validation.md).

## Development

```sh
flutter pub get
dart format --output=none --set-exit-if-changed lib test packages/tagentra_pm3/lib
flutter analyze
flutter test
flutter build ios --release --no-codesign
```

Generated PM3 binaries are derived from RRG Proxmark3. Distributions must keep
the corresponding source and notices together with the binary; see `LICENSE`
and `THIRD_PARTY_NOTICES.md`.
