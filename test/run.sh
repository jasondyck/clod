#!/bin/bash
# clod's test suite: builds images through the launcher, as a Linux user would,
# and checks the containers it runs. CI runs it on fresh GitHub runners, a few
# tests per job.
#
# It needs Linux, and a Docker it can have to itself: it builds, replaces and
# prunes the clod images on the Docker it uses, and starts containers with that
# Docker's socket mounted. Run it on a CI runner or a throwaway VM, or through
# test/docker.sh (a Docker inside a container, on any Docker) or
# test/incus.sh (an incus container); --yes confirms that outside CI, and
# those two pass it. Each run gets a fresh HOME, so ~/.clod is left
# alone, and the Docker CLI keeps its config (and so its context).
#
#   test/run.sh [--yes] [TEST|GROUP...]   run them, or every test
#   test/run.sh --list                    list the groups and tests
#
# Tests run in the order listed. Each starts in an empty directory; the home is
# shared, so later tests see the images and variants earlier ones made, but
# each also runs alone.

# shellcheck disable=SC2016 # single-quoted scripts expand in the container

repo=$(cd "$(dirname "$0")/.." && pwd -P)

# Checks count characters, such as the statusline's meter cells, which needs a
# UTF-8 locale; GitHub's runners have one, a bare container (test/docker.sh)
# none.
export LC_ALL=C.UTF-8

lint_tests='lint'
base_tests='env run-command terminal mount-paths scratch workspace worktree refuses-home claude claude-args codex statusline
  port port-busy clipboard show-image docker-socket envrc volume-home home-copy home-new volume-workspace default shared command-line help
  multi-stage combine live-files rebuild image-edit image-diff image-rm image-clean image-prune devcontainer-names
  completion update install'
classic_tests='classic'
# The bundled variants: go and sudo are checked together as go+sudo, and docker
# by docker-socket.
variant_names='browser dotnet lamp python rust go+sudo'
# other-base builds the base on another image, as a devcontainer's, and
# devcontainer builds devcontainers with the devcontainer CLI.
variants_tests="$(for v in $variant_names; do printf 'variant-%s ' "$v"; done)other-base devcontainer"

# Prints the tests in group $1, or fails if there's no such group.
group_tests() {
  case $1 in
    lint) echo "$lint_tests" ;;
    base) echo "$base_tests" ;;
    classic) echo "$classic_tests" ;;
    variants) echo "$variants_tests" ;;
    *) return 1 ;;
  esac
}
all_tests="$lint_tests $base_tests $classic_tests $variants_tests"

usage() {
  sed -n '/^#   test/s/^# *//p' "$0"
}

list() {
  local g
  for g in lint base classic variants; do
    printf '%s:\n' "$g"
    # shellcheck disable=SC2046 # test names don't contain spaces or globs
    printf '  %s\n' $(group_tests "$g")
  done
}

# The tests. Each runs in a subshell with -e and pipefail, in an empty
# directory, with clod on PATH.

# Matches its input like grep -q, but reads all of it: grep -q exits at the
# first match, and a command still writing into the pipe then fails. The
# helpers return their failure, so a failed test names the line calling them.
has() {
  grep "$@" >/dev/null || return 1
}

# Runs a command, failing unless it exits with status $1.
exits() {
  local want=$1 got=0
  shift
  "$@" || got=$?
  [[ $got == "$want" ]] || return 1
}

test_lint() {
  cd "$repo"
  shellcheck clod completions/clod.bash entrypoint.sh clipboard.sh shared/statusline.sh docs/statusline-svg.sh \
    test/run.sh test/incus.sh test/docker.sh
}

test_env() {
  clod env
}

test_run_command() {
  echo hello > from-host
  clod bash -c '
    set -e
    test "$(id -u)" = "'"$(id -u)"'"
    test "$(cat /proc/1/comm)" = tini
    test "$USER" = claude && test "$TMPDIR" = /tmp && test "$EDITOR" = vim && test "$PAGER" = less
    test "$(cat /workspace/from-host)" = hello
    test -f /etc/claude-code/settings.json
    test -r /etc/clod/.claude/rules/clod.md
    test "$(find /usr/share/doc/git -type f)" = /usr/share/doc/git/copyright
    test ! -e /usr/share/man/man1/git.1.gz
    touch /workspace/from-container
    apt-cache policy gh | grep -A1 "^ *\*\*\*" | grep -q cli.github.com
    git --version; gh --version | head -1; node --version; python3 --version; jq --version; fd --version
  '
  test "$(stat -c %u from-container)" = "$(id -u)"
}

test_terminal() {
  export TERM=xterm-256color TERM_PROGRAM=iTerm.app TERM_PROGRAM_VERSION=3.7.3 \
    LC_TERMINAL=iTerm2 LC_TERMINAL_VERSION=3.7.3 COLORTERM=truecolor
  # in a terminal they go in, all but TERM
  cat > check <<'EOF'
set -e
test "$TERM" = xterm
test "$TERM_PROGRAM" = iTerm.app && test "$TERM_PROGRAM_VERSION" = 3.7.3
test "$LC_TERMINAL" = iTerm2 && test "$LC_TERMINAL_VERSION" = 3.7.3
test "$COLORTERM" = truecolor
EOF
  script -qec 'clod bash /workspace/check' /dev/null < /dev/null
  # without one they don't
  clod bash -c '
    test -z "${TERM_PROGRAM:-}${TERM_PROGRAM_VERSION:-}${LC_TERMINAL:-}${LC_TERMINAL_VERSION:-}${COLORTERM:-}"
  ' < /dev/null
}

test_mount_paths() {
  mkdir 'a,"b'
  echo hello > 'a,"b/from-host'
  clod home new './h,"1' >/dev/null
  clod -H './h,"1' -w 'a,"b' bash -c '
    set -e
    test "$(cat /workspace/from-host)" = hello
    touch ~/from-container
    if touch /etc/claude-code/x 2>/dev/null; then false; fi
  '
  test -f 'h,"1/from-container'
}

test_scratch() {
  touch from-host
  echo 'export FOO=bar' > .envrc
  direnv allow
  volumes=$(docker volume ls -q | wc -l)
  clod -s bash -c '
    set -e
    test "$CLOD_SCRATCH" = 1
    test -z "${CLOD_WORKSPACE_PATH:-}"
    test -z "$(ls -A /workspace)"
    test -z "${FOO:-}"
    touch /workspace/written
  ' 2>&1 | tee out
  if grep -q 'workspace is empty' out; then false; fi
  test ! -e written
  test "$(docker volume ls -q | wc -l)" = "$volumes"
  clod -s env | has '^scratch:'
  if clod -s env | has '^envrc:'; then false; fi
  clod -s --docker bash -c 'test -z "${CLOD_HOST_WORKSPACE:-}"'
  cd ~
  clod -s bash -c true
}

test_workspace() {
  local here=$PWD
  mkdir proj
  echo from-proj > proj/file
  echo 'export FOO=proj' > proj/.envrc
  echo 'export FOO=here' > .envrc
  direnv allow proj
  direnv allow
  clod -w proj env | has "^workspace: *$here/proj\$"
  clod -w proj env | has '^envrc: .*/proj/.envrc$'
  clod -w proj bash -c '
    set -e
    test "$(cat /workspace/file)" = from-proj
    test "$FOO" = proj
    test "$CLOD_WORKSPACE" = "'"$here/proj"'"
    test "$CLOD_WORKSPACE_PATH" = "'"$here/proj"'"
  '
  exits 1 clod -w nope bash -c true
  exits 1 clod -w nope env
  clod -w nope home >/dev/null
  exits 2 clod -s -w proj bash -c true
  exits 1 clod -w ~ bash -c true 2>&1 | has 'refusing to mount'
  mkdir -p ~/.clod/homes/x
  exits 1 clod -w ~/.clod/homes/x bash -c true 2>&1 | has 'refusing to mount'
  cd ~
  clod -w "$here/proj" bash -c 'test "$(cat /workspace/file)" = from-proj && test "$FOO" = proj'
  # a volume workspace is claude's, kept between runs, and reads no .envrc
  cd "$here/proj"
  docker volume rm -f clod-workspace-wtest >/dev/null
  clod -w vol:wtest bash -c '
    set -e
    test "$CLOD_WORKSPACE" = vol:wtest
    test -z "${CLOD_WORKSPACE_PATH:-}"
    test "$(stat -c %U /workspace)" = claude
    test -z "${FOO:-}"
    echo kept > /workspace/kept
  '
  clod -w vol:wtest bash -c 'test "$(cat /workspace/kept)" = kept'
  clod -w vol:wtest env | has '^workspace: *vol:wtest (Docker volume clod-workspace-wtest)'
  if clod -w vol:wtest env | has '^envrc:'; then false; fi
  exits 1 clod -w vol:./x env
  docker volume rm clod-workspace-wtest >/dev/null
}

test_worktree() {
  git init -q -b main repo
  git -C repo -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C repo worktree add -q ../wt -b feature
  clod -w wt bash -c '
    set -e
    cd /workspace
    git -c user.name=t -c user.email=t@t commit -q --allow-empty -m inside
    test "$(git branch --show-current)" = feature
    common=$(git rev-parse --path-format=absolute --git-common-dir)
    if touch "$common/hooks/pre-commit" 2>/dev/null; then false; fi
    if git config core.fsmonitor x 2>/dev/null; then false; fi
  ' 2>&1 | has ' · git .*/repo/.git'
  test "$(git -C repo log -1 --format=%s feature)" = inside
  test ! -e repo/.git/hooks/pre-commit
  test -z "$(git -C repo config --get core.fsmonitor || true)"
  # a worktree's config.worktree, with worktreeConfig, is read-only too
  git -C repo config extensions.worktreeConfig true
  clod -w wt bash -c 'cd /workspace; if git config --worktree core.fsmonitor x 2>/dev/null; then false; fi'
  # a relative gitdir is left alone, with a note
  echo 'gitdir: ../repo/.git/worktrees/wt' > wt/.git
  clod -w wt bash -c true 2>&1 | has 'relative gitdir'
}

test_refuses_home() {
  cd ~
  exits 1 clod bash -c true
}

test_claude() {
  clod claude --version | tee out
  grep -q 'Claude Code' out
  # a symlink into the container's paths, so dangling out here
  test -L ~/.clod/homes/default/.local/bin/claude
}

test_claude_args() {
  # a stand-in claude in its own home shows what the entrypoint passes
  mkdir -p ~/.clod/homes/args/.local/bin
  printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > ~/.clod/homes/args/.local/bin/claude
  chmod +x ~/.clod/homes/args/.local/bin/claude
  clod -H args -- -p hi | tee out
  has -e '^--settings=/etc/claude-code/settings.json$' out
  has -e '^--dangerously-skip-permissions$' out
  has -e '^--plugin-dir=/etc/clod/plugins/show-image$' out
  test "$(tail -2 out | tr '\n' ' ')" = '-p hi '
  # only the last --settings applies, so the user's own replaces the shared one
  clod -H args -- --settings mine.json -p hi | tee out
  exits 1 grep -q /etc/claude-code/settings.json out
  clod -H args -- --settings=mine.json -p hi | tee out
  exits 1 grep -q /etc/claude-code/settings.json out
}

test_codex() {
  clod codex --version | tee out
  grep -qi codex out
}

