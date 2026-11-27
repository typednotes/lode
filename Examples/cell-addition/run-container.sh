#!/usr/bin/env bash
# Build a Linen worker with Lode and exercise it inside a disposable container.
set -euo pipefail

engine=podman
image=
output=
mode=scripted
model=gpt-6.2-sol
confirm=false
dry_run=false

usage() {
  cat <<'HELP'
Usage: Examples/cell-addition/run-container.sh [OPTIONS]

Publish an effect-free addition cell to a local bare repo, build its worker,
and call it over JSON-RPC. Prints the host directory with the repo and logs.

  --engine podman|docker  Container CLI (default: podman)
  --image IMAGE          Use an existing local Lode image with Linen 5
                         (default: build from this checkout)
  --output NEW_DIR       Keep results here (default: /tmp/lode-cell-container.XXXXXX)
  --live                 Send the task to OpenAI Responses using OPENAI_API_KEY
                         (default: scripted model)
  --model MODEL          Model for --live (default: gpt-6.2-sol)
  --yes                  Confirm paid inference for --live without a prompt
  --dry-run              Print the selected settings and exit
  -h, --help             Show this help

Examples:
  Examples/cell-addition/run-container.sh
  Examples/cell-addition/run-container.sh --engine docker --image localhost/lode:cell-demo
  Examples/cell-addition/run-container.sh --engine docker --live --yes

Set NO_COLOR or TERM=dumb for plain output.
HELP
}

error() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine|--image|--output|--model)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || error "$1 requires a value"
      case "$1" in
        --engine) engine=$2 ;;
        --image) image=$2 ;;
        --output) output=$2 ;;
        --model) model=$2 ;;
      esac
      shift 2
      ;;
    --live) mode=live; shift ;;
    --yes) confirm=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) error "unknown option $1 (see --help)" ;;
  esac
done
[[ "$engine" == podman || "$engine" == docker ]] || error "--engine must be podman or docker"

if [[ "$dry_run" == true ]]; then
  printf 'Engine: %s\nImage: %s\nModel: %s\nOutput: %s\n' \
    "$engine" "${image:-build from checkout}" \
    "$(if [[ "$mode" == live ]]; then printf '%s (paid API)' "$model"; else printf 'scripted'; fi)" \
    "${output:-/tmp/lode-cell-container.XXXXXX}"
  exit 0
fi

