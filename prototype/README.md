# TerminalLab prototype

A minimal original macOS terminal app built with AppKit and [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.19.0. It starts the account's login shell in the home directory, renders ANSI and 256-color output through SwiftTerm, and supports normal terminal keyboard input, selection, copy/paste, resizing, and multiple windows.

## Build and run

Requires macOS 13 or later and Xcode with Swift 6. Run:

```sh
cd prototype
./build-app.sh
open dist/TerminalLab.app
```

The build creates an ad-hoc signed app at `dist/TerminalLab.app`. Swift Package Manager fetches the pinned SwiftTerm dependency. Run `swift test` for the PTY integration test.

For a deterministic test session that skips login profiles, launch the executable with `--execute`, for example:

```sh
dist/TerminalLab.app/Contents/MacOS/TerminalLab --execute /bin/sh -c 'printf "TerminalLab ready\n"; sleep 10'
```

## Scope

This is a prototype, not a clone of Apple Terminal. It has no tabs, profiles, search, restoration, or preferences. The shell runs without the macOS App Sandbox because a general-purpose local terminal needs normal filesystem and process access. Closing a live window or quitting with active sessions asks for confirmation. Third-party license text ships inside the app bundle. SwiftTerm is pinned to 1.19.0 (`464df5207fc2432e16c9a23abe538187196daf5f`).