test_statusline() {
  echo '{"model":{"display_name":"Opus"},"effort":{"level":"high"},"session_id":"ci","prompt_id":"p1",
         "workspace":{"current_dir":"/workspace"},
         "context_window":{"total_input_tokens":48200,"total_output_tokens":12100,"used_percentage":42,
           "current_usage":{"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},
         "cost":{"total_lines_added":120,"total_lines_removed":35},
         "rate_limits":{"five_hour":{"used_percentage":12}}}' > input.json
  git init -q -b main .
  # five columns over two lines: model over effort, context over tokens, home
  # over image and ports, git over lines changed; the 5h meter ends line 1
  clod -P 5173 -P 6000/udp bash -c 'bash /etc/claude-code/statusline.sh < /workspace/input.json' |
    sed 's/\x1b\[[0-9;]*m//g; s/\x1b\]8;;[^\x07]*\x07//g' | tee out
  test "$(wc -l < out)" = 2
  head -1 out | has '^✨ Opus  *◔ [▰▱]* 42%  *🏠 default  *🪾 main ±[0-9]  *5h '
  tail -1 out | has '^⚡ high  *↑0  *↓0  *📦 clod  ⇄ :5173  *+120/-35$'
  if grep -q 6000 out; then false; fi
  # subagents' transcripts beside the session's add to the token counts, each
  # streamed message counted once, at its last entry
  mkdir -p s/subagents
  echo '{"type":"assistant"}' > s.jsonl
  { echo '{"message":{"id":"m1","usage":{"input_tokens":10,"cache_creation_input_tokens":5000,"output_tokens":4}}}'
    echo '{"message":{"id":"m1","usage":{"input_tokens":10,"cache_creation_input_tokens":5000,"output_tokens":275}}}'
    echo '{"message":{"id":"m2","usage":{"input_tokens":3,"cache_creation_input_tokens":800,"cache_read_input_tokens":5000,"output_tokens":725}}}'
  } > s/subagents/agent-a.jsonl
  sed -i 's|"session_id":"ci"|"session_id":"sub","transcript_path":"/workspace/s.jsonl"|' input.json
  clod bash -c 'bash /etc/claude-code/statusline.sh < /workspace/input.json' |
    sed 's/\x1b\[[0-9;]*m//g' | tail -1 | has '↑5.8k  *↓1.0k '
  # inside .git, where git status fails, it still shows both lines
  sed -i 's|"/workspace"|"/workspace/.git"|' input.json
  clod bash -c 'bash /etc/claude-code/statusline.sh < /workspace/input.json' > out
  test "$(wc -l < out)" = 2
  # halfway through both windows, the 5h bar's last cell is yellow (48% used)
  # and the 7d bar's red (60% used, ahead)
  local now
  now=$(date +%s)
  printf '{"session_id":"q","rate_limits":{"five_hour":{"used_percentage":48,"resets_at":%d},
    "seven_day":{"used_percentage":60,"resets_at":%d}}}' $((now + 9000)) $((now + 302400)) > input.json
  clod bash -c 'bash /etc/claude-code/statusline.sh < /workspace/input.json' |
    sed 's/\x1b\[92m▰/G/g; s/\x1b\[93m▰/Y/g; s/\x1b\[91m▰/R/g; s/\x1b\[[0-9;]*m//g' | tee out
  head -1 out | has '5h GGGGY▁▁▁▁▁ 48%/50%$'
  tail -1 out | has '7d GGGGGR▁▁▁▁ 60%/50%$'
  # with room in the terminal the bars widen to 20 cells and end 4 columns short
  clod bash -c 'COLUMNS=120 bash /etc/claude-code/statusline.sh < /workspace/input.json' |
    sed 's/\x1b\[[0-9;]*m//g' | tee out
  head -1 out | has '5h [▰▱▁]\{20\} 48%/50%$'
  # (✨ and 🏠 take two columns each)
  test "$(head -1 out | sed "s/✨/xx/; s/🏠/xx/" | wc -m)" = 117
}

test_port() {
  echo served > index.html
  clod -P 8000 bash -c 'timeout 60 python3 -m http.server 8000 --bind 0.0.0.0' &
  for _ in $(seq 30); do
    curl -fs http://127.0.0.1:8000/index.html > out && break
    sleep 2
  done
  kill $! 2>/dev/null || true
  grep -q served out
}

# A host port another container has: -P stops, CLOD_PORTS skips it, or with
# CLOD_PORTS_BUSY=next moves it.
test_port_busy() {
  docker rm -f clod-test-ports >/dev/null 2>&1 || true
  docker run -d --rm --name clod-test-ports -p 127.0.0.1:18090:80 -p 0.0.0.0:18092:80 \
    --entrypoint sleep clod 300 >/dev/null
  trap 'docker rm -f clod-test-ports >/dev/null 2>&1' EXIT
  exits 1 clod -P 18090 bash -c true 2>&1 | has "can't publish 127.0.0.1:18090: container clod-test-ports has it"
  # a wildcard address takes the port on every address
  exits 1 clod -P 18092 bash -c true 2>&1 | has "can't publish 127.0.0.1:18092"
  clod -P 18091 bash -c 'test "$CLOD_PORTS" = 18091'
  export CLOD_PORTS=18090,18091
  clod env | has '^ports: .*(each left out if another container has it)$'
  clod bash -c 'test "$CLOD_PORTS" = 18091' 2>&1 | tee out
  has -x 'clod: not publishing 127.0.0.1:18090 → 18090: container clod-test-ports has it' < out
  CLOD_PORTS=18090 CLOD_PORTS_BUSY=next clod bash -c 'test "$CLOD_PORTS" = 18090' 2>&1 | tee out
  has -x 'clod: publishing 127.0.0.1:18091 → 18090, since container clod-test-ports has 127.0.0.1:18090' < out
  # 18093 is the first free one after 18092
  CLOD_PORTS=18092 CLOD_PORTS_BUSY=next clod bash -c true 2>&1 | has 'publishing 127.0.0.1:18093 → 18092'
  CLOD_PORTS_BUSY=error exits 1 clod bash -c true 2>&1 | has "can't publish 127.0.0.1:18090"
  CLOD_PORTS_BUSY=nope exits 1 clod bash -c true 2>&1 | has "it must be skip, next or error"
  # another protocol's port isn't taken
  CLOD_PORTS=18090/udp CLOD_PORTS_BUSY=error clod bash -c 'test "$CLOD_PORTS" = 18090/udp'
}

# The show-image plugin passes Claude Code's checks and its own tests, and its
# convert.py turns a GIF into a PNG no bigger than asked, with Pillow.
test_show_image() {
  clod claude --version
  clod bash -c 'claude plugin validate /etc/clod/plugins/show-image &&
    cd /etc/clod/plugins/show-image && claude plugin test .'
  clod bash -c 'cd /tmp && python3 -c "from PIL import Image; Image.new(\"P\", (400, 200)).save(\"a.gif\")" &&
    python3 /etc/clod/plugins/show-image/convert.py a.gif 100 100000 | base64 -d > a.png &&
    python3 -c "from PIL import Image; i = Image.open(\"a.png\"); print(i.format, i.size)"' | tee out
  has -x 'PNG (100, 50)' out
}

# --clipboard: the image's xclip and wl-paste fetch the host clipboard's image,
# here whatever CLOD_CLIPBOARD_COMMAND prints, as Claude Code's Ctrl+V asks.
test_clipboard() {
  printf '\x89PNG\r\n\x1a\nnot really' > clip.png
  export CLOD_CLIPBOARD_COMMAND="cat $PWD/clip.png"
  clod bash -c 'test -z "${CLOD_CLIPBOARD_URL:-}" && ! xclip -selection clipboard -t TARGETS -o'
  if clod env | has '^clipboard:'; then false; fi
  clod --clipboard env | has '^clipboard:'
  clod --clipboard bash -c '
    set -e
    xclip -selection clipboard -t TARGETS -o | grep -q image/png
    xclip -selection clipboard -t image/png -o > /workspace/xclip.png
    wl-paste -l | grep -q image/png
    wl-paste --type image/png > /workspace/wl-paste.png
    if xclip -selection clipboard -t text/plain -o; then exit 1; fi
    if curl -fs "${CLOD_CLIPBOARD_URL%/*}/wrong"; then exit 1; fi
  ' 2>&1 | tee out
  has 'clipboard$' < out
  cmp clip.png xclip.png
  cmp clip.png wl-paste.png
  # no image on the clipboard
  CLOD_CLIPBOARD_COMMAND=true CLOD_CLIPBOARD=on clod bash -c '! xclip -selection clipboard -t TARGETS -o'
  CLOD_CLIPBOARD=maybe exits 1 clod bash -c true 2>&1 | has 'it must be on or off'
  exits 2 clod default clipboard maybe
  # the server exits with the run
  sleep 3
  if pgrep -f clipboard-server.py; then false; fi
}

test_docker_socket() {
  echo sibling > from-host
  clod bash -c 'test ! -e /var/run/docker.sock'
  if clod env | has '^docker:'; then false; fi
  clod --docker env | has '^docker:'
  clod --docker bash -c true 2>&1 | has 'clod has no docker CLI'
  clod -i docker --docker bash -c '
    set -e
    test "$(id -un)" = claude
    docker compose version && docker buildx version
    test -r /etc/clod/.claude/rules/docker.md
    docker ps
    test "$(docker run --rm --entrypoint cat -v "$CLOD_HOST_WORKSPACE:/w" clod /w/from-host)" = sibling
  ' 2>&1 | tee out
  if grep -q 'no docker CLI' out; then false; fi
  mkdir sub
  clod -i docker --docker -w sub bash -c 'test "$CLOD_HOST_WORKSPACE" = "'"$PWD/sub"'"'
  # a volume workspace has no host path; the agent's containers mount it by name
  docker volume rm -f clod-workspace-dtest >/dev/null
  clod -i docker --docker -w vol:dtest bash -c '
    set -e
    test -z "${CLOD_HOST_WORKSPACE:-}"
    echo sibling > /workspace/from-agent
    test "$(docker run --rm --entrypoint cat -v clod-workspace-dtest:/w clod /w/from-agent)" = sibling
  '
  docker volume rm clod-workspace-dtest >/dev/null
}

test_envrc() {
  printf 'export FOO=bar MULTI="a\nb" CLOD_HOME=from-envrc\n' > .envrc
  exits 1 clod env
  direnv allow
  clod env 2>&1 | tee out
  grep -q '^FOO=bar$' out
  grep -q 'skipping multi-line variable MULTI' out
  grep -q '^home: *from-envrc' out
  echo 'export CLOD_PORTS=5000' >> .envrc
  direnv allow
  clod env | has '^ports: .*5000'
  if CLOD_PORTS='' clod env | has '^ports:'; then false; fi
  if clod -P '' env | has '^ports:'; then false; fi
  clod home new from-envrc >/dev/null
  clod bash -c 'test "$FOO" = bar && test -z "${MULTI:-}" && test "$CLOD_HOME" = from-envrc && test "$CLOD_HOME_PATH" = "~/.clod/homes/from-envrc"'
}

