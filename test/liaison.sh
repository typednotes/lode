#!/usr/bin/env bash
# End-to-end test of lode's production paths, against a mock liaison
# (test/mock_liaison.py): a private GitHub repository opened and published
# through liaison's native read/compare-and-publish operations, the same
# on GitLab, the model reached through liaison with
# its own warrant (Anthropic's wire format), a push race refused, and an
# expired warrant reported.
#
#   test/liaison.sh
#
# lode runs in production mode (no LODE_ALLOW_LOCAL): the repository URLs
# are real github.com / gitlab.com ones; only liaison is fake. Needs git,
# jq, curl, python3.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
port="$(free_port)"; lport="$(free_port)"
work="$(mktemp -d "${LODE_TEST_TMP:-${TMPDIR:-/tmp}}/lode-liaison.XXXXXX")"
base="http://127.0.0.1:$port"

fail() { echo "FAIL: $*" >&2; echo "(work dir: $work)" >&2; exit 1; }
pass() { echo "ok - $*"; }

# ── The hosts' repositories ─────────────────────────────────────────────────
seed="$work/seed"
mkdir -p "$seed/lean"
printf 'def Demo.answer : Nat := 42\n' > "$seed/lean/Demo.lean"
printf 'old\n' > "$seed/lean/Old.txt"
git -C "$seed" init -q -b main
git -C "$seed" add -A
git -C "$seed" -c user.email=e2e@lode -c user.name=e2e -c commit.gpgsign=false commit -q -m seed
git clone -q --bare "$seed" "$work/github.git"
git clone -q --bare "$seed" "$work/gitlab.git"

# The model's replies (Anthropic Messages API), shared by both sessions.
cat > "$work/script.json" <<'JSON'
[
  {"content": [{"type": "text", "text": "Writing."},
    {"type": "tool_use", "id": "toolu_1", "name": "write", "input": {"path": "Demo/Hello.lean", "content": "def Demo.hello := \"hi\"\n"}},
    {"type": "tool_use", "id": "toolu_2", "name": "bash", "input": {"command": "rm Old.txt && printf '#!/bin/sh\\n' > run.sh && chmod +x run.sh"}}],
   "stop_reason": "tool_use"},
  {"content": [{"type": "tool_use", "id": "toolu_3", "name": "publish", "input": {"message": "Add Demo.Hello"}}], "stop_reason": "tool_use"},
  {"_status": 429, "_headers": {"retry-after": "3"}},
  {"content": [{"type": "text", "text": "Published."}]},
  {"content": [{"type": "text", "text": "Writing."},
    {"type": "tool_use", "id": "toolu_4", "name": "write", "input": {"path": "Demo/Hello.lean", "content": "def Demo.hello := \"hi\"\n"}},
    {"type": "tool_use", "id": "toolu_5", "name": "bash", "input": {"command": "rm Old.txt && printf '#!/bin/sh\\n' > run.sh && chmod +x run.sh"}}],
   "stop_reason": "tool_use"},
  {"content": [{"type": "tool_use", "id": "toolu_6", "name": "publish", "input": {"message": "Add Demo.Hello"}}], "stop_reason": "tool_use"},
  {"content": [{"type": "text", "text": "Published."}]},
  {"content": [{"type": "tool_use", "id": "toolu_7", "name": "edit", "input": {"path": "Demo.lean", "old": "42", "new": "43"}},
               {"type": "tool_use", "id": "toolu_8", "name": "publish", "input": {"message": "race"}}], "stop_reason": "tool_use"},
  {"content": [{"type": "text", "text": "Blocked."}]}
]
JSON

# ── The mock liaison, and lode ──────────────────────────────────────────────
python3 "$here/mock_liaison.py" "$lport" "$work/github.git" "$work/gitlab.git" "$work/script.json" "$work/egress.log" \
  >"$work/liaison.log" 2>&1 &
liaison_pid=$!
if [ -z "${LODE_TEST_BINARY:-}" ]; then (cd "$root" && lake build lode >/dev/null); fi
LODE_WORKDIR="$work/lode" LODE_PORT="$port" LODE_TOKEN=secret LODE_LIAISON_URL="http://127.0.0.1:$lport" \
  "${LODE_TEST_BINARY:-$root/.lake/build/bin/lode}" >"$work/lode.log" 2>&1 &