blue= green= red= reset=
if [[ -t 2 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR+x}" ]]; then
  blue=$'\033[1;36m'; green=$'\033[1;32m'; red=$'\033[1;31m'; reset=$'\033[0m'
fi

for tool in "$engine" git jq; do
  command -v "$tool" >/dev/null || error "install $tool before running the demo"
done
"$engine" info >/dev/null || error "start the $engine daemon or VM and retry"
if [[ "$mode" == live ]]; then
  [[ -n "${OPENAI_API_KEY:-}" ]] || error "set OPENAI_API_KEY for --live"
  if [[ "$confirm" != true ]]; then
    [[ -t 0 ]] || error "--live requires --yes when stdin is piped"
    printf 'Send this task to OpenAI model %s using paid inference? [y/N] ' "$model" >&2
    read -r reply
    [[ "$reply" == y || "$reply" == Y ]] || error "live run declined"
  fi
fi

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
umask 077
if [[ -n "$output" ]]; then
  mkdir -- "$output" || error "--output must name a new directory with an existing parent"
  work="$(cd "$output" && pwd -P)"
else
  work="$(mktemp -d /tmp/lode-cell-container.XXXXXX)"
fi

container=
stage=0
step() {
  stage=$((stage + 1))
  printf '%s[%d/6] %s%s\n' "$blue" "$stage" "$*" "$reset" >&2
}
pass() {
  printf '%s  PASS%s %s\n' "$green" "$reset" "$*" >&2
}
cleanup() {
  local status=$?
  if [[ -n "$container" ]]; then
    if ! "$engine" stop "$container" >"$work/stop.log" 2>&1; then
      printf '%sError%s stopping container %s. See %s/stop.log\n' "$red" "$reset" "$container" "$work" >&2
      status=1
    fi
  fi
  if (( status != 0 )); then
    printf '%s  FAIL%s Step %d. See %s\n' "$red" "$reset" "$stage" "$work" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step "Prepare the Lode image"
if [[ -z "$image" ]]; then
  mkdir "$work/image"
  cp "$repo"/{Dockerfile,lean-toolchain,lakefile.lean,lake-manifest.json,Main.lean,Lode.lean} "$work/image/"
  cp -R "$repo/Lode" "$work/image/"
  "$engine" build --iidfile "$work/image.id" "$work/image" 2>&1 | tee "$work/build.log" >&2
  image="$(cat "$work/image.id")"
else
  "$engine" image inspect "$image" >/dev/null
fi
pass "$image"

step "Start the disposable container"
container="$("$engine" run --rm --detach --pull=never --entrypoint /bin/sleep "$image" infinity)"
pass "${container:0:12}"

step "Seed the Lean project and its local bare Git repo"
"$engine" exec -i "$container" sh -e >"$work/seed.log" 2>&1 <<'SETUP'
cell_dir=/tmp/lode-cell
seed="$cell_dir/seed"
for linen in "$LODE_PACKAGE_CACHE"/linen/*; do
  if [ -f "$linen/Integration/CellContract.lean" ]; then
    break
  fi
done
test -f "$linen/Integration/CellContract.lean"
mkdir -p "$seed/LocalCell"
cp "$linen/lean-toolchain" "$seed/"
printf '.lake/\n' > "$seed/.gitignore"
sed 's/Integration\.CellContract/LocalCell.Contract/g' \
  "$linen/Integration/CellContract.lean" > "$seed/LocalCell/Contract.lean"
sed -e 's/Integration\.CellContract/LocalCell.Contract/g' \
  -e 's/fun (left, right) => pure (left + right)/fun _ => pure 0/' \
  "$linen/Integration/CellWorker.lean" > "$seed/LocalCell/Worker.lean"
grep -F 'private def add : addition.Run := fun _ => pure 0' "$seed/LocalCell/Worker.lean"

cat > "$seed/lakefile.toml" <<'TOML'
name = "local-addition"
defaultTargets = ["add-worker"]

[[lean_lib]]
name = "CellContract"
roots = ["LocalCell.Contract"]

[[lean_exe]]
name = "add-worker"
root = "LocalCell.Worker"
TOML
printf '\n[[require]]\nname = "linen"\npath = "%s"\n' "$linen" >> "$seed/lakefile.toml"
(cd "$seed" && lake update)
git -C "$seed" init -q -b main
git -C "$seed" add .
git -C "$seed" -c user.name=Demo -c user.email=demo@lode.example \
  -c commit.gpgsign=false commit -qm "Seed the addition cell"
git clone -q --bare "$seed" "$cell_dir/project.git"
SETUP
seed_commit="$("$engine" exec "$container" git -C /tmp/lode-cell/seed rev-parse HEAD)"
pass "Seed commit $seed_commit"

step "Have Lode implement, check, and publish the cell"
jq -n --arg mode "$mode" '{
  source: {url: "file:///tmp/lode-cell/project.git", branch: "main"},
  tools: ["read", "ls", "grep", "edit", "check", "publish"]
} + (if $mode == "scripted" then {
  model: {api: "scripted", script: [
    {calls: [{name: "edit", arguments: {
      path: "LocalCell/Worker.lean",
      old: "private def add : addition.Run := fun _ => pure 0",
      new: "def add : addition.Run := fun (left, right) => pure (left + right)\n\ntheorem add_correct (left right : Nat) : (add (left, right)).run = left + right := rfl"
    }}]},
    {calls: [{name: "check", arguments: {}}]},
    {calls: [{name: "publish", arguments: {message: "Implement and prove addition"}}]},
    {text: "Published the addition cell."}
  ]}
} else {} end)' >"$work/session.json"
"$engine" exec -i "$container" sh -c 'cat > /tmp/lode-cell/session.json' <"$work/session.json"
run_args=(exec -i)
if [[ "$mode" == live ]]; then
  run_args+=(--env LODE_MODEL_API_KEY --env LODE_MODEL_PROVIDER=openai
    --env LODE_MODEL_API=responses --env LODE_MODEL_BASE_URL=https://api.openai.com/v1
    --env "LODE_MODEL_NAME=$model")
fi
LODE_MODEL_API_KEY="${OPENAI_API_KEY:-}" "$engine" "${run_args[@]}" \
  "$container" lode run --config /tmp/lode-cell/session.json >"$work/answer.log" 2>"$work/progress.log" <<'TASK'
Implement the addition cell in LocalCell/Worker.lean. Make add public and
replace the stub with the sum of its two natural-number inputs. Keep the
effect-free Linen signature and JSON-RPC adapter. Prove in Lean that running
the cell returns the sum for every input pair. Run check until it builds
cleanly, then publish the change to this local branch.
TASK
session="$(awk '/^\[lode\] session / {print $3; exit}' "$work/progress.log")"
[[ -n "$session" ]] || error "Lode did not report a session ID"
published="$("$engine" exec "$container" git --git-dir=/tmp/lode-cell/project.git rev-parse main)"
[[ "$published" != "$seed_commit" ]] || error "Lode did not publish an implementation"
pass "Session $session published $published"

step "Build and call the worker"
"$engine" exec "$container" lode output "$session" --format executable --target add-worker \
  --output /tmp/lode-cell/built >"$work/receipt.json" 2>"$work/export.log"
worker="$(jq -er '.path' "$work/receipt.json")"
for inputs in '2 3 5' '0 8 8' '123456789 987654321 1111111110'; do
  read -r left right expected <<<"$inputs"
  printf '{"jsonrpc":"2.0","id":1,"method":"call","params":[%s,%s]}\n' "$left" "$right" |
    "$engine" exec -i "$container" "$worker" |
    tee -a "$work/calls.jsonl" |
    jq -e --argjson expected "$expected" '.id == 1 and .result == $expected' >/dev/null
  pass "$left + $right = $expected"
done

step "Copy the Git repository and worker to the host"
"$engine" cp "$container:/tmp/lode-cell/project.git" "$work/project.git"
"$engine" cp "$container:$worker" "$work/add-worker"
[[ "$(git --git-dir="$work/project.git" rev-parse main)" == "$published" ]] ||
  error "the copied repository does not contain the published commit"
pass "$work/project.git"
printf '%s\n' "$work"
