# What the agent can reach

clod gives the agent a fixed reach instead of a stream of permission prompts.
Claude Code runs with `--dangerously-skip-permissions` and Codex with
`--dangerously-bypass-approvals-and-sandbox`, so within that reach they act
without asking:

- **The project directory**, read-write: the agent can change or delete any
  file in it, including any secrets the project keeps, such as a `.env` file.
- **Its home**, `~/.clod/homes/<name>` on your machine (or a Docker volume),
  not your own home directory. A new home starts empty: no SSH keys, git or
  GitHub credentials, or cloud logins. It holds only what you give it: the
  logins you make inside the container (`/login`, `! gh auth login`) and files
  you copy in. So the agent can push to git only
  if you've given that home credentials that allow it. Give each home only
  what its work needs.
- **The main repository's `.git`, when the project is a git worktree**: its
  objects and refs read-write, its config, hooks and submodules read-only (see
  [Git worktrees](usage.md#git-worktrees)).
- **The variables you pass in** from `.envrc`, tokens included.
- **The network**, including services on your machine through
  `host.docker.internal`.
- **Your clipboard's images**, with `--clipboard` (or `clipboard on`): whatever
  image you have copied, at any time during the run, not only when you paste.

Everything else on your machine is out of reach: your own home directory,
other projects, host processes and system files. In the container the agent
runs as an ordinary user, `claude`, so the image's system files are out of its
reach too, and anything it changes outside the home and project is discarded
on exit. `clod` refuses to use your home directory, `~/.clod` or the homes
directory as the project or as the container's home, unless run with
`--force`.

The one exception is `--docker`, which you pass by hand when the agent needs
to run containers. It gives the agent the Docker host, which is far more than
this list: see [Letting the agent run containers](docker-socket.md).

Claude Code installs on first run with
`curl -fsSL https://claude.ai/install.sh | bash`, and Codex from npm. The base
image's packages come from Debian, except Node, from NodeSource's apt
repository, and the GitHub CLI, from GitHub's.
