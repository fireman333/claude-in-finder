# Claude in Finder

Every Claude Code conversation, as a file you can double-click in Finder.

Sessions live next to the work they belong to:

```
~/code/my-project/
├── src/
├── package.json
└── Claude Sessions/
    ├── + New Session.claudesession
    ├── Fix the auth redirect loop.claudesession
    └── Rewrite the CSV importer.claudesession
```

- **Double-click a session** → it reopens in Claude Code desktop.
- **Space bar** → Quick Look shows the actual conversation.
- **Rename a session in Claude** → the file renames itself, keeping its Finder tags.
- **`+ New Session`** → starts a fresh session in that project, skipping the New screen.
- **Rename a session file** → the session is renamed in Claude. If Claude currently
  has that conversation open it may write its own title back; the file keeps the
  name you typed and the rename is re-applied until it takes.
- **Delete the `+ New Session` file** → it stays deleted, in that folder only.
- **Delete a session file** → the session is archived. Delete it again from
  `Archive/` → the session is deleted for real.
- **Right-click a folder — or the empty space in a window** → *New Claude Session
  Here*, *Open Claude Archive Folder*.
- **Right-click a session** → *Archive Claude Session*, *Delete Claude Session*.

Those live in the contextual menu itself, not in the Services submenu.
- **Drag a session into `Archive/`** → it is archived in Claude too. Drag it back
  out to unarchive.

In a git repository the folder is added to `.git/info/exclude`, so it never shows
up in `git status` and never lands in a commit. Sessions whose working directory
no longer exists fall back to `~/Claude Sessions/_Unavailable/`.

Requires macOS 13+, Claude Desktop, and the Command Line Tools. **No Xcode needed.**

## Install