test_volume_home() {
  docker volume rm -f clod-home-vtest >/dev/null
  clod home new vol:vtest >/dev/null
  clod -H vol:vtest bash -c '
    set -e
    test "$CLOD_HOME" = vol:vtest
    test -z "${CLOD_HOME_PATH:-}"
    test "$(stat -c %U ~)" = claude
    echo kept > ~/kept
    mkdir ~/owned && chown claude:claude ~/owned
  '
  clod -H vol:vtest bash -c 'test "$(cat ~/kept)" = kept'
  test ! -e ~/.clod/homes/vol:vtest
  clod -H vol:vtest env | has '^home: *vol:vtest (Docker volume clod-home-vtest)'
  clod -H vol:vtest home | has '^\* vol:vtest '
  exits 1 clod -H vol:./x env
  # home rm takes names and vol:NAME, not paths, asks first, and needs --force
  # without a terminal
  exits 2 clod home rm ./x 2>&1 | has 'delete the home ./x yourself'
  exits 2 clod --force home rm vol:vtest ~/.clod/homes/x
  exits 2 clod home rm -- -f 2>&1 | has "'-f' isn't a name"
  # a name it doesn't know removes none of them
  exits 1 clod --force home rm vol:vtest vol:no-such
  docker volume inspect clod-home-vtest >/dev/null
  exits 1 clod home rm vol:vtest < /dev/null 2>&1 | tee out
  has 'no terminal' < out
  if grep -q deleting out; then false; fi
  docker volume inspect clod-home-vtest >/dev/null
  # Docker won't remove a volume a container uses
  docker rm -f clod-test-home >/dev/null 2>&1 || true
  docker create --name clod-test-home -v clod-home-vtest:/h clod >/dev/null
  exits 1 clod --force home rm vol:vtest 2>&1 | has 'a container uses vol:vtest'
  docker rm clod-test-home >/dev/null
  docker volume inspect clod-home-vtest >/dev/null
  clod --force home rm vol:vtest | has -x 'removed vol:vtest (Docker volume clod-home-vtest)'
  if docker volume inspect clod-home-vtest >/dev/null 2>&1; then false; fi
  if clod home | grep -q vtest; then false; fi
  # a directory home, the same way
  mkdir -p ~/.clod/homes/dtest/.claude
  exits 1 clod home rm dtest < /dev/null 2>&1 | has 'no terminal'
  test -d ~/.clod/homes/dtest
  docker create --name clod-test-home --mount "type=bind,src=$HOME/.clod/homes/dtest,dst=/h" clod >/dev/null
  exits 1 clod --force home rm dtest 2>&1 | has 'a container uses dtest'
  docker rm clod-test-home >/dev/null
  test -d ~/.clod/homes/dtest
  clod --force home rm dtest dtest | has -x "removed dtest (the folder ~/.clod/homes/dtest)"
  test ! -e ~/.clod/homes/dtest
  exits 1 clod --force home rm dtest 2>&1 | has 'no home dtest'
}

# home cp and mv, between directory and volume homes both ways: the copy is
# claude's, and they refuse a missing source, an existing destination, a home a
# container uses and a directory that's off limits.
test_home_copy() {
  docker volume rm -f clod-home-cp1 clod-home-cp2 >/dev/null
  docker rm -f clod-test-cp clod-test-cp-dir clod-test-cp-gone >/dev/null 2>&1 || true
  mkdir -p ~/.clod/homes/src/.config
  echo hi > ~/.clod/homes/src/.config/f
  chmod 600 ~/.clod/homes/src/.config/f
  test "$(clod home cp src vol:cp1)" = 'copied src to vol:cp1'
  test -f ~/.clod/homes/src/.config/f
  clod -H vol:cp1 bash -c '
    set -e
    test "$(cat ~/.config/f)" = hi
    test "$(stat -c %U ~ ~/.config ~/.config/f | sort -u)" = claude
    test "$(stat -c %a ~/.config/f)" = 600
    touch ~/written
  '
  test "$(clod home cp vol:cp1 back)" = 'copied vol:cp1 to back'
  test "$(cat ~/.clod/homes/back/.config/f)" = hi
  test -O ~/.clod/homes/back/written
  test "$(clod home mv vol:cp1 vol:cp2)" = 'moved vol:cp1 to vol:cp2'
  if docker volume inspect clod-home-cp1 >/dev/null 2>&1; then false; fi
  clod -H vol:cp2 bash -c 'test -f ~/written'
  test "$(clod home mv back vol:cp1)" = 'moved back to vol:cp1'
  test ! -e ~/.clod/homes/back
  clod -H vol:cp1 bash -c 'test -f ~/written'
  # a directory moved to a directory is renamed
  test "$(clod home mv src ./moved/here)" = 'moved src to ./moved/here'
  test ! -e ~/.clod/homes/src
  test -f moved/here/.config/f
  exits 2 clod home cp src
  exits 2 clod home mv a b c
  exits 1 clod home cp nope vol:x 2>&1 | has -x 'clod: no home nope (clod home lists them)'
  exits 1 clod home cp vol:nope x 2>&1 | has 'no home vol:nope'
  exits 1 clod home cp vol:cp1 vol:cp2 2>&1 | has 'already a home vol:cp2'
  mkdir -p ~/.clod/homes/taken
  exits 1 clod home mv vol:cp1 taken 2>&1 | has 'taken already exists'
  exits 1 clod home cp ./moved ./moved/here/inside 2>&1 | has 'into itself'
  exits 1 clod home mv ~ vol:x 2>&1 | has "won't touch"
  exits 1 clod home cp ~/.clod/homes vol:x 2>&1 | has "won't touch"
  exits 1 clod home cp vol:cp1 ~/.clod 2>&1 | has "won't touch"
  # neither a source nor a destination a container uses, even a stopped one
  docker create --name clod-test-cp -v clod-home-cp1:/h clod >/dev/null
  exits 1 clod home mv vol:cp1 elsewhere 2>&1 | has 'a container uses vol:cp1'
  docker create --name clod-test-cp-dir --mount "type=bind,src=$PWD/moved/here,dst=/h" clod >/dev/null
  exits 1 clod home cp ./moved/here vol:x 2>&1 | has 'a container uses'
  mkdir gone
  docker create --name clod-test-cp-gone --mount "type=bind,src=$PWD/gone,dst=/h" clod >/dev/null
  rmdir gone
  exits 1 clod home cp vol:cp2 ./gone 2>&1 | has 'a container uses'
  docker rm clod-test-cp clod-test-cp-dir clod-test-cp-gone >/dev/null
  test -f moved/here/.config/f
  test ! -e gone
  docker volume inspect clod-home-cp1 >/dev/null
  if docker volume inspect clod-home-x >/dev/null 2>&1; then false; fi
  clod --force home rm vol:cp1 vol:cp2 >/dev/null
}

# A run asks before creating a home that doesn't exist, and without a terminal
# fails; clod home new creates one.
test_home_new() {
  docker volume rm -f clod-home-ntest >/dev/null
  exits 1 clod -H fresh bash -c true < /dev/null 2>&1 |
    has -x "clod: there's no home fresh; clod home new fresh creates it"
  test ! -e ~/.clod/homes/fresh
  exits 1 clod -H vol:ntest bash -c true < /dev/null 2>&1 | has 'no home vol:ntest'
  if docker volume inspect clod-home-ntest >/dev/null 2>&1; then false; fi
  # in a terminal it asks
  printf 'n\n' | script -qec 'clod -H fresh bash -c true' /dev/null > out || true
  has 'no home fresh; create it' < out
  test ! -e ~/.clod/homes/fresh
  printf 'y\n' | script -qec 'clod -H fresh bash -c true' /dev/null > out
  test -d ~/.clod/homes/fresh
  clod -H fresh bash -c true
  test "$(clod home new made)" = 'created home made'
  clod -H made bash -c 'test "$(stat -c %U ~)" = claude'
  exits 1 clod home new made 2>&1 | has 'made already exists'
  test "$(clod home new vol:ntest)" = 'created home vol:ntest'
  clod -H vol:ntest bash -c 'test "$(stat -c %U ~)" = claude'
  exits 1 clod home new vol:ntest 2>&1 | has 'already a home vol:ntest'
  exits 2 clod home new
  exits 2 clod home new a b
  clod --force home rm vol:ntest >/dev/null
}

test_volume_workspace() {
  docker volume rm -f clod-workspace-one clod-workspace-two clod-workspace-three >/dev/null
  clod workspace | has 'no volume workspaces'
  clod -w vol:one bash -c true
  clod -w vol:two bash -c true
  clod workspace | has '^  vol:one  *-$'
  clod -w vol:two workspace | tee out
  has '^\* vol:two ' < out
  has '^\* used here' < out
  exits 2 clod workspace rm
  exits 2 clod workspace ls
  # a name it doesn't know removes none of them
  exits 1 clod workspace rm one no-such -f
  docker volume inspect clod-workspace-one >/dev/null
  exits 1 clod workspace rm one < /dev/null 2>&1 | tee out
  has 'no terminal' < out
  if grep -q deleting out; then false; fi
  docker volume inspect clod-workspace-one >/dev/null
  # in a terminal it lists the volumes and asks: n or no answer keeps them, y
  # removes them
  docker volume create clod-workspace-three >/dev/null
  printf 'n\n' | exits 1 script -qec 'clod workspace rm three' /dev/null > out
  has 'vol:three (Docker volume clod-workspace-three)' < out
  has 'Delete? \[y/N\]' < out
  has 'nothing deleted' < out
  docker volume inspect clod-workspace-three >/dev/null
  printf '\n' | exits 1 script -qec 'clod workspace rm three' /dev/null | has 'nothing deleted'
  docker volume inspect clod-workspace-three >/dev/null
  printf 'y\n' | script -qec 'clod workspace rm three' /dev/null |
    has 'removed vol:three (clod-workspace-three)'
  if docker volume inspect clod-workspace-three >/dev/null 2>&1; then false; fi
  # Docker won't remove a volume a container uses
  docker rm -f clod-test-volume >/dev/null 2>&1 || true
  docker create --name clod-test-volume -v clod-workspace-two:/w clod >/dev/null
  clod workspace | has '^  vol:two  *in use$'
  exits 1 clod --force workspace rm two 2>&1 | has 'a container uses vol:two'
  docker rm clod-test-volume >/dev/null
  test "$(clod --force workspace rm one vol:two)" = \
    "$(printf 'removed vol:one (clod-workspace-one)\nremoved vol:two (clod-workspace-two)')"
  clod workspace | has 'no volume workspaces'
}

test_default() {
  exits 1 clod default image no-such-image
  clod default image python
  clod default image | has '^image  *python .*config'
  clod default command bash
  clod -i clod -- -c 'echo from-default-command' | has from-default-command
  clod default command --reset
  clod default command | has '^command  *claude .*built in'
  clod env | has '^image: *python '
  clod default image clod
  clod env | has '^image: *clod$'
  exits 2 clod default ports-busy sometimes
  clod default ports-busy next | has '^ports-busy  *next .*config'
  CLOD_PORTS=8000 clod env | has '^ports: .*(each moved to a free host port if another container has it)$'
  clod -P 8000 env | has '^ports: *127.0.0.1:8000 → 8000$'
  clod default ports-busy --reset
  # default edit opens the config, then names the lines clod won't read
  rm -f ~/.clod/config
  test "$(EDITOR='echo' clod default edit)" = "$HOME/.clod/config"
  exits 2 clod default edit extra
  completes default '' | has -x edit
  test -z "$(completes default edit '')"
  printf '#!/bin/sh\nprintf "# mine\\nCLOD_HOME=work\\nCLOD_NOPE=1\\nimage=go\\n" >> "$1"\n' > append
  chmod +x append
  EDITOR=$PWD/append clod default edit 2>&1 | tee out
  has "line 3 of ~/.clod/config isn't a setting clod reads: CLOD_NOPE=1" < out
  has "line 4 of .* reads: image=go" < out
  if grep -q 'CLOD_HOME\|# mine' out; then false; fi
  clod default home | has '^home  *work '
  rm ~/.clod/config
}

