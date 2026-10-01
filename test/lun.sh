#!/usr/bin/env bash
# End-to-end test of lode with a real lun: `lun_build` builds the published
# commit with the functions and graphs of its `lun.json` (and reports lun's
# diagnostics when a declared signature is wrong), `lun_call` calls a
# function and runs a graph of the ready build.
#
#   test/lun.sh [LUN_DIR] [LINEN_DIR]
#
# LUN_DIR is a lun checkout (default ../lun; >= 0.2.0, whose graphs are on
# linen's released `Control.Reactive`) and LINEN_DIR a linen checkout
# (default ../linen, >= 1.3.0) the test project depends on by path.
# Both lode and lun run in local mode (file:// repository, a path dependency on
# LINEN_DIR, the scripted model). Takes a few minutes: lun compiles a driver
# per build.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
lun_dir="$(cd "${1:-$root/../lun}" && pwd)"
linen="$(cd "${2:-$root/../linen}" && pwd)"
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
port="$(free_port)"; lun_port="$(free_port)"
work="$(mktemp -d "${TMPDIR:-/tmp}/lode-lun.XXXXXX")"
base="http://127.0.0.1:$port"

fail() { echo "FAIL: $*" >&2; echo "(work dir: $work)" >&2; exit 1; }
pass() { echo "ok - $*"; }

# ── A project for lun, in a bare repository ─────────────────────────────────
seed="$work/seed"
mkdir -p "$seed/lean/Demo"
cat > "$seed/lean/lakefile.toml" <<TOML
name = "demo"
defaultTargets = ["Demo"]

[[require]]
name = "linen"
path = "$linen"

[[lean_lib]]
name = "Demo"
TOML
cp "$root/lean-toolchain" "$seed/lean/lean-toolchain"
echo 'import Demo.Math' > "$seed/lean/Demo.lean"
cat > "$seed/lean/Demo/Math.lean" <<'LEAN'
import Lean.Data.Json
import Linen.Control.Monad.Effect
import Linen.Control.Monad.Effect.Trace

namespace Demo
open Control.Monad.Effect

/-- Twice its argument. -/
def double (n : Nat) : Eff [] Nat := pure (2 * n)

/-- The sum of its arguments, traced. -/
def add (a b : Nat) : Eff [Trace.Trace] Nat := do
  Trace.trace s!"adding {a} and {b}"
  pure (a + b)

/-- A pure sum for a graph run without caller-supplied effect authority. -/
def pureAdd (a b : Nat) : Eff [] Nat := pure (a + b)

/-- A constant source. -/
def seed : Unit → Eff [] Nat := fun _ => pure 10

end Demo
LEAN
lun_json() { # SIGNATURE-OF-DOUBLE
  jq -n --arg sig "$1" '{open: ["Demo"],
    functions: [{name: "double", module: "Demo.Math", function: "Demo.double", signature: $sig},
             {name: "add", module: "Demo.Math", function: "Demo.add", signature: "Nat → Nat → Eff [Trace.Trace] Nat"},
             {name: "pureAdd", module: "Demo.Math", function: "Demo.pureAdd", signature: "Nat → Nat → Eff [] Nat"},
            {name: "seed", module: "Demo.Math", function: "Demo.seed", signature: "Unit → Eff [] Nat"}],
    graphs: [{name: "main", program: "do\n  let x ← input \"x\" Nat\n  let s ← seed\n  let d ← double x\n  pureAdd d s"}]}'
}
lun_json "String → Eff [] Nat" > "$seed/lean/lun.json"   # wrong on purpose: lode fixes it
(cd "$seed/lean" && lake update >/dev/null 2>&1)
git -C "$seed" init -q -b main
printf '.lake/\n' > "$seed/.gitignore"
git -C "$seed" add -A
git -C "$seed" -c user.email=e2e@lode -c user.name=e2e -c commit.gpgsign=false commit -q -m seed
git clone -q --bare "$seed" "$work/remote.git"

# ── lun and lode ────────────────────────────────────────────────────────────
(cd "$lun_dir" && lake build lun >/dev/null)
(cd "$root" && lake build lode >/dev/null)
sdk="${LUN_LIAISON_SDK_PATH:-$lun_dir/.lake/packages/liaison}"
[ -f "$sdk/Liaison/Wire.lean" ] || fail "Liaison SDK missing at $sdk; build lun or set LUN_LIAISON_SDK_PATH"
LUN_WORKDIR="$work/lun" LUN_PORT="$lun_port" LUN_ALLOW_LOCAL=1 LUN_TOKEN=luntoken LUN_ID_SALT=e2e LUN_LIAISON_SDK_PATH="$sdk" \
  "$lun_dir/.lake/build/bin/lun" >"$work/lun.log" 2>&1 &