lode_pid=$!
trap 'kill $lode_pid $liaison_pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -sf "$base/_health" >/dev/null && curl -sf "http://127.0.0.1:$lport/_health" >/dev/null && break; sleep 0.2; done
curl -sf "$base/_health" >/dev/null || fail "lode did not start: $(cat "$work/lode.log")"
pass "lode and the mock liaison are up"

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
  for _ in $(seq 300); do
    r="$(api GET "/v0/sessions/$1/messages?after=$after&wait=5")"
    [ "$(jq -r .running <<<"${r#* }")" = "false" ] && { echo "$(api GET "/v0/sessions/$1/messages" | cut -d' ' -f2-)"; return; }
    after="$(jq -r .next <<<"${r#* }")"
  done
  fail "session $1 did not finish"
}
warrant() { # PROVIDER [EXPIRES-AT] [OPERATION]
  jq -n --arg p "$1" --arg e "${2:-9999999999}" --arg op "${3:-}" '{id: "w", orgId: "org", tag: "00", caveats: [
    {kind: "runId", value: "run-1"}, {kind: "budget", value: "0"}, {kind: "resource", value: "conn"},
    {kind: "capability", provider: $p, action: (if $op != "" then $op elif $p == "anthropic" then "inference.generate" else "repositories.read" end)}, {kind: "expiresAt", value: $e}]}'
}
creds() {
  local provider="$1" expires="${2:-9999999999}"
  local operations='[]'
  if [ "$provider" != anthropic ]; then
    operations="$(jq -n --argjson w "$(warrant "$provider" "$expires" repositories.write)" \
      --argjson d "$(warrant "$provider" "$expires" repositories.delete)" \
      '[{operation: "repositories.write", warrant: $w}, {operation: "repositories.delete", warrant: $d}]')"
  fi
  jq -n --argjson w "$(warrant "$provider" "$expires")" --argjson ops "$operations" \
    '{warrant: $w, account: "user/conn", cost: 3, operations: $ops}'
}
create() { # URL PROVIDER
  api POST /v0/sessions "$(jq -n --arg url "$1" --argjson rc "$(creds "$2")" --argjson mc "$(creds anthropic)" \
    '{source: {url: $url, branch: "main", path: "lean", credentials: $rc},
      model: {name: "claude-test", credentials: $mc}}')"
}

# ── GitHub ──────────────────────────────────────────────────────────────────
old="$(git -C "$work/github.git" rev-parse main)"
r="$(create https://github.com/acme/demo github)"
expect "a GitHub session opens through liaison" 201 ".workspace.remoteHead == \"$old\" and .credentials.repo and .credentials.model and .model.api == \"anthropic\"" "$r"
gh="$(jq -r .id <<<"${r#* }")"
expect "run" 202 '.queued == false' "$(api POST "/v0/sessions/$gh/messages" '{"text": "Add Demo.hello."}')"
log="$(wait_idle "$gh")"
jq -e '.entries[-1].kind == "run_finished"' <<<"$log" >/dev/null || fail "the run finished: $(jq -c '.entries[-3:]' <<<"$log")"
jq -e '[.entries[] | select(.type == "tool_results") | .results[] | select(.name == "publish")][0] | (.isError | not) and (.content | test("Published [0-9a-f]{40}"))' <<<"$log" >/dev/null \
  || fail "publish: $(jq -c '[.entries[] | select(.type == "tool_results")]' <<<"$log")"
new="$(git -C "$work/github.git" rev-parse main)"
[ "$new" != "$old" ] || fail "the branch moved"
[ "$(git -C "$work/github.git" rev-parse "$new^")" = "$old" ] || fail "the new commit's parent is the old head"
[ "$(git -C "$work/github.git" log -1 --format=%s main)" = "Add Demo.Hello" ] || fail "the message"
git -C "$work/github.git" show main:lean/Demo/Hello.lean | grep -q 'Demo.hello' || fail "the added file"
if git -C "$work/github.git" cat-file -e main:lean/Old.txt 2>/dev/null; then fail "the deleted file is gone"; fi
[ "$(git -C "$work/github.git" ls-tree main lean/run.sh | cut -d' ' -f1)" = "100755" ] || fail "the executable bit"
git -C "$work/github.git" show main:lean/Demo.lean | grep -q 'answer' || fail "untouched files are kept"
pass "GitHub: native compare-and-publish makes the right commit"
repositories="$(jq -c 'select(.provider == "github")' "$work/egress.log")"
jq -e -s 'all(.[]; .call.kind == "connector" and .action == .call.operation and
  (.call | has("url") | not) and (.call | has("headers") | not)) and
  any(.[]; .call.operation == "repositories.read") and
  any(.[]; .call.operation == "repositories.write" and .call.resource == ["acme", "demo", "lean"])' \
  <<<"$repositories" >/dev/null || fail "native repository envelopes: $repositories"
pass "repository calls use named-operation warrants and a scoped publication target"
expect "the status follows GitHub" 200 ".workspace.remoteHead == \"$new\"" "$(api GET "/v0/sessions/$gh")"

# What went through liaison for the model.
model_calls="$(jq -c 'select(.provider == "anthropic")' "$work/egress.log")"
first="$(head -n1 <<<"$model_calls")"
jq -e '.cost == "3" and .call.kind == "connector" and .call.operation == "inference.generate" and .call.resource == ["claude-test"] and .call.context.client == "typednotes-lode"' <<<"$first" >/dev/null \
  || fail "the model call's envelope: $first"
jq -e '.call | (has("headers") | not) and (has("url") | not)' <<<"$first" >/dev/null \
  || fail "no credential headers from lode"
