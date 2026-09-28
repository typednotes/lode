/-
  Tests for `Lode.Message`: log entries round-trip through JSON, and the
  context the model is sent is well formed — every tool call answered, the
  compacted history replaced by its summary.
-/
import LodeTest.Util
import Lode.Message

open Lean (Json toJson)
open Lode

namespace LodeTests.Message

def call (id : String) : ToolCall := { id, name := "read", arguments := "{}" }
def res (id : String) : ToolResult := { id, name := "read", content := "ok" }

-- ── Round trips ─────────────────────────────────────────────────────────────

def entries : List Entry :=
  [ .user "hi" 1
  , .assistant { text := "t", calls := #[call "a"], usage := { input := 3, output := 4 }, stop := "tool_use" } "m" 2
  , .toolResults #[{ res "a" with isError := true }] 3
  , .compaction "sum" 1 99 4
  , .event "run_finished" "1 step(s)" 5 ]

#guard entries.all fun e => (toJson e).compress == ((Entry.ofJson (toJson e)).map (toJson ·) |>.toOption.map (·.compress)).getD ""
#guard (Entry.ofJson (Json.mkObj [("type", "bogus")])).toOption.isNone

-- ── Dangling tool calls ─────────────────────────────────────────────────────

#guard answerDangling [.user "u", .assistant "" #[call "a"]] ==
  [.user "u", .assistant "" #[call "a"],
   .toolResults #[{ id := "a", name := "read", content := "(interrupted: this tool call did not complete)", isError := true }]]
-- A partial answer is completed, in order; a stray result is dropped.
#guard answerDangling [.assistant "" #[call "a", call "b"], .toolResults #[res "b", res "z"]] ==
  [.assistant "" #[call "a", call "b"],
   .toolResults #[res "b", { id := "a", name := "read", content := "(interrupted: this tool call did not complete)", isError := true }]]
#guard answerDangling [.toolResults #[res "a"], .user "u"] == [.user "u"]
#guard answerDangling [.assistant "x" #[], .user "u"] == [.assistant "x" #[], .user "u"]

-- ── The context ─────────────────────────────────────────────────────────────

#guard context #[.event "run_started" "" 0, .user "a" 1, .assistant { text := "b", calls := #[] } "m" 2] ==
  #[.user "a", .assistant "b" #[]]
-- After a compaction: the summary, then the entries from `firstKept` on.
#guard context #[.user "a" 1, .assistant { text := "b", calls := #[] } "m" 2, .user "c" 3,
                 .assistant { text := "d", calls := #[] } "m" 4, .compaction "S" 3 0 5] ==
  #[.user (summaryMessage "S"), .assistant "d" #[]]
#guard lastCompaction? #[.compaction "1" 1 0 0, .user "x" 0, .compaction "2" 2 0 0] == some ("2", 2)

end LodeTests.Message
