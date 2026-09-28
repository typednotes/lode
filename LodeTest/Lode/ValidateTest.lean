/-
  Tests for `Lode.Validate`: the grammars accept what they should and refuse
  what would be dangerous downstream (a path escaping the checkout, a write
  into `.git`, a model endpoint with a query).
-/
import LodeTest.Util
import Lode.Validate

open Lode.Validate

namespace LodeTests.Validate

-- ── Ids ─────────────────────────────────────────────────────────────────────

#guard sessionId "0123456789abcdef0123456789abcdef"
#guard !sessionId "0123456789ABCDEF0123456789abcdef"
#guard !sessionId "../../etc"
#guard buildId ("".pushn 'a' 64) && !buildId ("".pushn 'a' 63)
#guard commit "dc19b371d09f409810678d8b35dbb381afecf272" && !commit "dc19b37"

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

-- ── Project paths ───────────────────────────────────────────────────────────

-- (Repository URLs and branch names are linen's `System.Git.Remote`, tested there.)
#guard projectPath "" && projectPath "lean" && projectPath "a/b-c/d_e.f"
#guard !projectPath "/abs" && !projectPath "a/../b" && !projectPath "a//b" && !projectPath "." && !projectPath "a b"

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
