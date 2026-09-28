/-
  Tests for `Lode.Compaction`: when to compact, where to cut (always before
  an assistant message, never splitting a call from its result), and what
  the summarizer reads.
-/
import LodeTest.Util
import Lode.Compaction

open Lode Lode.Compaction

namespace LodeTests.Compaction

def a (text : String) (input := 0) : Entry := .assistant { text, calls := #[], usage := { input } } "m" 0
def u (text : String) : Entry := .user text 0

def big : String := "".pushn 'x' 100000

-- The estimate prefers reported usage; without it, characters / 4.
#guard estimateTokens #[u "abcd", a "abcd"] == 2
#guard estimateTokens #[u big, a "ok" (input := 500)] == 500
#guard estimateTokens #[u big, a "ok" (input := 500), u "abcdefgh"] == 502
#guard needed #[u big, a "ok" (input := 190000)] 200000 8192
#guard !needed #[u "hi", a "ok" (input := 1000)] 200000 8192

-- The cut: the earliest assistant entry leaving at most `keepChars` after it.
#guard cutPoint #[u big, a big, u "q", a "r", u "s"] 10 == some 3
#guard cutPoint #[u big, a big, u big, a "r"] 10 == some 3
-- Nothing fits: the last assistant entry.
#guard cutPoint #[u "q", a big] 10 == some 1
-- Never the context's first entry, and only after the last compaction.
#guard cutPoint #[a "x"] 10 == none
#guard cutPoint #[u "q", a "x", u "y", a "z", .compaction "s" 3 0 0] 1000000 == none
#guard cutPoint #[u "q", a "x", u "y", a "z", .compaction "s" 1 0 0] 1000000 == some 3

-- The transcript: the previous summary first, then the messages before the cut.
#guard (transcript #[u "q", a "x", u "y", a "z", .compaction "S" 1 0 0] 3 100000).startsWith
  "[Summary of the conversation before this point]\nS\n\n[Assistant]\nx\n\n[User]\ny"
#guard (transcript #[u big, a "x"] 1 100).length < 200

end LodeTests.Compaction