body1="$(jq -r .call.payload <<<"$first")"
jq -e '(has("model") | not) and (.tools | map(.name) | index("publish") != null) and (.system[0].text | test("lun"))
       and (.system[0].text | test("lean/"))' <<<"$body1" >/dev/null || fail "the first request: $body1"
body2="$(jq -r .call.payload <<<"$(sed -n 2p <<<"$model_calls")")"
jq -e '.messages[2].role == "user" and ([.messages[2].content[] | .tool_use_id] == ["toolu_1", "toolu_2"])' <<<"$body2" >/dev/null \
  || fail "the second request carries the tool results: $body2"
pass "the model is reached through liaison, with tool results threaded back"
# The third call was rate limited (429, `retry-after: 3`): the same request
# again, after the 3 s the provider asked for (backoff alone would be ≤ 2 s).
jq -e -s '(.[2].call.payload == .[3].call.payload) and (.[2].call.context.sessionId == .[3].call.context.sessionId) and (.[3].received - .[2].received >= 2.8)' <<<"$model_calls" >/dev/null \
  || fail "a rate-limited call is retried after its Retry-After: $(jq -c -s 'map({received, n: (.call.payload | length)})' <<<"$model_calls")"
pass "a rate-limited model call is retried after the provider's Retry-After"
expect "usage is accumulated" 200 '.usage.input == 300 and .usage.output == 30' "$(api GET "/v0/sessions/$gh")"

# ── GitLab ──────────────────────────────────────────────────────────────────
old="$(git -C "$work/gitlab.git" rev-parse main)"
r="$(create https://gitlab.com/acme/demo gitlab)"
expect "a GitLab session opens through liaison" 201 ".workspace.remoteHead == \"$old\"" "$r"
gl="$(jq -r .id <<<"${r#* }")"
api POST "/v0/sessions/$gl/messages" '{"text": "Add Demo.hello."}' >/dev/null
log="$(wait_idle "$gl")"
jq -e '[.entries[] | select(.type == "tool_results") | .results[] | select(.name == "publish")][0].isError | not' <<<"$log" >/dev/null \
  || fail "GitLab publish: $(jq -c '[.entries[] | select(.type == "tool_results")]' <<<"$log")"
new="$(git -C "$work/gitlab.git" rev-parse main)"
[ "$(git -C "$work/gitlab.git" rev-parse "$new^")" = "$old" ] || fail "GitLab: the parent"
git -C "$work/gitlab.git" show main:lean/Demo/Hello.lean | grep -q 'Demo.hello' || fail "GitLab: the added file"
if git -C "$work/gitlab.git" cat-file -e main:lean/Old.txt 2>/dev/null; then fail "GitLab: the deleted file"; fi
[ "$(git -C "$work/gitlab.git" ls-tree main lean/run.sh | cut -d' ' -f1)" = "100755" ] || fail "GitLab: the executable bit"
pass "GitLab: one commit with create/delete actions"

# ── A push race: someone else moved the branch ──────────────────────────────
clone="$work/other"
git clone -q "$work/github.git" "$clone"
echo more >> "$clone/lean/Demo.lean"
git -C "$clone" -c user.email=o@x -c user.name=o -c commit.gpgsign=false commit -q -am "someone else"
theirs="$(git -C "$clone" rev-parse main)"
git -C "$work/github.git" fetch -q "$clone" main
git -C "$work/github.git" update-ref refs/heads/main "$theirs" "$(git -C "$clone" rev-parse "$theirs^")"
api POST "/v0/sessions/$gh/messages" '{"text": "Bump the answer."}' >/dev/null
log="$(wait_idle "$gh")"
jq -e '[.entries[] | select(.type == "tool_results") | .results[] | select(.name == "publish")][-1] | .isError and (.content | test("moved"))' <<<"$log" >/dev/null \
  || fail "the race: $(jq -c '[.entries[] | select(.type == "tool_results")][-1]' <<<"$log")"
[ "$(git -C "$work/github.git" rev-parse main)" = "$theirs" ] || fail "their commit was overwritten"
pass "publishing over someone else's push is refused, nothing overwritten"

# ── Expired warrants ────────────────────────────────────────────────────────
expect "credentials can be refreshed" 200 '.credentials.model' \
  "$(api PUT "/v0/sessions/$gh/credentials" "$(jq -n --argjson m "$(creds anthropic 1000)" '{model: $m}')")"
api POST "/v0/sessions/$gh/messages" '{"text": "Again."}' >/dev/null
log="$(wait_idle "$gh")"
jq -e '.entries[-1].kind == "error" and (.entries[-1].detail | test("expired"))' <<<"$log" >/dev/null \
  || fail "an expired model warrant: $(jq -c '.entries[-1]' <<<"$log")"
expect "the status says why the run failed" 200 '.error | test("fresh credentials")' "$(api GET "/v0/sessions/$gh")"

echo "all passed"
[ -n "${LODE_E2E_KEEP:-}" ] && echo "(kept $work)" || rm -rf "$work"
