# TabDance

This repository contains two related projects: a static inspection of the macOS
Terminal executable, and **TerminalLab**, an original macOS terminal app
prototype built with AppKit and SwiftTerm.

## TerminalLab

TerminalLab starts your account's login shell in your home directory. It supports
terminal keyboard input, ANSI and 256-color output, selection, copy and paste,
resizing, and multiple windows. It targets macOS 13 or later and uses Swift 6.
This is a prototype without tabs, profiles, search, restoration, or preferences.

Build and open the app from the repository root:

```sh
cd prototype
./build-app.sh
open dist/TerminalLab.app
```

To run the PTY integration tests, use `swift test` from `prototype/`. For more
detail on the prototype's behavior and scope, see
[`prototype/README.md`](prototype/README.md).

## Apple Terminal analysis

[`analysis/`](analysis/) contains static extraction artifacts for an Apple
Terminal Mach-O executable, including Objective-C metadata, method indexes,
call data, and per-method disassembly. The extraction script is
[`analysis/extract.py`](analysis/extract.py). It uses Python 3 and macOS tools
such as `lipo`, `otool`, `nm`, and `dyld_info`.

Before running the script, update its hardcoded `SOURCE` path to a Mach-O
executable with an arm64e slice. It also reads the installed Terminal app at
`/System/Applications/Utilities/Terminal.app`. From the repository root, run:

```sh
python3 analysis/extract.py
```

Running it regenerates files under `analysis/`, including the raw tool output,
so review the destination before running it.

## License

This repository is distributed under the [GNU General Public License, version
3](LICENSE). TerminalLab's bundled SwiftTerm license text is in
[`prototype/THIRD_PARTY_LICENSES.txt`](prototype/THIRD_PARTY_LICENSES.txt).
