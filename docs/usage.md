# Using clod

## The command line

```bash
clod                 # Claude Code
clod claude --resume # Claude Code with its own arguments
clod codex [args]    # Codex
clod bash | zsh      # a shell in the container
clod -i go           # the go image variant (see Image variants)
clod -H work         # the "work" home (see Homes)
clod -w ~/src/app    # that directory as /workspace (see Another workspace)
clod -w vol:play     # a workspace kept in a Docker volume
clod -s              # an empty, throwaway /workspace (see A scratch workspace)
clod env             # show the home, workspace, image, ports, .envrc and variables that would be used
clod default         # show your defaults
clod image           # list the images (see Image variants)
clod home            # list the homes (see Homes)
clod workspace       # list the volume workspaces
clod help            # all commands and options
clod help home rm    # one command's page; so is clod home rm -h
```

Commands that manage something are a noun and a verb: `clod image build`,
`clod home rm`. The noun on its own lists them, except `shared`, which needs
`new` or `diff`.

clod's options go before the command or anywhere after it, up to `--`:
`clod home rm work --force` is `clod --force home rm work`. Past `--`, a word
starting with `-` is an argument.

`clod help` lists the commands and options. A command's page, with its usage,
what it does and the options that apply to it, is `clod help COMMAND`, or `-h`
or `--help` anywhere after the command: `clod home rm -h`. A noun's page lists
its verbs. The run commands (`claude`, `codex`, `bash`, `zsh`) are the
exception: their arguments go to the program they run, so clod's options go
before them, `clod claude --help` is Claude Code's help, and `clod help claude`
is clod's page for it. A usage error names the page to read.

A bare `clod` runs Claude Code, or whatever you've set as the default command.
To pass it arguments without naming it, put them after `--`: `clod -- --resume`
is `clod claude --resume`.

Claude Code runs with `--dangerously-skip-permissions` unless its arguments
include `--permission-mode`, `--dangerously-skip-permissions` or
`--allow-dangerously-skip-permissions`, so `clod claude --permission-mode plan`
brings the prompts back. `clod claude -p "..." | ...` works without a terminal.

`clod` refuses to mount your home directory or any directory above it,
`~/.clod`, or `~/.clod/homes` or anything under it as the workspace, since the
agent could then read your credentials and every home's login. `clod --force`
runs anyway.

See also [Image variants](images.md) and [Homes, settings and per-project
environment](configuration.md).

## Another workspace

`clod -w PATH` (`--workspace`) mounts that directory as `/workspace` instead of
the current one, from wherever you run it; the `.envrc` is looked up from it.
It must exist.