test_shared() {
  exits 1 clod shared diff
  exits 1 clod shared edit 2>&1 | has 'clod shared new creates yours'
  exits 2 clod shared
  clod shared new
  test -f ~/.clod/shared/statusline.sh
  clod shared new | has 'has everything in the starter'
  clod shared diff | has 'same as the starter'
  clod env | has '^shared: *~/.clod/shared'
  rm ~/.clod/shared/statusline.sh
  echo '# mine' >> ~/.clod/shared/settings.json
  clod shared new | has 'missing  *statusline.sh'
  exits 1 clod shared diff | has '^Only in .*/shared: statusline.sh$'
  exits 1 clod shared diff | has -x '+# mine'
  # diff's trouble, status 2, is clod's
  mkdir bin
  printf '#!/bin/sh\nexit 2\n' > bin/diff
  chmod +x bin/diff
  PATH=$PWD/bin:$PATH exits 2 clod shared diff
  cp "$repo/container.md" ~/.clod/shared/CLAUDE.md
  clod shared new | has 'describes the container'
  echo '{"statusLine": {}}' > ~/.clod/shared/managed-settings.json
  clod shared new | has 'sets statusLine'
  # shared edit opens its CLAUDE.md, or a file named
  test "$(EDITOR='echo' clod shared edit)" = "$HOME/.clod/shared/CLAUDE.md"
  test "$(EDITOR='echo' clod shared edit settings.json)" = "$HOME/.clod/shared/settings.json"
  exits 2 clod shared edit ../config 2>&1 | has "isn't a file in"
  exits 2 clod shared edit a b
  completes shared edit '' | has -x settings.json
  test -z "$(completes shared edit settings.json '')"
  clod --force shared new
  test -f ~/.clod/shared/statusline.sh
  ls -d ~/.clod/shared.bak-*
  rm -r ~/.clod/shared ~/.clod/shared.bak-*
}

test_command_line() {
  exits 2 clod -p 'a prompt'
  exits 1 clod -H ~ bash -c true
  exits 2 clod --resume
  exits 2 clod 'a prompt'
  exits 1 clod image build mine
  exits 2 clod image prune extra
  exits 2 clod env extra
  exits 2 clod image new a b c
  exits 2 clod image new
  exits 2 clod image new -mine 2>&1 | has 'unknown option -mine'
  exits 2 clod image new -- -mine 2>&1 | has 'invalid image name'
  for name in Mine mine_ my.image; do
    exits 2 clod image new "$name" 2>&1 | has 'invalid image name'
  done
  exits 2 clod image show
  exits 2 clod image edit a b c
  exits 2 clod image nope
  exits 2 clod home ls
  for old in images homes new-image remove-image prune new-shared; do
    exits 2 clod "$old" 2>&1 | has "unknown command '$old'"
  done
  # build and rebuild still work, with a note naming image build
  exits 1 clod build mine 2>&1 | has 'clod build is deprecated; use clod image build$'
  exits 1 clod rebuild mine 2>&1 | has 'use clod image rebuild$'
  clod -i clod-python env | has '^image: *python (.*images/python)'
  # a run command's -h goes to the program it runs
  test "$(clod bash -c 'echo "$0"' -h)" = -h
  clod --version | has '^clod '
  # clod's options go after a command too, up to --; an unknown one is an
  # error, after -h has had its chance
  clod env -H other -i python | has '^image: *python '
  clod image -i python edit -h | has -x 'usage: clod image edit \[OPTIONS\] \[NAME \[FILE\]\]'
  exits 2 clod env --nope 2>&1 | has -x "clod: unknown option --nope (see 'clod env -h')"
  clod env --nope -h | has '^usage: clod env '
  exits 2 clod image --reset 2>&1 | has 'unknown option --reset'
  # after a run command, they're the program's
  test "$(clod bash -c 'echo "$0"' -i)" = -i
  clod -H other -i python -P 3000:8080 env | tee out
  grep -q '^home: *other' out
  grep -q '^image: *python ' out
  grep -q '^ports: *127.0.0.1:3000 → 8080$' out
  clod -P 6000/udp env | has '^ports: *127.0.0.1:6000 → 6000/udp$'
  clod bash -c true
  clod image | has '^\* clod  *built'
  clod home | has '^\* default'
  rm -rf ~/.clod/images/mine ~/.clod/images/starter
  clod image new mine go
  grep -q '^FROM \$BASE$' ~/.clod/images/mine/Dockerfile
  clod image new starter
  clod image | has 'starter .*~/.clod/images/starter'
  clod --skip-build bash -c true 2>&1 | has 'running clod as built'
}

# clod help, the commands' pages, and the pages the usage errors point to.
# Needs no Docker.
test_help() {
  clod help > out
  has -x 'usage: clod \[OPTIONS\] \[COMMAND \[ARGS...\]\]' < out
  has -x 'Images' < out
  has -xE '  image rm NAME\.\.\. +delete your variants and their built images' < out
  has -xE '  image clean \[NAME\.\.\.\] +remove built images, keeping their variants' < out
  has -xE '  -i, --image NAME +the image or variant to run, or a\+b \(CLOD_IMAGE\)' < out
  has -x "'clod COMMAND -h' shows more about COMMAND." < out
  if grep -q '^  shared  *the shared config' out; then false; fi
  clod -h | diff - out
  clod --help | diff - out
  # a command's page: -h or --help after it, before it, or clod help COMMAND
  clod home rm -h > out
  has -x 'usage: clod home rm \[OPTIONS\] NAME\.\.\.' < out
  has -xE '  -f, --force +delete without asking; needed without a terminal' < out
  clod home rm vol:x --help | diff - out
  clod -h home rm | diff - out
  clod help home rm | diff - out
  # not after --
  exits 2 clod home rm -- -h 2>&1 | has "'-h' isn't a name"
  # a noun's page lists its verbs, default's its keys, help's its own
  clod image -h | has -xE '  image prune +remove the stale images clod built'
  clod shared -h | has -x 'usage: clod shared COMMAND'
  clod help default | has -xE '  ports \(CLOD_PORTS\) +ports to publish on localhost, comma-separated'
  clod help default | has -x '       clod default KEY --reset'
  clod help -h | has -x 'usage: clod help \[COMMAND\]'
  clod help claude | has 'ARGS go to Claude Code unchanged'
  clod build -h 2>/dev/null | has -x 'usage: clod image build \[OPTIONS\] \[NAME\.\.\.\]'
  # every command and verb has a page that says what it does, within 80
  # columns
  for c in $(completes ''); do
    for v in '' $(completes help "$c" ''); do
      # shellcheck disable=SC2086 # no verb is no word
      clod help "$c" $v > out
      test -n "$(awk 'NF == 0 { blank = 1; next } blank { print; exit }' out)"
      if awk 'length > 80' out | grep -q .; then false; fi
    done
  done
  # usage errors point to the page to read
  exits 2 clod home rm 2>&1 | has "(see 'clod home rm -h')$"
  exits 2 clod image nope 2>&1 | has "(see 'clod image -h')$"
  exits 2 clod default nokey 2>&1 | has "(see 'clod default -h')$"
  exits 2 clod nope 2>&1 | has "(see 'clod help')$"
  exits 2 clod -x 2>&1 | has "(see 'clod help')$"
  exits 2 clod -s -w x claude 2>&1 | has "(see 'clod help claude')$"
  exits 2 clod help nope 2>&1 | has "unknown command 'nope' (see 'clod help')$"
  exits 2 clod help image nope 2>&1 | has "unknown image command 'nope'"
}

test_multi_stage() {
  mkdir -p ~/.clod/images/one ~/.clod/images/stages
  printf 'FROM clod\n' > ~/.clod/images/one/Dockerfile
  printf 'FROM debian:trixie-slim AS build\nFROM clod-one\n' > ~/.clod/images/stages/Dockerfile
  clod -i stages bash -c true
  clod image | has '^  stages  *built'
  echo 'RUN true' >> ~/.clod/images/one/Dockerfile
  clod image | has '^  one  *stale'
  clod image | has '^  stages  *stale'
  clod -i stages bash -c true 2>&1 | tee out
  grep -q 'building one\.\.\.' out
  grep -q 'building stages\.\.\.' out
  clod image | has '^  stages  *built'
  clod image show stages | has '^stages  *built  *debian:trixie-slim, one  '
  clod image show stages | has '^one  *built  *clod  '
}

# Writes variants first and second, which take their base as BASE and record
# the order they were built in.
order_variants() {
  mkdir -p ~/.clod/images/first ~/.clod/images/second
  printf 'ARG BASE=clod\nFROM $BASE\nRUN echo first > /tmp/order\n' > ~/.clod/images/first/Dockerfile
  printf 'ARG BASE=clod\nFROM $BASE\nRUN echo second >> /tmp/order\n' > ~/.clod/images/second/Dockerfile
}

test_combine() {
  order_variants
  mkdir -p ~/.clod/images/third ~/.clod/images/fixed
  # braces, and no default: it only ever goes on top of another
  printf 'ARG BASE\nFROM ${BASE}\nRUN echo third >> /tmp/order\n' > ~/.clod/images/third/Dockerfile
  printf 'FROM clod\n' > ~/.clod/images/fixed/Dockerfile
  clod -i first+second env | has '^image: *first+second '
  clod -i first+second bash -c 'test "$(cat /tmp/order)" = "$(printf "first\nsecond")"'
  clod -i first+second bash -c 'test "$CLOD_IMAGE" = first+second' 2>&1 | has '^clod ⌂ .* ⬢ first+second · '
  clod image | has '^  first+second  *built'
  clod -i clod-first.second --skip-build bash -c true
  echo 'RUN true' >> ~/.clod/images/first/Dockerfile
  clod image | has '^  first+second  *stale'
  clod -i first+second bash -c true 2>&1 | has 'building first+second\.\.\.'
  exits 1 clod -i first+fixed env 2>out
  grep -q "fixed can't go on top" out
  exits 1 clod -i first+nope env
  for name in first+ +first first++second; do
    exits 1 clod -i "$name" env 2>out
    grep -q 'invalid image name' out
  done
  exits 1 clod default image first+nope
  clod -i fixed+first env | has '^image: *fixed+first '
  # the Docker image's name works too
  clod -i first.second env | has '^image: *first+second '
  clod -i clod-first.second env | has '^image: *first+second '
  # three: third is built on the combination first+second
  clod -i first+second+third bash -c 'test "$(cat /tmp/order)" = "$(printf "first\nsecond\nthird")"'
  clod image | has '^  first+second+third  *built'
  clod image show first+second+third > out
  test "$(awk 'NR > 1 { print $1 }' out)" = "$(printf 'first+second+third\nfirst+second\nfirst\nclod')"
  has '^first+second  *built  *first  ' < out
  has '^first+second+third  .*/images/third/Dockerfile$' < out
  exits 1 clod image show nope
  exits 2 clod image show first second
  clod default image first+second
  clod env | has '^image: *first+second '
  clod image | has '^\* first+second  *built'
  clod default image --reset
  # a variant on a combination rebuilds when a variant in it changes
  rm -rf ~/.clod/images/ontop
  clod image new ontop first+second
  grep -q '^FROM clod-first\.second$' ~/.clod/images/ontop/Dockerfile
  grep -q 'FROM names first+second as Docker does: clod-first\.second\.$' ~/.clod/images/ontop/Dockerfile
  clod -i ontop bash -c 'test "$(cat /tmp/order)" = "$(printf "first\nsecond")"'
  clod image | has '^  ontop  *built'
  echo 'RUN true' >> ~/.clod/images/second/Dockerfile
  clod image | has '^  ontop  *stale'
  clod -i ontop bash -c true 2>&1 | tee out
  grep -q 'building first+second\.\.\.' out
  grep -q 'building ontop\.\.\.' out
}

