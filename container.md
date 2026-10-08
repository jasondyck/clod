# Environment

Running in a disposable Docker container (`docker run --rm`) started by the user's `clod` launcher (https://github.com/DavidBoone/clod), a bash script on their macOS (Colima or Docker Desktop) or Linux host. Image is `clod`, a variant built `FROM clod`, or, when `$CLOD_IMAGE` starts with `devcontainer`, the project's devcontainer (built by the devcontainer CLI, with clod's layer on top; its `postCreateCommand` and other lifecycle commands, mounts and forwarded ports aren't used, so run any setup they'd do yourself).

- `/home/claude` ← host `~/.clod/homes/<name>` (or another path chosen by `CLOD_HOME`), or, when `$CLOD_HOME` is `vol:<name>`, the Docker volume `clod-home-<name>` on Docker's own disk
- `/workspace` ← the host directory `$CLOD_WORKSPACE` (the one `clod` was run from, or `clod -w PATH`): the user's real project, not a scratch dir. When `$CLOD_WORKSPACE` is `vol:<name>`, it's the Docker volume `clod-workspace-<name>`, kept between runs but not in a host folder. When `$CLOD_SCRATCH` is set, it's an empty volume (`clod --scratch`), discarded with the container, so anything worth keeping goes in the home or to a remote
- When `/workspace` is a git worktree, the main repository's `.git` is mounted at its host path so git works: commit, branch and push as usual, but its `config`, `hooks` and `modules` are read-only, so `git config` (without `--global`) and hook installs fail; set config with `git -c` or `--global` instead
- `/etc/claude-code` ← `~/.clod/shared`, or clod's own `shared/` until that exists (read-only here): the statusline and the `settings.json` passed as `--settings`, any managed settings, and the user's own instructions in its `CLAUDE.md`, if any
- `/etc/clod/.claude/rules/` holds this file and any instructions the image's variants add
- `$CLOD_HOME`, `$CLOD_WORKSPACE` and `$CLOD_IMAGE` name this run's home, workspace and image as `clod -H`, `-w` and `-i` take them. `$CLOD_HOME_PATH` and `$CLOD_WORKSPACE_PATH` are the host folders mounted at `/home/claude` and `/workspace`, unset for a volume (`vol:<name>`) or scratch workspace. A `~` in a path there is the user's home on the host
- Files for the user to open: put them under `/workspace` or `/home/claude` and give the host path, `$CLOD_WORKSPACE_PATH` in place of `/workspace` and `$CLOD_HOME_PATH` in place of `/home/claude` (e.g. `~/proj/out/shot.png`), which their terminal can open with a click. `/tmp` and other container paths don't exist on the host, so never point the user at them; copy the file somewhere mounted first. A volume or scratch mount has no host folder, so say that instead
- `$CLOD_PORTS`, when set, lists the container ports published to the user's machine, comma-separated (`5000,8080`); a server must listen on `0.0.0.0` to be reachable through them. When another container already had one of their host ports, clod left that port out or published it on another host port, and said which on the host
- `$TERM` is `xterm`. When clod runs in a terminal, `$TERM_PROGRAM`, `$TERM_PROGRAM_VERSION`, `$LC_TERMINAL`, `$LC_TERMINAL_VERSION` and `$COLORTERM` are the host terminal's, where it sets them
- `$CLOD_CLIPBOARD_URL`, set with `clod --clipboard`, is where `xclip` and `wl-paste` here (shims, image only) fetch the image on the user's clipboard, which is how Claude Code's Ctrl+V pastes one. Without it, Ctrl+V can't paste images; the user turns it on with `clod --clipboard` or `clod default clipboard on`
- The `show_image` tool (the `show-image` plugin in `/etc/clod/plugins/`) draws a picture file inline in the user's terminal, where it is kitty or Ghostty; elsewhere they see its path. The user can also type `/show-image PATH`
- The host is `host.docker.internal`. The Docker socket is mounted only with `clod --docker` (then `$CLOD_HOST_WORKSPACE` is the project's host path, unset for a volume or scratch workspace)

When the home and workspace are virtiofs mounts (`mount` shows it; usual on a macOS host), GNU `sed -i` leaves the file mode 600 (it restores the mode through an ACL, which the mount stores but doesn't apply); edit files with your own tools or `perl -i` instead.

Only `/home/claude` and (unless scratch) `/workspace` persist. System packages (apt, `/usr/local`) belong in an image variant's Dockerfile, which the user maintains. `npm install -g` goes to `~/.local` and persists, Python packages go in a venv, and single-file tools can go in `~/.local/bin`.

# Changing the container

You can't run `clod` or see the host's `~/.clod`; the user changes these on the host, and they take effect on the next `clod` run. When something about the container is in the way, say which of these to change, with the exact lines:

- Packages or system setup: a variant, `~/.clod/images/<name>/Dockerfile` (`ARG BASE=clod` / `FROM $BASE`, `USER root` … `USER claude`), run with `clod -i <name>`; `clod image new <name>` starts one and `clod image edit <name>` opens its Dockerfile. Variants combine (`-i go+<name>`), and clod rebuilds them when their files change. For root while running, the bundled `sudo` variant
- Environment variables for the container: `.envrc` in the project (`export FOO=bar`), loaded by direnv on the host, where it must be allowed
- Defaults for every run: `clod default image|command|home|ports|ports-busy|clipboard|devcontainer VALUE`; for one project, `CLOD_IMAGE`, `CLOD_PORTS` and so on in its `.envrc`
- A project with a `.devcontainer`: `clod -i devcontainer` runs in it (`clod -i devcontainer:PATH/` for one in another folder, such as below the workspace) (the devcontainer CLI on the host builds it), and `clod default devcontainer auto` does so wherever there is one; the devcontainer config, in the project, is what to change for its packages
- Instructions or managed settings for every home: `~/.clod/shared/` (`clod shared new` creates it)
- A home on the shared folders that's slow, or that `chown` fails in: a volume home, which `clod home mv NAME vol:NAME` moves it to, login included (`clod home cp` copies)
- Ports: `clod -P 3000` or `CLOD_PORTS`; Docker access: `clod -i docker --docker`, which gives the agent root on the Docker host

On the host, `clod env` shows the settings a run would use; `clod image`, `clod home` and `clod workspace` list the images, homes and volume workspaces, and `clod help` lists the rest (`clod help COMMAND` for one). The full docs are in the repo's `docs/`: `usage.md`, `images.md`, `configuration.md`, `shared-config.md`, `docker-socket.md`, `security.md`, `docker.md`. Read them (`https://raw.githubusercontent.com/DavidBoone/clod/master/docs/<page>`) before advising on clod beyond this summary.
