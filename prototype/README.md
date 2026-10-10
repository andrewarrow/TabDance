# TabDance

TabDance is a macOS terminal prototype built with AppKit and [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.19.0. It supports multiple windows, workspaces, and live terminal tabs. Each tab runs a login shell with terminal input, ANSI and 256-color output, selection, copy and paste, and resizing.

## Build and run

Requires macOS 13 or later and Swift 6. Run:

```sh
cd prototype
./build-app.sh
open dist/TabDance.app
```

The build creates an ad-hoc signed app. Swift Package Manager fetches the pinned SwiftTerm dependency; no other package dependencies are used. The package product and executable remain named `TerminalLab`.

Run `swift test` for the PTY, workspace, Codex activity, terminal behavior, and AppKit window tests. Window layout tests exercise 390×844, 768×1024, 1280×800, and 1440×900 sizes.

For a deterministic test session that skips login profiles and workspace persistence, launch the executable with `--execute`, for example:

```sh
dist/TabDance.app/Contents/MacOS/TerminalLab --execute /bin/sh -c 'printf "TabDance ready\n"; sleep 10'
```

## Workspaces and tabs

The workspace rail shows each workspace's tab count. Every workspace keeps its own live tabs and selected tab; switching workspaces preserves each one's selection. Drag workspace rows to reorder them. Tabs can be reordered with `⌘⌃⇧←` and `⌘⌃⇧→`; tab dragging is not available. The tab bar scrolls horizontally when its tabs do not fit.

Tab and workspace labels use OSC 7 updates with periodic `libproc` polling as a fallback. Immediately before creating a tab or workspace, TabDance reads the selected shell's process working directory, so a quick `cd` followed by `⌘T` or `⌘⇧N` starts the new shell there. Directory labels follow Rio's naming style.

Below 600 points of window width, the workspace rail collapses and the workspace menu button remains available. `⌘B` toggles the wider sidebar.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘T` | New tab |
| `⌘⇧N` | New workspace |
| `⌘N` | New window |
| `⌘W` | Close tab |
| `⌘⇧W` | Close window |
| `⌃Tab` / `⌃⇧Tab` | Select next / previous tab |
| `⌘1`–`⌘8` | Select tab 1–8 in the active workspace |
| `⌘9` | Select the last tab in the active workspace |
| `⌥⌘↑` / `⌥⌘↓` | Select previous / next workspace |
| `⌘B` | Toggle the sidebar |
| `⌘K` | Clear output above the current logical command line |

## State and terminal behavior

The primary window saves its layout, tab directories and titles, and selections
to `~/Library/Application Support/TabDance/workspaces.json`. Restoring that
layout starts new shells; it does not restore running processes, shell history,
or commands. Secondary windows do not overwrite the primary window's saved
layout. Launching with `--execute` skips persistence.

`⌘K` clears prior output and scrollback while keeping the current logical
command line at the cursor, including wrapped lines. It does not send `Ctrl-L`.
A selection snapshot survives terminal redraw; explicit input or a mouse clear
discards it.

The Codex activity indicator follows Codex task events found under each shell's
process tree and session transcript. An idle Codex process does not show as
busy. `Ctrl-C` cancels the indicator, and bracketed paste contents do not count
as submitted prompts.

## Scope

TabDance is a prototype, not a clone of Apple Terminal. It has no profiles,
search, or preferences. Shells run without the macOS App Sandbox because a
general-purpose local terminal needs normal filesystem and process access.
Closing a live window or quitting with active sessions asks for confirmation.
Third-party license text ships inside the app bundle. SwiftTerm is pinned to
1.19.0 (`464df5207fc2432e16c9a23abe538187196daf5f`). Exact copied-newline
behavior and latency parity with Apple Terminal have not been measured.