`clod -w vol:NAME` uses the Docker volume `clod-workspace-NAME` instead: it
lives on Docker's own disk, not in a folder on your machine, and is kept
between runs, for a repository cloned just for the agent, say. Docker creates it
on first use, owned by the container's user. No `.envrc` is read, and clod runs
from anywhere. To get files out, push them somewhere or copy them into the home.
In the container, `CLOD_WORKSPACE` is `vol:NAME` and `CLOD_WORKSPACE_PATH`,
otherwise the workspace's host folder, is unset (see [the container's
variables](configuration.md#your-defaults)).

```bash
clod workspace                  # list the volume workspaces, and which are in use
clod workspace rm play          # delete clod-workspace-play, after asking
clod workspace rm play --force  # delete it without asking
```

`clod workspace rm` takes `NAME` or `vol:NAME`. In a terminal it lists what
it will delete and asks first; without one, it needs `--force`. Docker won't
remove a volume a container uses.

`-w` is an option only, with no setting in the environment, an `.envrc` or your
defaults.

## A scratch workspace

`clod --scratch` (`-s`) runs with an empty `/workspace` instead of the current
directory: a Docker volume that's removed with the container, for a question,
an experiment or a repository cloned just to look at. Only the home persists,
so copy out anything worth keeping, or push it somewhere. No `.envrc` is read,
since the current directory isn't the project, and clod runs from anywhere,
your home directory included. With `--docker`, the agent's containers can't
bind-mount a scratch workspace, which has no path on the Docker host.

Claude Code keys its history and memory by the workspace path, which is
`/workspace` in every clod run, so a scratch session shares them with the
home's other sessions: `clod -s claude --resume` lists them all. `-s` doesn't
combine with `-w`.

## Install and tab completion

`clod install` links `clod` into the first of `~/.local/bin`, `~/bin`,
`/opt/homebrew/bin` and `/usr/local/bin` that's on your `PATH` and writable,
or else creates `~/.local/bin` and prints the line that adds it to your
`PATH`. `clod install DIR` links it into a directory of your choice.

It also sets up tab completion, asking zsh and bash, each started as a login
shell, where they load it from. For a zsh that runs `compinit`, it links
`_clod` into the first directory on zsh's `$fpath` you can write to; for a
bash that loads bash-completion 2, it links `clod` into
`~/.local/share/bash-completion/completions` (with `XDG_DATA_HOME` set, into
`bash-completion/completions` there, and with `BASH_COMPLETION_USER_DIR` set,
into `completions` in the first directory it lists). It takes effect in a new
terminal. When your login shell gets neither, `install`
prints the line to add to your `~/.zshrc` or `~/.bashrc` instead:

```bash
eval "$(clod completion)"
```

`install` won't replace a file it didn't make; `clod install --force` does.
Running it again only reports what's installed already.

`clod uninstall` removes the links `install` made, and nothing else: `clod` in
the directories on your `PATH` and the four above, `_clod` on zsh's `$fpath`
and `clod` in bash-completion's directory. A link `clod install DIR` made in a
directory off your `PATH` stays, as do clod's checkout, `~/.clod` (your homes
and their logins, variants, shared config and defaults) and the Docker images
and volumes clod made, which `clod image`, `clod home` and `clod workspace`
list and their `rm` commands delete. Take out an `eval "$(clod completion)"`
line yourself.

## Git and GitHub

A new home has no git identity or GitHub login, so the agent's first commit
fails until you set them up. Do it once per home, in a shell in the container;
both persist in the home:

```bash
clod bash
git config --global user.name "Your Name"
git config --global user.email you@example.com
gh auth login            # then: gh auth setup-git, so git pushes use it
```

Whatever you log into here, the agent can use: give each home only what its
work needs.

### Git worktrees

