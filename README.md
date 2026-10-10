# TabDance

TabDance is a macOS terminal prototype built with AppKit and SwiftTerm. It has
multiple windows, workspaces, and live terminal tabs. The repository also
contains static inspection artifacts for an Apple Terminal executable.

## Build and run

Requires macOS 13 or later and Swift 6. Build and open the app from the
repository root:

```sh
cd prototype
./build-app.sh
open dist/TabDance.app
```

Run the test suite with `swift test` from `prototype/`. For workspace behavior,
keyboard shortcuts, persistence, and terminal details, see
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

Running it regenerates files under `analysis/`, including raw tool output, so
review the destination before running it.

## License

This repository is distributed under the [GNU General Public License, version
3](LICENSE). TabDance's bundled SwiftTerm license text is in
[`prototype/THIRD_PARTY_LICENSES.txt`](prototype/THIRD_PARTY_LICENSES.txt).