lun_pid=$!
LODE_WORKDIR="$work/lode" LODE_PORT="$port" LODE_ALLOW_LOCAL=1 LODE_TOKEN=secret \
  LODE_LUN_URL="http://127.0.0.1:$lun_port" LODE_LUN_TOKEN=luntoken \
  "$root/.lake/build/bin/lode" >"$work/lode.log" 2>&1 &
lode_pid=$!
trap 'kill $lode_pid $lun_pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -sf "$base/_health" >/dev/null && curl -sf "http://127.0.0.1:$lun_port/_health" >/dev/null && break; sleep 0.2; done
curl -sf "$base/_health" >/dev/null || fail "lode did not start"
pass "lode and lun are up"

api() {
  local out
  out="$(curl -s -o /dev/stdout -w '\n%{http_code}' -X "$1" -H 'Authorization: Bearer secret' \
    -H 'Content-Type: application/json' ${3:+--data-binary "$3"} "$base$2")"
  echo "$(tail -n1 <<<"$out") $(sed '$d' <<<"$out")"
}

good="$(lun_json "Nat → Eff [] Nat")"
script="$(jq -n --arg good "$good" '[
  {calls: [{name: "lun_build", arguments: {}}]},
  {calls: [{name: "write", arguments: {path: "lun.json", content: $good}},
           {name: "publish", arguments: {message: "Fix the signature of double"}}]},
  {calls: [{name: "lun_build", arguments: {}}]},
  {calls: [{name: "lun_call", arguments: {kind: "function", name: "double", body: {input: 21}}},
           {name: "lun_call", arguments: {kind: "function", name: "add", body: {input: [1, 2]}}},
           {name: "lun_call", arguments: {kind: "graph", name: "main", body: {inputs: {x: 5}}}}]},
  {text: "done"}]')"
r="$(api POST /v0/sessions "$(jq -n --arg url "file://$work/remote.git" --argjson script "$script" \
  '{source: {url: $url, branch: "main", path: "lean"}, model: {api: "scripted", script: $script}, message: "Build it."}')")"
[ "${r%% *}" = "201" ] || fail "create: $r"
id="$(jq -r .id <<<"${r#* }")"
after=0
for _ in $(seq 720); do
  r="$(api GET "/v0/sessions/$id/messages?after=$after&wait=10")"
  [ "$(jq -r .running <<<"${r#* }")" = "false" ] && break
  after="$(jq -r .next <<<"${r#* }")"
done
r="$(api GET "/v0/sessions/$id/messages")"
log="${r#* }"
results="$(jq -c '[.entries[] | select(.type == "tool_results") | .results[]]' <<<"$log")"
jq -e '.[0] | .isError == true and (.content | test(": failed")) and (.content | test("\\[function double\\]"))' <<<"$results" >/dev/null \
  || fail "the wrong signature is reported on the function: $(jq -r '.[0].content' <<<"$results")"
pass "lun_build reports lun's diagnostics, attributed to the function"
jq -e '.[2] | .isError == false and (.content | test("Published"))' <<<"$results" >/dev/null || fail "publish: $(jq -c '.[2]' <<<"$results")"
jq -e '.[3] | (.content | test(": ready")) and (.content | test("functions: double, add, pureAdd, seed"))' <<<"$results" >/dev/null \
  || fail "the fixed build is ready: $(jq -r '.[3].content' <<<"$results")"
pass "after a fix and a publish, the build is ready"
jq -e '.[4].content | fromjson | .output == 42' <<<"$results" >/dev/null || fail "double: $(jq -c '.[4]' <<<"$results")"
jq -e '.[5] | .isError == true and (.content | fromjson | .error | test("permission denied: Trace"))' <<<"$results" >/dev/null || fail "an unwarranted effect must be reported as a tool error: $(jq -c '.[5]' <<<"$results")"
pass "lun_call cannot mint effect authority; a denied Trace is an error result"
jq -e '.[6].content | fromjson | .nodes[-1].output == 20' <<<"$results" >/dev/null || fail "the graph: $(jq -c '.[6]' <<<"$results")"
pass "lun_call calls functions and runs the graph"
r="$(api GET "/v0/sessions/$id")"
jq -e '(.lastBuild | length) == 64' <<<"${r#* }" >/dev/null || fail "the status names the build"
pass "the session records the build"

echo "all passed"
[ -n "${LODE_E2E_KEEP:-}" ] && echo "(kept $work)" || rm -rf "$work"
