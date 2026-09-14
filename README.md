# kiln

a native macOS client for codex and opencode.

i wanted the CLI workflow without having to live in a terminal for every part of it. kiln keeps the conversations, files, tools, and model controls together. there's a web client too, so i can check a run or send something from another device.

the CLI still does the work. kiln handles the interface around it.

## using it

pick a folder, pick a model, start a conversation.

each chat keeps its own model, reasoning level, permissions, and fast-mode choice. the folder in the header is the folder the agent starts in. switching chats shouldn't change what another one is doing.

codex models come from the CLI kiln is actually running, including the reasoning levels and fast mode it advertises. older models live in their own group. opencode keeps its provider/model IDs. being in the list doesn't mean your account has access to a model.

you sign in to the model provider through its CLI. this is separate from a kiln account:

```sh
codex login
opencode auth login
```

settings has an update checker for both CLIs. it checks the installed version and the package manager's release, then gives you the appropriate update command. it doesn't install anything behind your back.

## the chat

paste screenshots, drop files, or attach them from the composer. images go to the backend as image inputs, not just a path mentioned in the prompt.

replies keep the model that produced them. reasoning summaries and tool output are expandable, and the run log is there when something goes wrong. reasoning is whatever the backend exposes, not a separate hidden-thoughts feed.

image, video, audio, and PDF links in replies can render inline. video and audio wait for you to press play. supported formats depend on macOS or your browser; a file that can't preview still has an open link. ordinary web pages aren't turned into arbitrary embedded sites.

YouTube, Vimeo, Spotify, SoundCloud, and TikTok links get titles, authors, thumbnails, and click-to-load players. X posts use fixupx.com: kiln gets the post through FixupX's API and shows the text, photos, videos, and quoted post itself. no X widget. twitter.com, x.com, fxtwitter.com, and fixupx.com post links all take the same path.

previews contact the relevant provider, or FixupX for X posts. private, deleted, region-locked, or embed-disabled content can still fail; the original link stays available. regular websites stay as links rather than being fetched by the host as arbitrary pages.

there's conversation search, forks, pinned messages, export, and an editor for longer prompts. drafts are saved per chat. undo-send gives you a chance to pull a request back, and interrupted queued requests come back as drafts rather than sending themselves after a restart.

auto-compact is on by default at 90% of the backend's current context, not the total tokens processed across a run. codex reports the latest request size and its effective context limit; kiln uses those same numbers for the meter and trigger. it checks before the next send, saves an archive, and compacts the existing codex thread without replacing the visible conversation or restarting it.

if the measurement isn't available, kiln says so and doesn't guess. opencode's current CLI transport only supplies usage totals here, so kiln's automatic trigger stays inactive for it; manual compaction is still available. this toggle controls kiln's trigger, not the backend's own context management. turn it off in chat & composer settings. saved archives can be restored as a separate chat.

## the workspace

the native client has a file browser, editor, git panel, terminal, and activity view alongside the conversation. you can resize, collapse, and rearrange the panels.

permissions matter. bypass skips the normal prompts; guarded and read-only use the backend's restrictions. operations that need interactive CLI approval may be blocked in guarded mode. don't use bypass on a repository you haven't looked at.

opencode runs with external plugins disabled and automatic sharing off. kiln doesn't rewrite your global backend configuration to make a session work.

## memory and decisions

memory now has a native home in kiln. settings > local memory connects to your installed engram and mythic runtimes over local JSONL pipes. no browser dashboard or MCP hop is required between them. the executable, config, working directory, and mythic store are visible settings; connecting doesn't install or replace either service.

project context only includes explicitly scoped active memories and checkpoints. whole-store search is a separate action and uses normal engram retrieval, including its access accounting. adding a result to a draft is explicit. nothing gets pasted into every turn automatically.

dormant review starts with evaluation metadata. opening a candidate and recording used, irrelevant, or dismissed feedback are separate actions. silence isn't feedback, and old memories aren't automatically true. forgotten or inactive candidates stay unavailable.

mythic keeps assumptions, observations, and revised decisions across restarts. checks are registered read-only operations: a file exists inside the project, engram responds, or an engram operation is advertised. the checked claim and evidence are distinct from whatever someone wrote in the assumption. storing an observation in engram doesn't turn it into engram-verified truth.

choose a decision with "use for next request" to check its dependencies before sending. missing, unknown, or expired evidence holds that request. ordinary chat stays usable, including asking how to fix the problem. these checks don't grant tool permissions or execute the proposed action themselves.

## accounts and usage