# entrypoint.sh, container.md, clipboard.sh and the plugin are mounted from the
# checkout, so changing them applies on the next run without a build. A copy of
# clod beside copies of the base's files builds the same image, from the layer
# cache.
test_live_files() {
  mkdir standin
  cp "$repo/clod" "$repo/Dockerfile" "$repo/entrypoint.sh" "$repo/container.md" "$repo/clipboard.sh" \
    "$repo/.dockerignore" standin/
  cp -R "$repo/plugins" standin/
  standin/clod image build
  echo 'live description' >> standin/container.md
  sed -i '2a echo live entrypoint >&2' standin/entrypoint.sh
  perl -pi -e 'print "echo live clipboard; exit 0\n" if $. == 2' standin/clipboard.sh
  echo '# live plugin' >> standin/plugins/show-image/convert.py
  standin/clod bash -c 'cat /etc/clod/.claude/rules/clod.md; test -x /usr/local/bin/clod-clipboard && xclip -version
    tail -1 /etc/clod/plugins/show-image/convert.py' > out 2> err
  if grep -q 'building' err; then false; fi
  has -x 'live entrypoint' err
  test "$(tail -3 out)" = "$(printf 'live description\nlive clipboard\n# live plugin')"
  # the image's own copies serve docker run without clod
  docker run --rm --pull=never clod bash -c 'cat /etc/clod/.claude/rules/clod.md; xclip -version
    cat /etc/clod/plugins/show-image/convert.py; true' 2>&1 |
    if grep -q live; then false; fi
}

# image rebuild replaces every image in the chain and prunes the old ones. It
# runs a copy of clod whose base Dockerfile only writes a file, since rebuilding
# the real one without the cache takes half a minute; that replaces the clod
# image, which the next test to use it rebuilds from the layer cache.
test_rebuild() {
  local t i before=() after=()
  [[ -f ~/.clod/images/first/Dockerfile ]] || order_variants
  mkdir standin
  cp "$repo/clod" "$repo/entrypoint.sh" "$repo/container.md" "$repo/clipboard.sh" standin/
  cp -R "$repo/plugins" standin/
  printf 'FROM debian:trixie-slim\nRUN date > /built\n' > standin/Dockerfile
  standin/clod -i first+second image build
  test "$(standin/clod -i first+second image build 2>&1)" = 'clod: first+second is up to date'
  for t in clod clod-first clod-first.second; do before+=("$(docker image inspect -f '{{.Id}}' "$t")"); done
  standin/clod -i first+second image rebuild
  for t in clod clod-first clod-first.second; do after+=("$(docker image inspect -f '{{.Id}}' "$t")"); done
  for i in 0 1 2; do
    test "${before[i]}" != "${after[i]}"
    if docker image inspect "${before[i]}" >/dev/null 2>&1; then false; fi
  done
  # image build rebuilds only what changed, and prunes what it replaced
  echo 'RUN true' >> ~/.clod/images/second/Dockerfile
  standin/clod -i first+second image build 2>&1 | tee out
  if grep -q 'building first\.\.\.' out; then false; fi
  grep -q 'building first+second\.\.\.' out
  test "$(docker image inspect -f '{{.Id}}' clod-first)" = "${after[1]}"
  if docker image inspect "${after[2]}" >/dev/null 2>&1; then false; fi
  # image build takes names, which win over -i, and builds a shared base once
  exits 1 clod image build no-such
  echo 'RUN true' >> ~/.clod/images/first/Dockerfile
  clod -i no-such image build first first+second 2>&1 | tee out
  test "$(grep -c 'building first\.\.\.' out)" = 1
  grep -q 'building first+second\.\.\.' out
  test "$(clod -i no-such image build first first+second)" = \
    "$(printf 'clod: first is up to date\nclod: first+second is up to date')"
  # the build alias, with its note on stderr only
  test "$(clod build first 2>/dev/null)" = 'clod: first is up to date'
}

# image rm deletes your variants and the images built from them, asking first
# in a terminal; a bundled variant or a combination has nothing of yours.
# clod image edit opens only your own variants' files, and with --build builds
# them.
test_image_edit() {
  # image new names image edit
  clod image new newone | has -x 'Edit its Dockerfile with: clod image edit newone'
  rm -r ~/.clod/images/newone
  mkdir -p ~/.clod/images/editme
  printf 'ARG BASE=clod\nFROM $BASE\n' > ~/.clod/images/editme/Dockerfile
  test "$(EDITOR='echo edited' clod image edit editme)" = "edited $HOME/.clod/images/editme/Dockerfile"
  test "$(VISUAL='echo visual' EDITOR=false clod image edit editme)" = "visual $HOME/.clod/images/editme/Dockerfile"
  # with no name, the image -i selects
  test "$(EDITOR='echo' clod -i editme image edit)" = "$HOME/.clod/images/editme/Dockerfile"
  # sh reads the editor setting, as git does: quoted arguments, and a path with
  # a space
  mkdir -p 'my tools'
  printf '#!/bin/sh\nprintf "[%%s]" "$@"\n' > 'my tools/ed'
  chmod +x 'my tools/ed'
  test "$(EDITOR="\"$PWD/my tools/ed\" -c 'set ft=x'" clod image edit editme)" = \
    "[-c][set ft=x][$HOME/.clod/images/editme/Dockerfile]"
  exits 1 clod image edit go 2>&1 | has 'clod image new go makes your own copy'
  exits 1 clod image edit clod 2>&1 | has "base image is clod's own"
  exits 1 clod image edit go+editme 2>&1 | has 'is a combination'
  exits 1 clod image edit nope 2>&1 | has "no variant of yours named 'nope'"
  # another file beside the Dockerfile, but nothing outside the directory
  test "$(EDITOR='echo' clod image edit editme CLAUDE.md)" = "$HOME/.clod/images/editme/CLAUDE.md"
  for bad in ../x /etc/passwd sub/../../x ./Dockerfile; do
    exits 2 clod image edit editme "$bad" 2>&1 | has "isn't a file in"
  done
  mkdir ~/.clod/images/editme/sub
  exits 2 clod image edit editme sub 2>&1 | has 'is a directory'
  exits 2 clod image edit editme Dockerfile extra
  touch ~/.clod/images/editme/sub/x
  completes image edit editme '' | has -x Dockerfile
  completes image edit editme '' | has -x sub/x
  # --build builds once the editor exits, and not if it fails
  exits 2 clod --build image show editme 2>&1 | has -- '--build goes with image edit'
  exits 2 clod image show editme --build 2>&1 | has -- '--build goes with image edit'
  EDITOR=true clod image edit editme --build
  clod image show editme | has '^editme  *built '
  echo 'LABEL edited=1' >> ~/.clod/images/editme/Dockerfile
  EDITOR=false exits 1 clod image edit --build editme
  clod image show editme | has '^editme  *stale '
  EDITOR=true clod --build image edit editme
  clod image show editme | has '^editme  *built '
  EDITOR=true clod --build image edit editme | has 'editme is up to date'
  clod image clean editme
  rm -r ~/.clod/images/editme
}

# clod image diff compares your copy of a bundled variant with it. Needs no
# Docker.
test_image_diff() {
  clod image new python
  clod image diff python | has 'same as the bundled python'
  echo 'RUN true' >> ~/.clod/images/python/Dockerfile
  exits 1 clod image diff python | has -x '+RUN true'
  completes image diff '' | has -x python
  test -z "$(completes image diff python '')"
  mkdir -p ~/.clod/images/onlymine
  printf 'FROM clod\n' > ~/.clod/images/onlymine/Dockerfile
  if completes image diff '' | grep -qx onlymine; then false; fi
  exits 1 clod image diff onlymine 2>&1 | has 'no bundled variant is named onlymine'
  exits 1 clod image diff go 2>&1 | has "no variant of yours named 'go'"
  exits 2 clod image diff
  exits 2 clod image diff python go
  rm -r ~/.clod/images/python ~/.clod/images/onlymine
}

test_image_rm() {
  local v
  for v in mine other go; do
    mkdir -p ~/.clod/images/$v
    printf 'ARG BASE=clod\nFROM $BASE\nLABEL test=%s\n' "$v" > ~/.clod/images/$v/Dockerfile
  done
  clod -i other+mine image build
  clod -i go image build
  completes image rm '' | has -x mine
  completes image rm '' | has -x go
  if completes image rm '' | grep -qx sudo; then false; fi
  if completes image rm mine '' | grep -qx mine; then false; fi
  exits 2 clod image rm
  exits 1 clod --force image rm sudo 2>&1 | has 'clod image clean sudo removes its built image'
  exits 1 clod --force image rm other+mine 2>&1 | has 'clod image clean other+mine removes'
  exits 1 clod image rm mine --force no-such 2>&1 | has "no variant of yours named 'no-such'"
  test -d ~/.clod/images/mine
  exits 1 clod image rm mine < /dev/null 2>&1 | has 'no terminal'
  # in a terminal it lists the variant and the images built from it, and asks
  printf 'n\n' | exits 1 script -qec 'clod image rm mine' /dev/null > out
  has '  ~/.clod/images/mine' < out
  has 'other+mine (the image clod built)' < out
  has 'nothing deleted' < out
  test -d ~/.clod/images/mine
  # nor while a container uses one of its images
  docker rm -f clod-test-rm >/dev/null 2>&1 || true
  docker create --name clod-test-rm clod-other.mine >/dev/null
  exits 1 clod --force image rm mine 2>&1 | has 'a container uses other+mine'
  docker rm clod-test-rm >/dev/null
  printf 'y\n' | script -qec 'clod image rm mine' /dev/null > out
  has 'removed other+mine' < out
  has 'removed ~/.clod/images/mine' < out
  test ! -e ~/.clod/images/mine
  if docker image inspect clod-other.mine >/dev/null 2>&1; then false; fi
  docker image inspect clod-other >/dev/null
  # yours named as a bundled one: the bundled one takes its place
  clod --force image rm go other | has -x 'the bundled go takes its place'
  clod image | has '^  go  *-  *bundled$'
}

test_image_clean() {
  mkdir -p ~/.clod/images/gone ~/.clod/images/top ~/.clod/images/a-very-long-variant-name
  printf 'ARG BASE=clod\nFROM $BASE\nLABEL test=%s\n' gone > ~/.clod/images/gone/Dockerfile
  printf 'ARG BASE=clod\nFROM $BASE\nLABEL test=%s\n' top > ~/.clod/images/top/Dockerfile
  printf 'FROM clod\n' > ~/.clod/images/a-very-long-variant-name/Dockerfile
  clod -i gone+top image build
  clod -i top image build
  clod __complete image clean '' | has -x gone+top
  if clod __complete image clean gone '' | grep -qx gone; then false; fi
  clod image | has '^  a-very-long-variant-name  -'
  exits 1 clod -i no-such image clean
  exits 1 clod image clean no-such
  exits 1 clod image clean gone no-such
  docker image inspect clod-gone >/dev/null
  # gone+top is built on gone; a name wins over -i
  clod -i top image clean gone | has '^removed .*gone'
  if docker image inspect clod-gone >/dev/null 2>&1; then false; fi
  docker image inspect clod-top >/dev/null
  clod -i top image clean | has -x 'removed top'
  clod image | has '^  gone  *-'
  rm -r ~/.clod/images/gone
  clod image | has '^  gone+top  *built  *gone + top (no Dockerfile)'
  clod image clean gone+top | has -x 'removed gone+top'
  if clod image | grep -q gone; then false; fi
}

# image prune removes the stale images, those built on others first, and keeps the
# rest.
test_image_prune() {
  mkdir -p ~/.clod/images/keep ~/.clod/images/old
  printf 'ARG BASE=clod\nFROM $BASE\nLABEL test=%s\n' keep > ~/.clod/images/keep/Dockerfile
  printf 'ARG BASE=clod\nFROM $BASE\nLABEL test=%s\n' old > ~/.clod/images/old/Dockerfile
  clod -i keep image build
  clod -i old+keep image build
  clod image prune
  test "$(clod image prune)" = 'clod: no stale images'
  echo 'LABEL changed=1' >> ~/.clod/images/old/Dockerfile
  clod image | has '^  old+keep  *stale'
  test "$(clod image prune)" = "$(printf 'removed old+keep\nremoved old')"
  docker image inspect clod-keep >/dev/null
  clod image | has '^  keep  *built'
  clod image | has '^  old  *-'
  if clod image | grep -q 'old+keep'; then false; fi
  # an image a container uses, even a stopped one, stays, and shows as in use
  docker rm -f clod-test-in-use >/dev/null 2>&1 || true
  docker create --name clod-test-in-use clod-keep >/dev/null
  echo 'LABEL changed=1' >> ~/.clod/images/keep/Dockerfile
  clod image | has '^  keep  *stale, in use  '
  clod image | has '^in use '
  test "$(clod image prune)" = 'kept keep: a container uses it (docker ps -a lists them)'
  exits 1 clod image clean keep
  docker image inspect clod-keep >/dev/null
  docker rm clod-test-in-use >/dev/null
  test "$(clod image prune)" = 'removed keep'
}

