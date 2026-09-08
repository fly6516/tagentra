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
5. Connect in Chameleon mode and run the reviewed `REBOOTPM3` path.
6. Capture the official PM3-to-Chameleon command and response. Add it only with
   the redacted diagnostic fixture and a parser test.

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
