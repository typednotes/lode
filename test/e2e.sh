#!/usr/bin/env bash
# End-to-end test of lode, locally: a real agent loop over a real repository,
# with a scripted model (no network, no model): sessions, every file tool,
# `bash`, `check` (a real `lake build`), `publish` (a real push), steering,
# abort, the diff, persistence across a restart, authentication, and
# refusals.
#
#   test/e2e.sh
#
# Runs lode in local mode (LODE_ALLOW_LOCAL=1), which admits the file://
# repository and the `scripted` model. Needs git, jq, curl and the Lean
# toolchain of lean-toolchain (for the tiny project `check` builds). lun is
# not involved: `lun_build`/`lun_call` are exercised against lun by hand
# (see README.md).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
port="${LODE_E2E_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
work="$(mktemp -d /tmp/lode-e2e.XXXXXX)"
base="http://127.0.0.1:$port"
toolchain="$(cat "$root/lean-toolchain")"

fail() { echo "FAIL: $*" >&2; echo "(work dir: $work)" >&2; exit 1; }
pass() { echo "ok - $*"; }

# ── The shared repository: a bare remote with a tiny Lean project ───────────
seed="$work/seed"
mkdir -p "$seed/lean"
cat > "$seed/lean/lakefile.toml" <<'TOML'
name = "demo"
defaultTargets = ["Demo"]

[[lean_lib]]
name = "Demo"
TOML
echo "$toolchain" > "$seed/lean/lean-toolchain"
echo 'def Demo.answer : Nat := 42' > "$seed/lean/Demo.lean"
printf '# Demo\n\nKeep modules small.\n' > "$seed/AGENTS.md"
git -C "$seed" init -q -b main
git -C "$seed" add -A
git -C "$seed" -c user.email=e2e@lode -c user.name=e2e -c commit.gpgsign=false commit -q -m seed
git clone -q --bare "$seed" "$work/remote.git"
remote="file://$work/remote.git"

# ── lode ────────────────────────────────────────────────────────────────────
(cd "$root" && lake build lode >/dev/null)
start_lode() {
  LODE_WORKDIR="$work/lode" LODE_PORT="$port" LODE_ALLOW_LOCAL=1 LODE_TOKEN=secret LODE_MODEL_API_KEY=sk-leak \
    "$root/.lake/build/bin/lode" >>"$work/lode.log" 2>&1 &
  lode_pid=$!
  for _ in $(seq 50); do curl -sf "$base/_health" >/dev/null && return; sleep 0.2; done
  fail "lode did not start: $(cat "$work/lode.log")"
}
start_lode
trap 'kill $lode_pid 2>/dev/null || true' EXIT
pass "health"