Download the `.dmg` from [Releases](https://github.com/fireman333/claude-in-finder/releases),
open it, and run this one line in Terminal:

```bash
bash "/Volumes/Claude in Finder/install.sh"
```

The app is ad-hoc signed and not notarised, so macOS blocks it if you open it the
usual way. Running the installer through `bash` gets around that, and the
installer clears the quarantine flag on its own copy.

Or build it yourself:

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

## Settings

Three ways in, whichever is nearest:

- the **menu bar icon** → Settings…
- right-click any folder → Services → **Claude in Finder Settings…**
- open the app from Spotlight

| Setting | Choices |
|---|---|
| Where session files are kept | in each working folder · all together under `~/Claude Sessions` |
| Show the Archive folder | visible · hidden (the files stay; open it from the right-click menu) |
| Deleting a session file | archives the session · deletes it (from `Archive/` it always deletes) |
| A `+ New Session` file in each folder | on · off (deleting one only affects its folder) |
| Tell me when a new release is out | on · off (checks GitHub once a day) |

Or from the command line:

```bash
ccfinder config                        # show current settings
ccfinder config layout workdir|central
ccfinder config archive show|hide
ccfinder config on-delete archive|delete
ccfinder config updates on|off
```

Changing a setting rearranges the existing files immediately — by moving them, so
Finder tags survive — and the background agent picks the change up without a
restart. Settings live in `~/Library/Application Support/ClaudeInFinder/config.json`.

Hiding the Archive folder sets its hidden flag rather than dropping the files, so
the archived sessions are still there and **Open Claude Archive Folder** can reach
them.

Deleting works in two stages, like the Trash itself: removing a session from its
folder archives it, and removing it from `Archive/` — where it has already been
put aside once — deletes it. That second step is deliberate enough to take at face
value, whatever the setting says.

A session file that is gone from its folder counts as deleted, whether or not it
left a copy in the Trash — Finder does not always leave one, and the sync agent
may replace the file before it ever sees one. The check happens at the moment the
file would be recreated, so a deletion that lands mid-sync is not missed.

Two guards keep that from going wrong:

- The folder must have answered this pass. A folder macOS will not let the agent
  read also looks empty, and reading that as "every session in it was deleted"
  would be a disaster.
- **Deleting the session outright needs the file to actually be in the Trash.**
  Something that merely went missing might have been dragged somewhere the tool
  does not look, so an unconfirmed disappearance is downgraded to archiving — a
  nuisance you undo by dragging it back, rather than something you cannot.

### Update reminders

With **Tell me when a new release is out** on, the background agent asks GitHub
once a day whether this project has a newer release. If it does, the menu bar
icon grows a dot, the menu gains an **Update to 0.11.0…** item, and the Settings
window says so — with a **Release Notes…** button that opens the release page.

**Nothing is downloaded and nothing is installed.** Updating is still `install.sh`,
which is deliberate: the app is ad-hoc signed, so every update re-grants folder
access and the Finder extension by hand, and that is not something to start
behind your back. A check that cannot reach GitHub says so rather than reporting
"up to date", and tries again in an hour instead of a day.

```bash
ccfinder update            # check now and print the answer
ccfinder update --if-due   # what the agent runs: obeys the setting and the daily window
```

The answer is cached in `~/Library/Application Support/ClaudeInFinder/update.json`,
so opening the menu never waits on the network. Turning the setting off stops the
scheduled check entirely; `ccfinder update` still answers when asked directly.

The Settings window has a **Permissions** section showing whether folder access
and the Finder menu are actually on, with buttons that jump straight to the right
System Settings pane. Both lapse on every update, so it is worth a glance after
installing.

## Access to protected folders

macOS protects Desktop, Documents and Downloads. The installer asks for them, so
answering its prompts is usually all there is to it.

**You will be asked again after every update.** The app is ad-hoc signed, which
means its identity *is* its code hash, so a new build is a different app as far as
macOS is concerned and the old grant no longer applies. A Developer ID certificate
would fix that; a hobby project does not warrant one.

Without it nothing breaks: the agent notices a folder is not answering, skips that
whole tree, logs it, and keeps going — and refuses to read anything into a folder
it cannot see, so a blocked folder is never mistaken for one whose sessions were
all deleted. `ccfinder doctor` lists what it could not read. Running `ccfinder
sync` from your own terminal works regardless, because your terminal has its own
access.

## Usage

```bash
ccfinder sync                 # reconcile once
ccfinder watch                # stay running and sync on change (what the agent does)
ccfinder new .                # start a session in a folder
ccfinder archive <file>       # archive a session (reversible)
ccfinder unarchive <file>     # bring it back
ccfinder delete <file> --yes  # delete the session record
ccfinder update               # check GitHub for a newer release
ccfinder doctor               # report what it can and cannot see
```

Useful flags for `sync` and `watch`:

| Flag | Effect |
|---|---|
| `--no-archived` | leave archived sessions out for this run |
| `--central` | keep everything under `~/Claude Sessions` for this run |
| `--no-git-exclude` | leave `.git/info/exclude` alone |
| `--no-prune` | never delete a mirrored file |

`CCF_MIRROR` moves the fallback root away from `~/Claude Sessions`.

## Archiving and deleting

Several sessions can be selected at once; you are asked to confirm the batch once,
and the files move immediately rather than after the next sync.

Both act on Claude's own session records, following the conventions read out of
the app: archiving flips `isArchived`, deleting writes the `deleted_<uuid>`
tombstone Claude itself uses and removes the record.

Deleting is narrower than it sounds, on purpose:

- the transcript under `~/.claude/projects` is **not** touched — the conversation
  is still on disk
- the removed record is copied to `~/Library/Application Support/ClaudeInFinder/deleted/`
- the mirrored file goes to the Trash, not to `/dev/null`

Claude Desktop caches sessions in memory, so a session archived or deleted from
Finder while Claude is running may linger in its sidebar until you restart it.

Dragging a file into or out of `Archive/` does the same thing. A tracked file
found somewhere other than where the index left it can only have been moved by
hand; when that move crossed the Archive boundary it is taken as intent. Moves
that did not cross it are undone by the next sync.

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

**The menu is a Finder Sync extension.** Services can only ever appear inside the
Services submenu, and never at all when you right-click empty space. A Finder Sync
extension does both. It has one non-obvious requirement: it must carry the
`app-sandbox` entitlement or `pluginkit` ignores the bundle outright, with nothing
logged anywhere to say why. Installing therefore must not re-sign the app with
`--deep`, which would strip that entitlement back off.

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

**Asking for a new session always walks up to the working directory.** The mirror
folder sits *inside* the project, so a new session started from within
`Claude Sessions/` has to resolve back to the parent — otherwise you would get a
session rooted at `<project>/Claude Sessions` and a nested mirror folder inside
it. A `.ccf-project` marker records the real directory, and every entry point —
double-clicking `+ New Session`, the Finder service, `ccfinder new` — goes
through the same resolver.

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
./Tests/run-all.sh       # everything

./Tests/rename-test.sh         # where files land, renames as moves, git hygiene,
                              # missing folders, archiving, index recovery,
                              # new-session resolution from every entry point
./Tests/watch-test.sh         # FSEvents picks up creation and retitling live
./Tests/archive-delete-test.sh # archive/delete against Claude's record format,
                              # and dragging in and out of Archive/
./Tests/config-test.sh        # both settings, including flag overrides
./Tests/multi-select-test.sh  # batch archive / unarchive / delete
./Tests/update-test.sh        # version comparison, the daily window, the setting,
                              # and that a failed check does not claim success
```

They run against a synthetic session directory via `CCF_SESSIONS`, so they never
touch your real Claude data; the update test reads a fixture through
`CCF_UPDATE_API` rather than the network.

## Prior art

Session *browsers* are a crowded field — [agentsview](https://github.com/kenn-io/agentsview),
[claude-code-history-viewer](https://github.com/jhlee0409/claude-code-history-viewer),
[claude-history](https://github.com/raine/claude-history), and Raycast's TokenTrack
extension, which uses the same `claude://resume` link. This project deliberately
does none of that: no browser, no analytics, no window of its own. Finder is the UI.

## License

MIT