# Prints clod __complete's candidates for words $@, without their descriptions.
completes() {
  clod __complete "$@" | cut -f1
}

# Writes a project with a devcontainer in directory $1: the default one on
# Ubuntu, whose user ubuntu has claude's uid once built, and devcontainer:py,
# built from a Dockerfile, whose user vscode starts at uid 1500.
devcontainer_project() {
  mkdir -p "$1/.devcontainer/py"
  cat > "$1/.devcontainer/devcontainer.json" <<'EOF'
{
  // JSON with comments, which clod never reads
  "image": "ubuntu:24.04",
  "containerEnv": { "FROM_DC": "yes", "EDITOR": "nano" },
  "remoteUser": "ubuntu"
}
EOF
  printf '{ "build": { "dockerfile": "Dockerfile" }, "remoteUser": "vscode" }\n' \
    > "$1/.devcontainer/py/devcontainer.json"
  printf '%s\n' 'FROM debian:trixie-slim' \
    'RUN useradd -m -u 1500 vscode && mkdir /opt/tool && chown vscode /opt/tool' 'USER vscode' \
    > "$1/.devcontainer/py/Dockerfile"
}

# The devcontainer image names, their errors, env and completion, which need
# neither the devcontainer CLI nor a build.
test_devcontainer_names() {
  local nocli d here
  devcontainer_project proj
  cd proj
  # (with a note when the devcontainer CLI isn't installed, checked below)
  clod env | has '^devcontainer: .*/proj/.devcontainer/devcontainer.json (clod -i devcontainer runs it)'
  clod -i devcontainer env | has '^image: *devcontainer (.*/proj/.devcontainer/devcontainer.json)$'
  if clod -i devcontainer env | has '^devcontainer:'; then false; fi
  clod -i devcontainer:py+sudo env |
    has '^image: *devcontainer:py+sudo (.*/proj/.devcontainer/py/devcontainer.json + .*/images/sudo)$'
  exits 1 clod -i devcontainer:nope bash -c true 2>&1 |
    has -x "clod: no devcontainer named 'nope' in $PWD (it has: py)"
  exits 1 clod -i go+devcontainer env 2>&1 | has -x 'clod: a devcontainer goes first in a combination, as devcontainer+go'
  exits 1 clod -s -i devcontainer bash -c true 2>&1 | has -x 'clod: a scratch workspace has no devcontainer; name one by its path, as devcontainer:PATH'
  exits 1 clod -w vol:dcvol -i devcontainer bash -c true 2>&1 | has -x 'clod: a volume workspace has no devcontainer; name one by its path, as devcontainer:PATH'
  # one the workspace hasn't is an error only for what needs it
  (cd .. && clod -i devcontainer env | has '^image: *devcontainer (no devcontainer in ')
  (cd .. && clod -i devcontainer home >/dev/null)
  (cd .. && exits 1 clod -i devcontainer bash -c true)
  mv .devcontainer/devcontainer.json default.json
  exits 1 clod -i devcontainer bash -c true 2>&1 |
    has -x "clod: $PWD has several devcontainers; choose one: devcontainer:py"
  clod env | has '^devcontainer: *devcontainer:py (clod -i devcontainer:NAME runs one)'
  exits 1 clod -i devcontainer:./ bash -c true 2>&1 |
    has -x "clod: $PWD has several devcontainers; choose one: devcontainer:./.devcontainer/py"
  mv default.json .devcontainer/devcontainer.json
  # one anywhere, such as below the workspace, by its path: a project, a config
  # folder or file; any workspace, scratch included, can run it
  here=$PWD
  (cd .. && clod -i devcontainer:proj/ env | has "^image: *devcontainer:proj/ ($here/.devcontainer/devcontainer.json)\$")
  (cd .. && clod -i devcontainer:./proj/.devcontainer/py+sudo env |
    has "^image: *devcontainer:./proj/.devcontainer/py+sudo ($here/.devcontainer/py/devcontainer.json + .*/images/sudo)\$")
  (cd .. && clod -s -i devcontainer:proj/.devcontainer/py/devcontainer.json env |
    has "^image: *devcontainer:proj/.devcontainer/py/devcontainer.json ($here/.devcontainer/py/devcontainer.json)\$")
  (cd .. && exits 1 clod -i devcontainer:nope/ bash -c true 2>&1 |
    has -x "clod: no devcontainer at ${here%/*}/nope: no such file or folder")
  # not a variant
  exits 2 clod image new devcontainer
  exits 1 clod image new mine devcontainer 2>&1 | has 'clod -i devcontainer+mine$'
  exits 1 clod image edit devcontainer 2>&1 | has "edit that: $PWD/.devcontainer/devcontainer.json$"
  exits 1 clod -i devcontainer+sudo image edit 2>&1 | has 'clod image edit sudo$'
  exits 1 clod image rm devcontainer 2>&1 | has 'clod image clean devcontainer removes its built image$'
  completes -i '' | has -x devcontainer
  completes -i '' | has -x devcontainer:py
  if completes image new mine '' | grep -q devcontainer; then false; fi
  # bash splits words at :, as in vol:NAME
  for sh in bash zsh; do
    [[ $sh == bash ]] || command -v zsh >/dev/null || continue
    "$repo/test/tab-complete.py" "$sh" 'clod -i devcontainer:p' 'clod --image=devcontainer:p' |
      diff - <(printf '%s\n' 'clod -i devcontainer:py' 'clod --image=devcontainer:py')
  done
  # devcontainer:PATH: the subdirectories that have one, then the folders and
  # config files in the path typed, with no space after a folder
  (cd .. && completes -i '' | has -x devcontainer:proj/)
  (cd .. && completes -i devcontainer: | has -x devcontainer:proj/)
  (cd .. && completes -i devcontainer:proj/. | has -x devcontainer:proj/.devcontainer/)
  (cd .. && completes -i devcontainer:proj/.devcontainer/ | has -x devcontainer:proj/.devcontainer/py/)
  (cd .. && completes -i devcontainer:proj/.devcontainer/ | has -x devcontainer:proj/.devcontainer/devcontainer.json)
  for sh in bash zsh; do
    [[ $sh == bash ]] || command -v zsh >/dev/null || continue
    (cd .. && "$repo/test/tab-complete.py" --mark "$sh" 'clod -i devcontainer:pro' \
      'clod -i devcontainer:proj/.devcontainer/py/d' 'clod -i devcontainer:proj/+su') |
      diff - <(printf '%s\n' 'clod -i devcontainer:proj/%' \
        'clod -i devcontainer:proj/.devcontainer/py/devcontainer.json %' 'clod -i devcontainer:proj/+sudo %')
  done
  # without the devcontainer CLI: a build says how to get it, and auto runs
  # the image it would otherwise
  nocli=''
  while IFS= read -r d; do
    [[ -x $d/devcontainer ]] || nocli+=${nocli:+:}$d
  done < <(tr : '\n' <<<"$PATH")
  PATH=$nocli command -v docker >/dev/null
  exits 1 env PATH="$nocli" clod -i devcontainer image build 2>&1 |
    has -x 'clod: devcontainer images need the devcontainer CLI on the host: npm install -g @devcontainers/cli'
  CLOD_DEVCONTAINER=auto PATH=$nocli clod env 2>&1 | tee out
  has '^image: *clod$' < out
  has "the devcontainer CLI isn't installed (npm install -g @devcontainers/cli)$" < out
  has "^devcontainer: .*(clod -i devcontainer runs it); the devcontainer CLI isn't installed$" < out
  exits 1 env CLOD_DEVCONTAINER=maybe clod env
}

