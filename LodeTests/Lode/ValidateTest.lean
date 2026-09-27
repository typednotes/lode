/-
  Tests for `Lode.Validate`: the grammars accept what they should and refuse
  what would be dangerous downstream (a path escaping the checkout, a write
  into `.git`, a URL with userinfo, a model endpoint with a query).
-/
import LodeTests.Util
import Lode.Validate

open Lode.Validate

namespace LodeTests.Validate

-- ── Ids ─────────────────────────────────────────────────────────────────────

#guard sessionId "0123456789abcdef0123456789abcdef"
#guard !sessionId "0123456789ABCDEF0123456789abcdef"
#guard !sessionId "../../etc"
#guard buildId ("".pushn 'a' 64) && !buildId ("".pushn 'a' 63)
#guard commit "dc19b371d09f409810678d8b35dbb381afecf272" && !commit "dc19b37"

-- ── Branches ────────────────────────────────────────────────────────────────

#guard branch "main" && branch "feature/x-1"
#guard !branch "-rf" && !branch "a..b" && !branch "a b" && !branch "x.lock" && !branch "@"
#guard !branch "a/" && !branch "/a" && !branch "a//b" && !branch ".hidden"

-- ── Resolving paths ─────────────────────────────────────────────────────────

-- Relative to the project directory `lean/`.
#guard resolve "/w" ["lean"] "Demo.lean" == .ok ["lean", "Demo.lean"]
#guard resolve "/w" ["lean"] "./Demo/../Demo.lean" == .ok ["lean", "Demo.lean"]
#guard resolve "/w" ["lean"] "../README.md" == .ok ["README.md"]
#guard resolve "/w" ["lean"] "." == .ok ["lean"]
#guard resolve "/w" ["lean"] "a//b/" == .ok ["lean", "a", "b"]
-- Absolute paths under the checkout are accepted; others are not.
#guard resolve "/w" ["lean"] "/w/lean/X.lean" == .ok ["lean", "X.lean"]
#guard resolve "/w" ["lean"] "/w" == .ok []
#guard (resolve "/w" ["lean"] "/etc/passwd").toOption.isNone
#guard (resolve "/w" ["lean"] "/wx/y").toOption.isNone
-- Escapes.
#guard (resolve "/w" ["lean"] "../../etc/passwd").toOption.isNone
#guard (resolve "/w" [] "..").toOption.isNone
#guard (resolve "/w" ["lean"] "a/../../..").toOption.isNone
#guard (resolve "/w" ["lean"] "").toOption.isNone
#guard (resolve "/w" ["lean"] "a\nb").toOption.isNone

#guard writable ["lean", "Demo.lean"]
#guard !writable [".git", "config"] && !writable ["lean", ".git", "x"]
#guard !writable ["lean", ".lake", "build"] && !writable []

-- ── Repositories ────────────────────────────────────────────────────────────

#guard (repo "https://github.com/typednotes/lode").toOption.map (·.host) == some .github
#guard (repo "https://github.com/typednotes/lode.git").toOption.map (·.cloneUrl) ==
  some "https://github.com/typednotes/lode.git"
#guard (repo "https://gitlab.com/g/sub/p").toOption.map (·.segments) == some ["g", "sub", "p"]
#guard (repo "https://GitHub.com/a/b").toOption.map (·.host) == some .github
#guard (repo "https://github.com/a/b/c").toOption.isNone
#guard (repo "https://user@github.com/a/b").toOption.isNone
#guard (repo "https://github.com:22/a/b").toOption.isNone
#guard (repo "http://github.com/a/b").toOption.isNone
#guard (repo "https://github.com/a/..").toOption.isNone
#guard (repo "file:///tmp/r").toOption.isNone
#guard (repo "file:///tmp/r" (allowLocal := true)).toOption.map (·.host) == some .local
#guard (repo "file://relative" (allowLocal := true)).toOption.isNone

-- ── Model endpoints ─────────────────────────────────────────────────────────

#guard baseUrl "https://api.anthropic.com/v1"
#guard baseUrl "https://llm.example.com:8443/openai/v1"
#guard !baseUrl "https://api.anthropic.com/v1/"
#guard !baseUrl "http://api.anthropic.com/v1"
#guard baseUrl "http://127.0.0.1:9000/v1" (allowLocal := true)
#guard !baseUrl "https://user:pw@api.x.com/v1"
#guard !baseUrl "https://api.x.com/v1?key=1"
#guard !baseUrl "https://api.x.com/v1/../admin"
#guard !baseUrl "https://"

end LodeTests.Validate