A [linked worktree](https://git-scm.com/docs/git-worktree)'s `.git` is a file
pointing into the main repository's `.git`, which is outside the workspace.
When the workspace is one, clod also mounts that `.git` at the same path, so
git works in the container. Its `config`, `hooks` and `modules` (submodules'
git directories) are read-only, as is each worktree's `config.worktree` when
`extensions.worktreeConfig` is on: those are what make git run programs, and
the agent could otherwise plant one that runs on your machine the next time you
use git there. The agent can still commit, branch and change refs in the whole
repository, not only its worktree's branch. A worktree made with relative
paths (`git worktree add --relative-paths`) isn't mounted; clod says so.

## Codex

Codex CLI installs from the official `@openai/codex` npm package into the home
the first time `codex` runs, and updates itself. Its login is per home.

```bash
clod codex login --device-auth  # first-time login
clod codex                      # start Codex
clod codex resume               # resume a session
```

Open the printed link in your browser and enter the code. Device code login
must be enabled in your ChatGPT security settings or by your workspace admin.
See [OpenAI's authentication documentation](https://learn.chatgpt.com/docs/auth).

Codex runs with `--dangerously-bypass-approvals-and-sandbox`, which turns off
its own sandbox and approval prompts inside the container, including for
resumed sessions.

## Publishing ports

To reach a server the agent starts, such as a dev server on port 5173, publish
its port when you launch. Ports are written host first, container second, as
in Docker: the port on your machine, then the one inside. They're published on
your machine's localhost, and the server must listen on all interfaces
(`0.0.0.0`) inside the container:

```bash
clod -P 5173                 # localhost:5173 -> port 5173 in the container
clod -P 3000:5173            # localhost:3000 -> port 5173 in the container
clod -P 5173 -P 8080         # several
clod -P ''                   # none, even if the .envrc or config sets some
```

Another running container may already publish a host port, such as a second
`clod` in the same project. A port given with `-P` then stops the run before it
starts. A port from `CLOD_PORTS` (the `.envrc`, your shell or your defaults) is
left out instead, with a warning, and the rest are published; the container's
`CLOD_PORTS` lists only those published. `CLOD_PORTS_BUSY` changes that:

```bash
clod default ports-busy next   # publish the next free host port (8091 for 8090) instead
clod default ports-busy error  # stop, as for -P
clod default ports-busy skip   # leave it out (the default)
```

Only the ports other running containers publish are checked.

## Pasting images

Claude Code pastes an image from the clipboard with Ctrl+V, but the container
has no clipboard: it can't see your machine's. With `--clipboard` it can, for
images:

```bash
clod --clipboard                 # this run
clod default clipboard on        # every run
```

Copy or screenshot an image to the clipboard, then press Ctrl+V in Claude
Code. clod starts a small server on your machine for the run, which reads the
clipboard each time the container asks and hands over only an image, as PNG;
in the container, `xclip` and `wl-paste` fetch it from there, which is what
Claude Code runs on Linux. Text still pastes through the terminal as usual.

It needs `python3` on your machine. On macOS it reads the clipboard with
`pngpaste` if you have it (`brew install pngpaste`), else with `osascript`; on
Linux with `wl-paste` (Wayland) or `xclip` (X11), and only on the machine Docker
runs on, since the container reaches the server on the Docker bridge's gateway.
`CLOD_CLIPBOARD_COMMAND`, set in your shell, replaces those with a command that
prints the clipboard's image as PNG.

While the run lasts, the agent can read whatever image is on your clipboard,
whenever it likes, not only when you press Ctrl+V; turn it on where that's fine.

## Showing images

In kitty or Ghostty, Claude Code shows pictures inline in the conversation,
through `show-image`, a Claude Code plugin the image brings and clod loads on
every Claude Code run:

- Claude shows you a picture file when it decides one helps, such as a chart it
  made or a screenshot it took, with its `show_image` tool. You see the
  picture; Claude doesn't.
- `/show-image PATH` shows one yourself.

PNG, JPEG, GIF (its first frame), WebP, TIFF and BMP all show; any but a PNG
of 2 MiB or less is converted to one first, with Pillow, at most 1200 pixels a
side. A picture takes at most 60 columns and 30 rows. In other terminals, its
path shows in its place.

The plugin is built on parts of Claude Code's plugin interface that it doesn't
document, so a Claude Code update can stop the pictures from showing.

## Updating and rebuilding

To update clod, `clod update` pulls its checkout in `~/.clod/src` and lists
what changed, one line per change. When the checkout is on another branch,
it asks first whether to switch to `master`; without a terminal it pulls the
branch it's on. The next `clod` rebuilds the image if it changed; `clod image
build` builds it straight away instead, without starting a container. Only a change to the base `Dockerfile` rebuilds the base:
`entrypoint.sh`, `container.md` (what Claude is told about the container) and
`clipboard.sh` (the `xclip` and `wl-paste` behind `--clipboard`) are mounted
from the checkout on every run, so changes to them apply without a build. An
update that changes the base image leaves every variant you've built stale;
`clod image prune` removes the stale images to free their space, and each
builds again on its next run.

An image is otherwise kept as built. To refresh its system packages, Node and
whatever its variant downloads, rebuild it from scratch. When an image's files
have changed but you'd rather not wait for the build, `--skip-build` runs it
as it is:

```bash
clod update                 # update clod
clod image build            # build the image now, if it changed
clod image build go rust    # build those images now, if they changed
clod image rebuild          # rebuild the image from scratch
clod --skip-build           # run the image as built
clod image prune            # remove the stale images
```

## What lives where

Everything clod keeps is under `~/.clod`:

```
~/.clod/
  src/                clod's own checkout
  config              your defaults for the launcher settings
  homes/<name>/       container homes (volume homes are Docker volumes, clod-home-<name>)
  images/<name>/      your image variants
  shared/             your shared config, mounted read-only as /etc/claude-code
```