# Tab completion: clod __complete's candidates and their descriptions, and the
# shim it prints, typed into bash and (if installed) zsh. Needs no Docker.
test_completion() {
  mkdir -p ~/.clod/homes/work ~/.clod/images/plain
  printf 'FROM clod\n' > ~/.clod/images/plain/Dockerfile
  test "$(completes --sk)" = --skip-build
  # both forms of an option after -, each with the description; long ones
  # only after --
  completes - | has -x -- -i
  clod __complete - | has -xF -e "$(printf -- '--image\tthe image or variant to run, or a+b (CLOD_IMAGE)')"
  clod __complete - | has -xF -e "$(printf -- '-i\tthe image or variant to run, or a+b (CLOD_IMAGE)')"
  completes -- | has -x -- --image
  if completes -- | grep -qx -- -i; then false; fi
  # the nouns and their verbs; build and rebuild only after image
  test "$(completes i)" = "$(printf 'image\ninstall')"
  test "$(completes u)" = "$(printf 'uninstall\nupdate')"
  # in command_table's order, with its descriptions
  test "$(completes '' | head -5)" = "$(printf 'claude\ncodex\nbash\nzsh\nimage')"
  clod __complete '' | has -xF -e "$(printf 'claude\tClaude Code')"
  clod __complete image '' | has -xF -e "$(printf 'rm\tdelete your variants and their built images')"
  clod __complete --sk | has -xF -e "$(printf -- '--skip-build\trun the image as built, even if its files changed')"
  clod __complete default '' | has -xF -e "$(printf 'ports\tports to publish on localhost, comma-separated')"
  test "$(completes default ports-busy '')" = "$(printf 'skip\nnext\nerror\n--reset')"
  clod __complete default command '' | has -xF -e "$(printf -- '--reset\tremove this default')"
  # no descriptions for names
  if clod __complete -i '' | grep -q $'\t'; then false; fi
  # help takes a command, and a noun's verb
  test "$(completes help im)" = image
  test "$(completes help image pr)" = prune
  test -z "$(completes help env '')"
  test -z "$(completes uninstall '')"
  if completes '' | grep -qxE 'build|rebuild'; then false; fi
  test "$(completes image '')" = "$(printf 'show\nnew\nedit\ndiff\nrm\nbuild\nrebuild\nclean\nprune')"
  test "$(completes image re)" = rebuild
  test "$(completes home '')" = "$(printf 'new\ncp\nmv\nrm')"
  test -z "$(completes home new '')"
  if completes home new ./x; then false; fi
  test "$(completes workspace '')" = rm
  test "$(completes shared '')" = "$(printf 'new\ndiff\nedit')"
  test -z "$(completes shared new '')"
  test -z "$(completes image prune '')"
  completes image show '' | has -x plain
  test -z "$(completes image show plain '')"
  completes image build '' | has -x plain
  completes image rebuild go '' | has -x plain
  if completes image build plain '' | grep -qx plain; then false; fi
  completes -i '' | has -x go
  completes -i '' | has -x clod
  test "$(completes -i go+su)" = go+sudo
  # after +: not a variant already there, nor one built FROM clod
  if completes -i go+ | grep -qxE 'go\+(go|plain)'; then false; fi
  completes -H w | has -x work
  test -z "$(completes -H ./w)"
  # bash splits words at colons
  completes -H vol : work '' | has -x claude
  completes -P 3000 : 5173 '' | has -x claude
  test "$(completes default co)" = command
  completes default command '' | has -x codex
  completes image new mine '' | has -x go
  if completes image new mine '' | grep -qx clod; then false; fi
  test -z "$(completes image new mine go '')"
  completes image edit '' | has -x plain
  if completes image edit '' | grep -qxE 'clod|go'; then false; fi
  test "$(completes image edit plain '')" = Dockerfile
  test -z "$(completes image edit plain Dockerfile '')"
  # after a command, the options on its page and -h, with the page's
  # description; the arguments around them complete as without them
  test "$(completes image edit -)" = "$(printf -- '--build\n-h\n--help')"
  clod __complete home rm - | has -xF -e "$(printf -- '--force\tdelete without asking; needed without a terminal')"
  completes default ports-busy - | has -x -- --reset
  completes image edit --build '' | has -x plain
  test "$(completes image edit -i go plain '')" = Dockerfile
  completes image build -i '' | has -x go
  completes env --home=w | has -x -- --home=work
  test -z "$(completes image edit -- -)"
  # exit status 1: the word is a file name, which the shell completes
  if completes claude -; then false; fi
  if completes claude --re; then false; fi
  if completes -- ''; then false; fi
  if completes -H ./w; then false; fi
  # a word starting with . or ~ is a path, never a name; a name that matches
  # nothing completes to nothing, not to files
  if completes -H .; then false; fi
  if completes -H '~'; then false; fi
  if completes --home='~'; then false; fi
  if completes default home .; then false; fi
  if completes home cp '~'; then false; fi
  if completes home new .; then false; fi
  test -z "$(completes -H xyz)"
  if completes install ''; then false; fi
  if completes -w ''; then false; fi
  test "$(completes --wor)" = --workspace
  test -z "$(completes -P '')"
  completes -P ''
  # The shim, and the files install links, in real shells, which split words
  # differently: bash at = and :, zsh not at all. A stand-in docker lists the
  # volumes. Directories complete with a / in bash only.
  mkdir proj bin .hdir
  printf '%s\n' '#!/bin/bash' \
    '[[ "$1 $2" == "volume ls" ]] && printf "%s\n" clod-home-vhome clod-workspace-play' > bin/docker
  chmod +x bin/docker
  PATH=$PWD/bin:$PATH completes home rm '' | has -x vol:vhome
  PATH=$PWD/bin:$PATH completes home rm '' | has -x work
  # a home named already isn't offered again
  PATH=$PWD/bin:$PATH completes home rm vol:vhome '' > out
  has -x work < out
  if grep -qx vol:vhome out; then false; fi
  # home cp and mv: a home, then a new one, which only a path completes
  PATH=$PWD/bin:$PATH completes home cp '' | has -x work
  PATH=$PWD/bin:$PATH completes home mv '' | has -x vol:vhome
  test -z "$(PATH=$PWD/bin:$PATH completes home cp work '')"
  if completes home cp ./w; then false; fi
  if completes home mv work ./w; then false; fi
  PATH=$PWD/bin:$PATH completes workspace rm '' | has -x play
  PATH=$PWD/bin:$PATH completes workspace rm vol : '' | has -x play
  test "$(PATH=$PWD/bin:$PATH completes workspace rm vo)" = vol:play
  test -z "$(PATH=$PWD/bin:$PATH completes workspace rm vol:play '')"
  for sh in bash zsh bash:files zsh:files; do
    [[ $sh == bash* ]] || command -v zsh >/dev/null || continue
    files=()
    [[ $sh == *:files ]] && files=(--files "$repo/completions")
    PATH=$PWD/bin:$PATH "$repo/test/tab-complete.py" ${files[@]+"${files[@]}"} "${sh%:*}" 'clod -i go+su' 'clod --image=go+su' \
      'clod --home=wo' 'clod -H vol:vh' 'clod --home=vol:vh' 'clod --workspace=vol:pl' \
      'clod -w pro' 'clod --workspace=pro' 'clod claude pro' 'clod image sh' 'clod shared d' \
      'clod home rm vol:vh' 'clod workspace rm pl' 'clod workspace rm vol:pl' \
      'clod workspace rm vo' 'clod home cp wo' 'clod home mv vol:vh' 'clod home rm wo' 'clod -H .hd' > out
    sed 's|/$||' out | diff - <(printf '%s\n' 'clod -i go+sudo' 'clod --image=go+sudo' \
      'clod --home=work' 'clod -H vol:vhome' 'clod --home=vol:vhome' 'clod --workspace=vol:play' \
      'clod -w proj' 'clod --workspace=proj' 'clod claude proj' 'clod image show' 'clod shared diff' \
      'clod home rm vol:vhome' 'clod workspace rm play' 'clod workspace rm vol:play' \
      'clod workspace rm vol:play' 'clod home cp work' 'clod home mv vol:vhome' 'clod home rm work' 'clod -H .hdir')
  done
  # zsh lists the descriptions beside the words, in command_table's order;
  # names have none
  command -v zsh >/dev/null || return 0
  for files in '' "$repo/completions"; do
    "$repo/test/tab-complete.py" ${files:+--files "$files"} --list zsh 'clod image ' 'clod -i ' 'clod -' > out
    has -E '^rm +-- delete your variants and their built images' < out
    has -E '^clean +-- remove built images, keeping their variants' < out
    # the two forms of an option on one line
    has -E '^--image +-i +-- the image or variant to run' < out
    test "$(grep -oE '^(show|prune) ' out | tr -d ' ' | tr '\n' ' ')" = 'show prune '
    if grep -E '(go|python) +--' out; then false; fi
  done
}

# Puts stand-ins for zsh and bash first on PATH, in directory fake. Run by
# install as interactive login shells (-lic), they skip the startup files:
# zsh has a completion system when FAKE_FPATH is set, with those directories
# on $fpath, and bash has bash-completion 2 when FAKE_BASH_COMPLETION is set.
# Otherwise they are the real shells.
fake_shells() {
  local zsh bash
  zsh=$(command -v zsh) bash=$(command -v bash)
  mkdir -p fake
  cat > fake/zsh <<EOF
#!/bin/bash
[[ \$1 == -lic ]] || exec $zsh "\$@"
[[ -n \${FAKE_FPATH+set} ]] && set -- "\$1" "compdef() { :; }; fpath=(\$FAKE_FPATH); \$2"
exec $zsh -f -c "\$2"
EOF
  cat > fake/bash <<EOF
#!/bin/bash
[[ \$1 == -lic ]] || exec $bash "\$@"
[[ -n \$FAKE_BASH_COMPLETION ]] && set -- "\$1" "_comp_load() { :; }; \$2"
exec $bash --norc --noprofile -c "\$2"
EOF
  chmod +x fake/zsh fake/bash
  export PATH=$PWD/fake:$PATH
}

# update pulls clod's checkout, asking first to switch to master when it's on
# another branch, and staying there without a terminal. Needs no Docker.
test_update() {
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  git init -q -b master origin
  cp "$repo/clod" origin/
  git -C origin add clod
  git -C origin commit -qm one
  git clone -q origin src
  src/clod update | has -x 'clod .* is up to date'
  git -C src checkout -q -b feature
  git -C origin commit -q --allow-empty -m two
  # no terminal: stays on the branch, whose pull fails without an upstream
  exits 1 src/clod update < /dev/null 2> out
  has 'is on branch feature, not master' < out
  has -x 'clod: staying on branch feature' < out
  test "$(git -C src branch --show-current)" = feature
  printf 'n\n' | script -qec 'src/clod update' /dev/null > out || true
  has 'Switch to master before pulling' < out
  test "$(git -C src branch --show-current)" = feature
  printf 'y\n' | script -qec 'src/clod update' /dev/null > out
  has 'clod updated to .*, 1 change:' < out
  test "$(git -C src branch --show-current)" = master
  # a detached HEAD
  git -C src checkout -q --detach
  printf 'y\n' | script -qec 'src/clod update' /dev/null > out
  has 'is at a detached HEAD, not master' < out
  test "$(git -C src branch --show-current)" = master
}

# install and uninstall, in a HOME of their own, with PATH holding only the
# directories here and the system's commands. Needs no Docker.
# shellcheck disable=SC2088 # clod shows $HOME as ~
test_install() {
  command -v zsh >/dev/null
  export HOME=$PWD/home XDG_DATA_HOME=$PWD/xdg SHELL=/bin/zsh
  unset BASH_COMPLETION_USER_DIR FAKE_FPATH FAKE_BASH_COMPLETION
  mkdir -p "$HOME/bin" zfn ro elsewhere
  chmod a-w ro
  export PATH=$HOME/.local/bin:$HOME/bin:/usr/bin:/bin
  fake_shells
  # the first install dir on PATH that exists: ~/bin; run through a link, it
  # links the real script
  ln -s "$repo/clod" via
  ./via install > out
  test "$(readlink "$HOME/bin/clod")" = "$repo/clod"
  # no completion system in either shell: the eval line, for zsh's file
  has -F 'add this line to ~/.zshrc' < out
  has -F 'eval "$(clod completion)"' < out
  test ! -e zfn/_clod
  # zsh's first writable $fpath directory, and bash-completion's under
  # XDG_DATA_HOME; then no eval line
  FAKE_FPATH="$PWD/ro $PWD/zfn" FAKE_BASH_COMPLETION=1 clod install > out
  test "$(readlink zfn/_clod)" = "$repo/completions/_clod"
  test "$(readlink xdg/bash-completion/completions/clod)" = "$repo/completions/clod.bash"
  test ! -e ro/_clod
  has -F '~/bin/clod is installed already' < out
  if grep -q eval out; then false; fi
  # again: all installed already
  FAKE_FPATH="$PWD/zfn" FAKE_BASH_COMPLETION=1 clod install > out
  test "$(grep -c 'installed already' out)" = 3
  # BASH_COMPLETION_USER_DIR's first directory
  BASH_COMPLETION_USER_DIR=$PWD/bc1:$PWD/bc2 FAKE_BASH_COMPLETION=1 clod install >/dev/null
  test "$(readlink bc1/completions/clod)" = "$repo/completions/clod.bash"
  # only a read-only $fpath directory: the eval line, unless bash is the login
  # shell and has it
  FAKE_FPATH=$PWD/ro clod install | has -F 'eval "$(clod completion)"'
  if SHELL=/bin/bash FAKE_FPATH=$PWD/ro FAKE_BASH_COMPLETION=1 clod install | grep -q eval; then false; fi
  # a directory off PATH: the PATH line, for the login shell's file
  SHELL=/bin/bash clod install "$PWD/elsewhere" > out
  test "$(readlink elsewhere/clod)" = "$repo/clod"
  has -F 'add this line to ~/.bashrc' < out
  has -F "export PATH=\"$PWD/elsewhere:\$PATH\"" < out
  # someone else's files: refused, then replaced with --force
  mkdir taken
  touch taken/clod
  exits 1 clod install "$PWD/taken" 2>&1 | has 'taken/clod already exists; clod install --force replaces it'
  test ! -L taken/clod
  clod install "$PWD/taken" --force >/dev/null
  test "$(readlink taken/clod)" = "$repo/clod"
  mkdir zfn2
  touch zfn2/_clod
  FAKE_FPATH=$PWD/zfn2 exits 1 clod install > out 2>&1
  has -F 'zfn2/_clod already exists' < out
  has -F 'eval "$(clod completion)"' < out
  FAKE_FPATH=$PWD/zfn2 clod --force install >/dev/null
  test "$(readlink zfn2/_clod)" = "$repo/completions/_clod"
  # with no install dir on PATH: ~/.local/bin, created
  HOME=$PWD/home2 PATH=$PWD/fake:/usr/bin:/bin "$repo/clod" install > out
  test "$(readlink home2/.local/bin/clod)" = "$repo/clod"
  has -F 'export PATH="$HOME/.local/bin:$PATH"' < out
  # uninstall: our links on PATH, in install's dirs, on $fpath and in
  # bash-completion's directory; not a file or someone else's link there
  rm zfn2/_clod
  touch zfn2/_clod
  mkdir -p "$HOME/.local/bin"
  ln -s /bin/true "$HOME/.local/bin/clod"
  PATH=$PATH:$PWD/elsewhere:$PWD/taken FAKE_FPATH="$PWD/zfn $PWD/zfn2" "$repo/clod" uninstall > out
  for f in ~/bin/clod elsewhere/clod taken/clod zfn/_clod xdg/bash-completion/completions/clod; do
    test ! -e "$f" && test ! -L "$f"
  done
  test "$(grep -c '^clod: removed' out)" = 5
  test "$(readlink "$HOME/.local/bin/clod")" = /bin/true
  test -f zfn2/_clod
  has -F '~/.clod: your homes' < out
  # nothing left to remove
  FAKE_FPATH=$PWD/zfn "$repo/clod" uninstall | has -F "found no links to $repo to remove"
}

