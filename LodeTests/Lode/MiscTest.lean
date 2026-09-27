/-
  Tests for the remaining pure parts: lake's diagnostics, dates, the log
  endpoint's shape, token comparison.
-/
import LodeTests.Util
import Lode.Diagnostics
import Lode.Server

open Lean (Json toJson)
open Lode

namespace LodeTests.Misc

-- ── Diagnostics ─────────────────────────────────────────────────────────────

def log : String :=
  "✖ [3/5] Building Demo.Hello\nerror: Demo/Hello.lean:3:25: Type mismatch\n  \"no\"\nhas type\n  String\n" ++
  "warning: Demo.lean:1:4: unused variable\nerror: Lean exited with code 1\nSome required targets logged failures:\n- Demo.Hello"

#guard (Diagnostics.parse log).map (fun d => (d.severity, d.file, d.line)) ==
  [("error", some "Demo/Hello.lean", some 3), ("warning", some "Demo.lean", some 1), ("error", none, none)]
#guard ((Diagnostics.parse log).head?.map (·.message)) == some "Type mismatch\n  \"no\"\nhas type\n  String"
#guard ((Diagnostics.parse log).head?.map Diagnostics.Diagnostic.render) ==
  some "Demo/Hello.lean:3:25: error: Type mismatch\n  \"no\"\nhas type\n  String"
#guard Diagnostics.isNoise { severity := "error", file := none, line := none, column := none, message := "build failed" }

-- ── Dates ───────────────────────────────────────────────────────────────────

#guard isoDate 0 == "1970-01-01"
#guard isoDate (951782400 * 1000) == "2000-02-29"
#guard isoDate (1790380800 * 1000) == "2026-09-26"

-- ── The API's shapes ────────────────────────────────────────────────────────

#guard (entriesJson #[.user "a" 1, .user "b" 2] 1 false).compress ==
  "{\"entries\":[{\"index\":1,\"text\":\"b\",\"time\":2,\"type\":\"user\"}],\"next\":2,\"running\":false}"
#guard constantTimeEq "Bearer x" "Bearer x" && !constantTimeEq "Bearer x" "Bearer y" && !constantTimeEq "a" "ab"

end LodeTests.Misc
