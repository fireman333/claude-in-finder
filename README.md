# Claude in Finder

Every Claude Code conversation, as a file you can double-click in Finder.

```
~/Claude Sessions/
├── Claude-in-finder/
│   ├── + New Session.claudesession
│   ├── macOS Claude 對話檔案應用.claudesession
│   └── .ccf-project
└── HFpEF-AF/
    ├── + New Session.claudesession
    └── Cox model 的 PH assumption.claudesession
```

- **Double-click a session** → it reopens in Claude Code desktop.
- **Space bar** → Quick Look shows the actual conversation.
- **Rename a session in Claude** → the file renames itself, keeping its Finder tags.
- **`+ New Session`** → starts a fresh session in that project, skipping the New screen.
- **Right-click any folder** → Services → *New Claude Session Here*.

Requires macOS 13+, Claude Desktop, and the Command Line Tools. **No Xcode needed.**

## Install

```bash
git clone https://github.com/fireman333/claude-in-finder.git
cd claude-in-finder
./Scripts/install.sh
```

Everything lands under your home directory — `~/Applications`, `~/.local/bin`,
`~/Library/LaunchAgents`. No sudo, nothing touched system-wide.

```bash
./Scripts/uninstall.sh   # removes all of it; leaves ~/Claude Sessions alone
```

## Usage

```bash
ccfinder sync         # reconcile the mirror once
ccfinder watch        # stay running and sync on change (this is what the agent does)
ccfinder new .        # start a session in a folder
ccfinder doctor       # report what it can and cannot see
```

Set `CCF_MIRROR` to put the mirror somewhere other than `~/Claude Sessions`.

## How it works

Two things make this small enough to be worth building.

**Claude already has the deep links.** Verified against Claude.app 1.34493.1 by
reading its URL router:

| Link | Effect |
|---|---|
| `claude://resume?session=<uuid>` | reopens an existing CLI session |
| `claude://code/new?folder=<path>` | starts a new session in a folder |

The `<uuid>` is validated against a strict UUID pattern before the app will act
on it, so `ccfinder` checks the same pattern before handing anything over.

**Claude Desktop already keeps an index.** Every session has a small JSON file at
`~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_<uuid>.json`
holding its title, working directory, archive flag and `cliSessionId`. Watching
that one directory with FSEvents covers creation, retitling and archiving —
there is no need to parse the much larger `~/.claude/projects/**/*.jsonl`
transcripts except to render the preview.

**Quick Look comes free.** The `.claudesession` file *is* an HTML document, and
its UTI (`com.klaude.claude-session`) declares conformance to `public.html`.
macOS previews it with the built-in `Web.qlgenerator`, while `LSHandlerRank =
Owner` keeps double-clicks routed to this app. That is what removes the need for
a Quick Look extension, an Xcode project, and a developer certificate.

**Renames are moves.** State lives in `~/Library/Application
Support/ClaudeInFinder/index.json`, so a retitled session becomes a
`moveItem` rather than a delete-and-recreate. The file keeps its inode, and with
it your Finder tags, comments and aliases. `Tests/rename-test.sh` asserts exactly
that.

## Limitations

- Sessions that never produced a CLI transcript have no `cliSessionId` and cannot
  be reopened by deep link. `ccfinder doctor` counts them; here it is ~2%.
- `claude://code/new` opens the composer. The session record only appears once you
  send the first message, so the mirrored file shows up then, not on click.
- Archived sessions are skipped. Pass `--archived` to include them.
- The mirror is generated. `ccfinder` only ever deletes files it created and still
  tracks in its index, but do not keep anything of your own in there.
- Ad-hoc signed. Fine locally; it is not notarised for distribution.

## Tests

```bash
./Tests/rename-test.sh   # rename preserves the inode and extended attributes
./Tests/watch-test.sh    # FSEvents picks up creation and retitling live
```

Both run against a synthetic session directory via `CCF_SESSIONS`, so they never
touch your real Claude data.

## Prior art

Session *browsers* are a crowded field — [agentsview](https://github.com/kenn-io/agentsview),
[claude-code-history-viewer](https://github.com/jhlee0409/claude-code-history-viewer),
[claude-history](https://github.com/raine/claude-history), and Raycast's TokenTrack
extension, which uses the same `claude://resume` link. This project deliberately
does none of that: no browser, no analytics, no window of its own. Finder is the UI.

## License

MIT