kiln accounts live at [kiln.raya.ac](https://kiln.raya.ac). account settings handles registration, sign-in, sign-out, password changes, and recovery. keep the recovery code shown at registration: there is no email recovery service. provider login still belongs to codex or opencode, not this server.

the hosted account service uses PostgreSQL for accounts, sessions, profiles, consent, usage, and rate limits. the private outbox on your mac is local state, not a substitute server database.

public profiles contain the handle, display name, and bio. token history is private. usage sharing is off until explicitly enabled on this device and account. it sends measured token counts, provider/model identifiers, an opaque session ID, and timestamps, not messages, memories, folder paths, attachments, or provider credentials.

the account is captured when a turn starts. signing out, changing accounts, or revoking sharing invalidates that turn's reporting permission. accepted events have stable identities; reconnects retry the same snapshot instead of adding the tokens twice. counts that the provider didn't report stay unknown. cached and reasoning counts are kept separate, and this is usage reporting, not billing or a guessed dollar total.

the backend and its operating instructions are in [account-service](account-service/). deployment status belongs in its deployment receipt, not in a build-success claim. local chat works without a kiln account.

## from another device

open the authenticated remote link from settings. keep that link private: its token grants access to kiln. use a trusted network or an authenticated HTTPS tunnel, not a bare port exposed to the internet.

the web client matches the native chat layout and core controls: models, reasoning, permissions, fast mode, media, search, and draft recovery. the phone layout puts sessions and activity in drawers. the auto-compact toggle changes the same setting on the host.

it isn't the entire desktop app in a browser. file editing, git, the terminal, local cognitive services, account credentials, and full archive management are still native-only. remote uploads currently have a 4 MB browser limit.

local media is only served when the conversation references it and it resolves inside that conversation's workspace or kiln's attachment folder. video supports range requests for seeking. unsupported files remain downloads.

the web assets ship with the app, including icons, Markdown parsing, and sanitization. the interface doesn't load CDN scripts. optional embedded players load the provider's page in an isolated frame, without access to the chat or its token. refresh the web page after updating kiln.

the tool timeline borrows closely from [T3 Code](https://github.com/pingdotgg/t3code): grouped adjacent work, expandable output, a visible active call, and a distinction between following a run and reading earlier output. [the parity notes](docs/t3-parity.md) record the pinned source and remaining differences. [MIT attribution](THIRD_PARTY_NOTICES.md) ships with the app.

## building it

you need macOS 14 or newer and a Swift 6 toolchain. codex or opencode needs to be installed separately.

```sh
git clone https://github.com/raya-ac/kiln.git
cd kiln
make bundle ARCH=arm64
open dist/arm64/Kiln.app
```

use `ARCH=x86_64` for an Intel build. `VERSION` is the version source; `make bundle VERSION=...` overrides it for a one-off package.

the bundle script includes Sparkle and the Swift package resources. local builds are ad-hoc signed unless you provide a signing identity. that isn't the same as a notarized release.

packaged builds live under [releases](https://github.com/raya-ac/kiln/releases). changes are in [the changelog](CHANGELOG.md).

## where things live

conversations and settings are in `~/.kiln/`. drafts are in `drafts.json`, pasted and uploaded files in `attachments/`, and pre-compaction backups in `compaction-archives/`. the CLIs keep their own credentials and backend session data.

agent traces are in `~/Library/Logs/Kiln/`. settings has shortcuts to those logs and the latest crash report. check exports and logs before sharing them; they can contain prompts, paths, and tool output.

## working on kiln

```sh
swift test
make run
make lint
```

the browser checks run against a local fixture server, not your real chats:

```sh
node scripts/test-remote-ui.cjs
```

that check needs Playwright available to Node and an installed Chrome. `KILN_BROWSER_CHANNEL` selects a different installed Playwright browser channel.

the link-preview check uses public example posts and videos, not your conversations:

```sh
mkdir -p .tmp
KILN_LIVE_LINK_TESTS=1 KILN_LINK_FIXTURES="$PWD/.tmp/rich-link-fixtures.json" swift test --filter RichLinkTests
node scripts/test-rich-links.cjs
```

add `KILN_LIVE_EMBED_TESTS=1` to the link-preview browser check to load the real providers instead of local fixtures.

the code is mostly SwiftUI and AppKit. `Sources/Services/` owns the agent and remote connections, `Sources/Models/` has the data types, and `Sources/Views/` has the native interface. the web client is in `Sources/App/Resources/remote/`.

this is a tool i use, so fixes for actual annoyances are useful. include what happened, what you expected, and enough detail to reproduce it. don't put credentials in an issue.

[contributing](CONTRIBUTING.md) · [security reports](SECURITY.md) · [code of conduct](CODE_OF_CONDUCT.md) · [license](LICENSE)

kiln isn't an official OpenAI product. the backend names and logos belong to their respective owners.