api() { # METHOD PATH [BODY] -> prints "STATUS BODY"
  local out
  out="$(curl -s -o /dev/stdout -w '\n%{http_code}' -X "$1" -H 'Authorization: Bearer secret' \
    -H 'Content-Type: application/json' ${3:+--data-binary "$3"} "$base$2")"
  echo "$(tail -n1 <<<"$out") $(sed '$d' <<<"$out")"
}
expect() { # DESCRIPTION EXPECTED-STATUS JQ-FILTER "STATUS BODY"
  local status="${4%% *}" body="${4#* }"
  [ "$status" = "$2" ] || fail "$1: status $status, expected $2: $body"
  jq -e "$3" >/dev/null <<<"$body" || fail "$1: $3 does not hold for $body"
  pass "$1"
}
wait_idle() { # ID -> the whole log
  local r after=0
  for _ in $(seq 600); do
    r="$(api GET "/v0/sessions/$1/messages?after=$after&wait=5")"
    [ "$(jq -r .running <<<"${r#* }")" = "false" ] && { echo "$(api GET "/v0/sessions/$1/messages" | cut -d' ' -f2-)"; return; }
    after="$(jq -r .next <<<"${r#* }")"
  done
  fail "session $1 did not finish"
}
session() { # SCRIPT-JSON [PATH] -> id
  local r
  r="$(api POST /v0/sessions "$(jq -n --arg url "$remote" --argjson script "$1" --arg path "${2:-lean}" \
    '{source: {url: $url, branch: "main", path: $path}, model: {api: "scripted", script: $script}}')")"
  [ "${r%% *}" = "201" ] || fail "creating a session: $r"
  jq -r .id <<<"${r#* }"
}
result() { # LOG TOOL-CALL-INDEX -> that tool result (in order of appearance)
  jq -c "[.entries[] | select(.type == \"tool_results\") | .results[]][$2]" <<<"$1"
}

# ── Refusals ────────────────────────────────────────────────────────────────
r="$(curl -s -o /dev/null -w '%{http_code}' "$base/v0/sessions")"
[ "$r" = "401" ] || fail "no token: $r"; pass "no token is 401"
expect "a bad branch is refused" 400 '.error | test("branch")' \
  "$(api POST /v0/sessions "$(jq -n --arg url "$remote" '{source: {url: $url, branch: "a..b"}, model: {api: "scripted"}}')")"
expect "an http repository is refused" 400 '.error | test("https")' \
  "$(api POST /v0/sessions '{"source": {"url": "http://example.com/x/y", "branch": "main"}, "model": {"api": "scripted"}}')"
expect "no model is refused" 400 '.error | test("model")' \
  "$(api POST /v0/sessions "$(jq -n --arg url "$remote" '{source: {url: $url, branch: "main"}}')")"
expect "a missing branch is refused" 502 '.error | test("nope")' \
  "$(api POST /v0/sessions "$(jq -n --arg url "$remote" '{source: {url: $url, branch: "nope"}, model: {api: "scripted"}}')")"
expect "an unknown session is 404" 404 '.error' "$(api GET /v0/sessions/0123456789abcdef0123456789abcdef)"

# ── A full run: tools, check, publish ───────────────────────────────────────
script='[
  {"text": "Planning.", "calls": [
    {"name": "todo", "arguments": {"todos": [{"content": "write Hello", "status": "in_progress"}, {"content": "publish", "status": "pending"}]}},
    {"name": "write", "arguments": {"path": "Demo/Hello.lean", "content": "def Demo.hello : String := \"hi\"\n\ndef Demo.broken : Nat := \"no\"\n"}},
    {"name": "ls", "arguments": {}}]},
  {"calls": [
    {"name": "check", "arguments": {"targets": ["Demo.Hello"]}},
    {"name": "edit", "arguments": {"path": "Demo/Hello.lean", "old": "def Demo.broken : Nat := \"no\"", "new": "def Demo.fixed : Nat := 1"}},
    {"name": "check", "arguments": {"targets": ["Demo.Hello"]}}]},
  {"calls": [
    {"name": "read", "arguments": {"path": "Demo/Hello.lean"}},
    {"name": "grep", "arguments": {"pattern": "def Demo\\.[a-z]+"}},
    {"name": "bash", "arguments": {"command": "echo out; echo err >&2; exit 3"}},
    {"name": "edit", "arguments": {"path": "Demo/Hello.lean", "old": "nowhere", "new": "x"}}]},
  {"calls": [
    {"name": "write", "arguments": {"path": "../.git/config", "content": "x"}},
    {"name": "read", "arguments": {"path": "../../etc/passwd"}},
    {"name": "write", "arguments": {"path": ".lake/x", "content": "x"}},
    {"name": "nope", "arguments": {}},
    {"name": "bash", "arguments": "{not json"},
    {"name": "lun_build", "arguments": {}}]},
  {"calls": [{"name": "publish", "arguments": {"message": "Add Demo.Hello"}}]},
  {"calls": [{"name": "publish", "arguments": {"message": "again"}}]},
  {"text": "Done: Demo.hello is published."}
]'
id="$(session "$script")"
expect "the session is idle" 200 '.state == "idle" and .agent == "build" and (.workspace.remoteHead | length) == 40' \
  "$(api GET "/v0/sessions/$id")"
expect "a message starts a run" 202 '.queued == false' \
  "$(api POST "/v0/sessions/$id/messages" '{"text": "Write Demo.hello and publish it."}')"
log="$(wait_idle "$id")"
jq -e '.entries[0].type == "event" and .entries[0].kind == "run_started" and .entries[1].type == "user"' <<<"$log" >/dev/null \
  || fail "the log starts with the run and the message: $log"
jq -e '.entries[-1].kind == "run_finished"' <<<"$log" >/dev/null || fail "the run finished: $(jq -c '.entries[-1]' <<<"$log")"
pass "the run finished"
check_result() { # DESCRIPTION INDEX JQ-FILTER
  local x; x="$(result "$log" "$2")"
  jq -e "$3" >/dev/null <<<"$x" || fail "$1: $3 does not hold for $x"
  pass "$1"
}
check_result "todo" 0 '.isError == false and (.content | test("\\[~\\] write Hello"))'
check_result "write" 1 '.isError == false and (.content | test("to Demo/Hello.lean"))'
check_result "ls lists relative to the project" 2 '(.content | test("Demo/Hello.lean")) and (.content | test("lakefile.toml"))'
check_result "check reports the type error" 3 '.isError == true and (.content | test("Demo/Hello.lean:3:[0-9]+: error"))'
check_result "edit" 4 '.isError == false and (.content | test("Replaced 1 occurrence"))'
check_result "check succeeds after the fix" 5 '.isError == false and (.content | test("Build succeeded"))'
check_result "read numbers lines" 6 '.content | test("1\tdef Demo.hello")'
check_result "grep, paths relative to the project" 7 '.content | test("(^|\\n)Demo/Hello.lean:3:def Demo.fixed")'
check_result "bash reports the exit code and both streams" 8 '.isError == true and (.content | test("exit code 3")) and (.content | test("out")) and (.content | test("err"))'
check_result "edit refuses text that is not there" 9 '.isError == true and (.content | test("not found"))'
check_result ".git is off limits" 10 '.isError == true and (.content | test("may not be written"))'
check_result "leaving the workspace is refused" 11 '.isError == true and (.content | test("leaves the workspace"))'
check_result ".lake is off limits" 12 '.isError == true and (.content | test("may not be written"))'
check_result "an unknown tool" 13 '.isError == true and (.content | test("not available"))'
check_result "malformed arguments" 14 '.isError == true and (.content | test("not valid JSON"))'
check_result "lun_build without lun" 15 '.isError == true and (.content | test("no lun is configured"))'
check_result "publish" 16 '.isError == false and (.content | test("Published [0-9a-f]{40} on main"))'
check_result "nothing more to publish" 17 '.isError == true and (.content | test("nothing to publish"))'
head="$(git -C "$work/remote.git" rev-parse main)"
[ "$(git -C "$work/remote.git" log -1 --format=%s main)" = "Add Demo.Hello" ] || fail "the remote has the commit"
git -C "$work/remote.git" show main:lean/Demo/Hello.lean | grep -q 'def Demo.fixed' || fail "the remote has the edited file"
if git -C "$work/remote.git" ls-tree -r --name-only main | grep -q '\.lake/'; then fail "build outputs were published"; fi
pass "the remote has the published commit, without build outputs"
expect "the status follows the remote" 200 \
  ".workspace.remoteHead == \"$head\" and (.todos | length) == 2 and .state == \"idle\" and .error == null" \
  "$(api GET "/v0/sessions/$id")"

# ── The diff of unpublished changes ─────────────────────────────────────────
script='[{"calls": [{"name": "write", "arguments": {"path": "Notes.md", "content": "unpublished\n"}}]}, {"text": "ok"}]'
id2="$(session "$script")"
api POST "/v0/sessions/$id2/messages" '{"text": "note"}' >/dev/null
wait_idle "$id2" >/dev/null
diff="$(curl -s -H 'Authorization: Bearer secret' "$base/v0/sessions/$id2/diff")"
grep -q '+unpublished' <<<"$diff" || fail "the diff shows the change: $diff"
pass "diff"

# ── What the model runs cannot see lode's secrets or write through links ───
script='[
  {"calls": [{"name": "bash", "arguments": {"command": "echo \"token=[${LODE_TOKEN:-}] key=[${LODE_MODEL_API_KEY:-}]\"; ln -s /tmp outside; ln -s ../.git g; ln -s /etc etc-link"}}]},
  {"calls": [{"name": "write", "arguments": {"path": "outside/lode-escape", "content": "x"}},
             {"name": "write", "arguments": {"path": "g/hooks/pre-commit", "content": "x"}},
             {"name": "edit", "arguments": {"path": "g/config", "old": "[core]", "new": "[core]"}},
             {"name": "read", "arguments": {"path": "etc-link/hosts"}}]},
  {"text": "ok"}]'
id6="$(session "$script")"
api POST "/v0/sessions/$id6/messages" '{"text": "try"}' >/dev/null
log="$(wait_idle "$id6")"
check6() { local x; x="$(result "$log" "$2")"; jq -e "$3" >/dev/null <<<"$x" || fail "$1: $x"; pass "$1"; }
check6 "bash does not see lode's token or key" 0 '.content | test("token=\\[\\] key=\\[\\]")'
check6 "a write through a link out of the workspace is refused" 1 '.isError and (.content | test("outside the workspace"))'
check6 "a write through a link into .git is refused" 2 '.isError and (.content | test(".git or .lake"))'
check6 "an edit through a link into .git is refused" 3 '.isError'
check6 "a read through a link out of the workspace is refused" 4 '.isError and (.content | test("outside the workspace"))'
[ ! -e /tmp/lode-escape ] || fail "the escape wrote a file"

# ── Steering: a message sent during a run reaches the model between steps ───
script='[{"calls": [{"name": "bash", "arguments": {"command": "sleep 2"}}]}, {"text": "first"}, {"text": "second"}]'
id3="$(session "$script")"
api POST "/v0/sessions/$id3/messages" '{"text": "start"}' >/dev/null
sleep 0.5
expect "a message during a run is queued" 202 '.queued == true' \
  "$(api POST "/v0/sessions/$id3/messages" '{"text": "also this"}')"
log="$(wait_idle "$id3")"
jq -e '[.entries[] | select(.type != "event") | .type] == ["user", "assistant", "tool_results", "user", "assistant"]' <<<"$log" >/dev/null \
  || fail "the queued message follows the tool results: $(jq -c '[.entries[] | .type]' <<<"$log")"
jq -e '[.entries[] | select(.type == "user")][1].text == "also this"' <<<"$log" >/dev/null || fail "the steering text"
pass "steering"

# ── Abort ───────────────────────────────────────────────────────────────────
script='[{"calls": [{"name": "bash", "arguments": {"command": "sleep 60"}}]}, {"text": "never"}]'
id4="$(session "$script")"
api POST "/v0/sessions/$id4/messages" '{"text": "wait"}' >/dev/null
sleep 0.5
expect "abort" 202 '.aborting == true' "$(api POST "/v0/sessions/$id4/abort")"
t0=$(date +%s)
log="$(wait_idle "$id4")"
[ $(( $(date +%s) - t0 )) -lt 20 ] || fail "abort took too long"
jq -e '.entries[-1].kind == "aborted"' <<<"$log" >/dev/null || fail "the run was aborted: $(jq -c '.entries[-1]' <<<"$log")"
jq -e '[.entries[] | select(.type == "tool_results") | .results[]][0].content | test("aborted")' <<<"$log" >/dev/null \
  || fail "the tool reports the abort"
pass "the run was aborted"
expect "abort when idle is 409" 409 '.error' "$(api POST "/v0/sessions/$id4/abort")"

# ── Plan agent: no writes ───────────────────────────────────────────────────
script='[{"calls": [{"name": "write", "arguments": {"path": "x", "content": "x"}}]}, {"text": "plan"}]'
id5="$(session "$script")"
api POST "/v0/sessions/$id5/messages" '{"text": "plan it", "agent": "plan"}' >/dev/null
log="$(wait_idle "$id5")"
jq -e '[.entries[] | select(.type == "tool_results") | .results[]][0] | .isError and (.content | test("not available"))' <<<"$log" >/dev/null \
  || fail "the plan agent cannot write"
pass "plan agent"

# ── Persistence across a restart ────────────────────────────────────────────
n="$(jq '.entries | length' <<<"$(wait_idle "$id")")"
kill "$lode_pid"; wait "$lode_pid" 2>/dev/null || true
start_lode
expect "a session survives a restart" 200 ".id == \"$id\" and .entries == $n and .workspace.remoteHead == \"$head\" and .credentials.repo == false" \
  "$(api GET "/v0/sessions/$id")"
expect "sessions are listed" 200 '(.sessions | length) == 6' "$(api GET /v0/sessions)"
expect "delete" 200 ".deleted == \"$id5\"" "$(api DELETE "/v0/sessions/$id5")"
expect "a deleted session is gone" 404 '.error' "$(api GET "/v0/sessions/$id5")"

echo "all passed"
[ -n "${LODE_E2E_KEEP:-}" ] && echo "(kept $work)" || rm -rf "$work"
