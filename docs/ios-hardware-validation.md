# iOS hardware validation

Use an iPhone on iOS 15 or later, PM3 SE Hub Mini, and expendable MIFARE
Classic, MFU/NTAG, ISO15693, T5577/EM4305 test cards. Never perform a write test
against access cards, payment cards, identity documents, or a card without
explicit authorization.

## Transport and mode capture

1. Start a development-signed build and export diagnostics before connecting.
2. Scan and connect in PM3 mode. Confirm service `6e400001...`, then record the
   UUID and properties selected for write-without-response and notify.
3. Run `hw version`, `hw status`, and `hw tune`; confirm incremental terminal
   output rather than a single result at completion.
4. Cancel a long read, disconnect during a command, and reconnect. Each command
   must finish or time out without terminating the app.
5. Connect with the device booted in Chameleon mode. Confirm the app detects it
   from the `VERSION?` response rather than the advertised name.
6. Switch to PM3. Confirm `REBOOTPM3` is followed by a 500 ms delay, BLE stays
   connected, PM3 Core becomes ready, and `hw version` completes.
7. Tap "Read card properties", confirm it fills `hf 14a info` without sending,
   then send it with an expendable HF ISO14443-A card in the field.
8. Switch back to Chameleon. Confirm `hw reset` is followed by a 300 ms delay,
   the PM3 TCP/Core path stops, and BLE stays connected.
9. Repeat both directions three times and confirm mode controls remain usable
   without `PM3 transport is not ready` or an unexpected disconnect.
10. Run `hf mf hardnested -t` and confirm it creates `hardnested_stats.txt`
    under the app's `Library/Application Support/Tagentra/PM3` directory instead
    of reporting `Could not create/open file hardnested_stats.txt`.

## Card acceptance

For MIFARE Classic, MFU/NTAG, ISO15693, and LF in turn:

- identify and read the expendable card;
- save and reopen the dump from the local library;
- export it and verify the preserved original plus normalized metadata;
- make an automatic backup, validate type and capacity, show confirmation;
- write the expendable card and perform an independent read-back comparison.

Diagnostics must include state changes, service and characteristic discovery,
mode decisions, TCP state, PM3 output, cancellation, and disconnect reason. They
must not contain stable peripheral UUIDs or user-provided key material.

## Release gate

- Build device arm64 and Simulator arm64/x86_64 and run the ABI/resource smoke test.
- Verify the Release ZIP has exactly one top-level XCFramework directory.
- Verify every SHA-256 entry and resolve the generated SwiftPM manifest afresh.
- Run Flutter analysis/tests and an unsigned iOS build.
- Complete this hardware checklist before a development-signing or TestFlight build.