# Homebrew's docker on macOS has no buildx, so clod's builds there use the
# classic builder; the base image, and a variant on top of another through
# BASE, must build without BuildKit.
test_classic() {
  DOCKER_BUILDKIT=0 docker build -q -t clod-classic "$repo"
  DOCKER_BUILDKIT=0 docker build -q --build-arg BASE=clod-classic "$repo/images/sudo"
}

# Builds the base on an image like a devcontainer's: Ubuntu, a user of its own
# at claude's uid, GitHub's apt repository under another key path (as the
# github-cli feature adds it), ending as that user. claude shares the uid,
# resolves first, and keeps the image's ENV; a base without apt-get is refused
# at once.
test_other_base() {
  cat > Dockerfile <<'EOF'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y curl \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo 'deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' \
       > /etc/apt/sources.list.d/github-cli.list
RUN mkdir /workspace
ENV FROM_BASE=1
USER ubuntu
EOF
  docker build -q -t clod-test-ubuntu . >/dev/null
  docker build -q -t clod-test-on-ubuntu --build-arg BASE=clod-test-ubuntu \
    --build-arg CLOD_UID=1000 --build-arg CLOD_GID=1000 "$repo" >/dev/null
  docker run --rm --entrypoint bash clod-test-on-ubuntu -c '
    set -e
    test "$(whoami)" = claude && test "$(id -gn)" = claude && test ~ = /home/claude
    test "$(getent passwd 1000 | cut -d: -f1)" = claude && test "$(getent group 1000 | cut -d: -f1)" = claude
    test "$(getent passwd ubuntu | cut -d: -f3)" = 1000 && test -O /home/ubuntu
    test "$(head -1 /etc/passwd | cut -d: -f1)" = root
    test -O /workspace && test "$FROM_BASE" = 1
    git --version; node --version; gh --version | head -1
  '
  docker rmi -f clod-test-on-ubuntu clod-test-ubuntu >/dev/null
  if docker build --build-arg BASE=alpine:3.22 "$repo" > out 2>&1; then false; fi
  has "clod's image needs a Debian or Ubuntu base" < out
}

# Builds devcontainers with the devcontainer CLI, with the base on top: their
# users take claude's ids, their containerEnv fills in variables, a variant can
# go on top, and a change beside the config makes one stale. CLOD_DEVCONTAINER
# auto runs one unless an image is chosen; image prune removes one whose
# config has gone.
test_devcontainer() {
  devcontainer_project proj
  cd proj
  clod -i devcontainer bash -c '
    set -e
    test "$(whoami)" = claude && test "$(id -u)" = "'"$(id -u)"'"
    test "$(id -u ubuntu)" = "$(id -u)" && test -O /home/ubuntu
    test "$FROM_DC" = yes && test "$EDITOR" = vim && test "$CLOD_IMAGE" = devcontainer
    grep -q "Ubuntu 24.04" /etc/os-release
    git --version; node --version; gh --version | head -1
  '
  clod image build devcontainer | has -x 'clod: devcontainer is up to date'
  # by its path, from above, it's the same image
  (cd .. && clod image build devcontainer:proj/ | has -x 'clod: devcontainer:proj/ is up to date')
  clod image | has "^  devcontainer  *built  *$PWD/.devcontainer/devcontainer.json\$"
  clod -i devcontainer:py+sudo bash -c '
    test "$(stat -c %u /opt/tool)" = "$(id -u)" && test "$(sudo -n whoami)" = root &&
      test "$CLOD_IMAGE" = devcontainer:py+sudo
  '
  clod image show devcontainer:py+sudo |
    has "^devcontainer:py  *built  *-  *$PWD/.devcontainer/py/devcontainer.json, then the base\$"
  echo '// changed' >> .devcontainer/devcontainer.json
  clod image show devcontainer | has '^devcontainer  *stale '
  CLOD_DEVCONTAINER=auto clod env | has '^image: *devcontainer '
  CLOD_DEVCONTAINER=auto clod -i sudo env | has '^image: *sudo '
  clod default devcontainer auto
  clod env | has '^image: *devcontainer '
  clod default devcontainer --reset
  completes image clean '' | has -x devcontainer:py
  clod image clean devcontainer:py+sudo devcontainer:py | has -x 'removed devcontainer:py'
  # one whose config has gone is stale, and image prune removes it
  mkdir -p ../gone/.devcontainer
  echo '{ "image": "debian:trixie-slim" }' > ../gone/.devcontainer/devcontainer.json
  (cd ../gone && clod image build devcontainer)
  mv ../gone ../moved
  clod image | has '^  devcontainer  *stale  .*/gone/.devcontainer/devcontainer.json (gone)$'
  clod image prune | grep -c '^removed devcontainer$' | has -x 2
  if clod image | grep -q '^  devcontainer '; then false; fi
}

# Builds variant (or combination) $1 and checks its tools in the container.
test_variant() {
  local check
  case $1 in
    browser)
      check='echo "<h1>clod</h1>" > /tmp/page.html &&
        chromium --headless --screenshot=/tmp/shot.png --window-size=800,600 file:///tmp/page.html &&
        test -s /tmp/shot.png && test -r /etc/clod/.claude/rules/browser.md' ;;
    dotnet) check='dotnet --version' ;;
    lamp) check='php -v && composer --version && apache2 -v && mariadb --version' ;;
    python) check='test "$UV_LINK_MODE" = copy && uv --version && gcc --version | head -1 && python3-config --includes' ;;
    rust) check='cargo new -q /tmp/hello && cd /tmp/hello && cargo run -q' ;;
    go+sudo) check='go version && test "$(sudo -n whoami)" = root && test -r /etc/clod/.claude/rules/sudo.md' ;;
  esac
  clod -i "$1" bash -c "set -e; $check"
}

# Collects the tests the arguments name, in the order given.
yes=''
selected=()
for arg in "$@"; do
  case $arg in
    -h|--help) usage; exit 0 ;;
    --list) list; exit 0 ;;
    -y|--yes) yes=1 ;;
    -*) echo "test/run.sh: unknown option $arg" >&2; usage >&2; exit 2 ;;
    *)
      if names=$(group_tests "$arg"); then
        # shellcheck disable=SC2206 # test names don't contain spaces or globs
        selected+=($names)
      elif [[ " ${all_tests//$'\n'/ } " == *" $arg "* ]]; then
        selected+=("$arg")
      else
        echo "test/run.sh: no test or group named '$arg' (test/run.sh --list)" >&2
        exit 2
      fi
      ;;
  esac
done
# shellcheck disable=SC2206 # test names don't contain spaces or globs
(( ${#selected[@]} )) || selected=($all_tests)

if [[ $OSTYPE != linux* ]]; then
  echo "test/run.sh: the tests need Linux (run them in a Linux VM)" >&2
  exit 1
fi
needs_docker=''
for t in "${selected[@]}"; do
  [[ $t == lint || $t == completion ]] || needs_docker=1
done
if [[ -n $needs_docker ]]; then
  if [[ -z $CI && -z $yes ]]; then
    echo "test/run.sh: the tests build, replace and prune clod images on the Docker they use, and" >&2
    echo "mount its socket into containers. Run them on a CI runner or a throwaway VM, with --yes." >&2
    exit 1
  fi
  if ! docker version >/dev/null 2>&1; then
    echo "test/run.sh: can't reach Docker" >&2
    exit 1
  fi
fi

# A fresh HOME, with clod installed on PATH as a user would install it. The
# Docker CLI keeps its config, and so its context.
work=$(mktemp -d)
export DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
export HOME=$work/home
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
while IFS= read -r v; do unset "$v"; done < <(compgen -v CLOD_)
# The default home, which a run without a terminal won't create.
mkdir -p "$HOME/.clod/homes/default"
"$repo/clod" install >/dev/null
if [[ $(readlink "$HOME/.local/bin/clod") != "$repo/clod" || $(command -v clod) != "$HOME/.local/bin/clod" ]]; then
  echo "test/run.sh: clod install didn't link $HOME/.local/bin/clod to $repo/clod" >&2
  exit 1
fi

# Reports that test $1 failed at line $2, from the test's own shell only.
fail_report() {
  [[ $BASHPID == "$test_shell" ]] || return 0
  echo "$1 failed at line $2:$(sed -n "$2p" "$repo/test/run.sh")" >&2
}

# Prints $1 seconds as 42s or 2m14s.
duration() {
  if (( $1 < 60 )); then echo "$1s"; else echo "$(($1 / 60))m$(($1 % 60))s"; fi
}

# Builds the base image, then the selected variants at once: their builds
# mostly wait on downloads, so they overlap well. The variant tests then find
# their images up to date, and a failed build fails its test there.
build_variants() {
  local t start=$SECONDS
  (
    cd "$work"
    clod image build >base-build.log 2>&1
    for t in "${selected[@]}"; do
      [[ $t == variant-* ]] && clod -i "${t#variant-}" image build >"$t-build.log" 2>&1 &
    done
    wait
  )
  echo "     variant builds ($(duration $((SECONDS - start))))"
}

# GitHub Actions folds each test's output into a group.
github=${GITHUB_ACTIONS:-}
failed=()
run_start=$SECONDS
built_variants=''
for t in "${selected[@]}"; do
  if [[ $t == variant-* && -z $built_variants ]]; then
    build_variants
    built_variants=1
  fi
  [[ -n $github ]] && echo "::group::$t"
  dir=$(mktemp -d "$work/$t.XXXX")
  start=$SECONDS
  (
    set -eEo pipefail
    # -E carries the trap into command substitutions and pipelines too, where a
    # command may fail without failing the test, so only the test's own shell
    # reports. The name is expanded now, since a test may have its own $t. The
    # trap stays on one line: LINENO counts on through a multi-line one.
    test_shell=$BASHPID
    trap 'fail_report "'"$t"'" "$LINENO"' ERR
    cd "$dir"
    case $t in
      variant-*) test_variant "${t#variant-}" ;;
      *) "test_${t//-/_}" ;;
    esac
  )
  status=$?
  took=$(duration $((SECONDS - start)))
  [[ -n $github ]] && echo "::endgroup::"
  if (( status )); then
    failed+=("$t")
    if [[ -n $github ]]; then echo "::error::$t failed ($took)"; else echo "FAIL $t ($took)"; fi
  else
    echo "ok   $t ($took)"
  fi
done

echo
took=$(duration $((SECONDS - run_start)))
if (( ${#failed[@]} )); then
  echo "${#failed[@]} of ${#selected[@]} failed in $took: ${failed[*]}"
  echo "(their directories and the home are in $work)"
  exit 1
fi
echo "all ${#selected[@]} passed in $took"
rm -rf "$work"
