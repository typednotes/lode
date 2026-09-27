/-
  Tests for `Lode.Tools`' pure parts: argument parsing (what the model's text
  becomes, and what it may not), `read`'s numbering, `edit`'s replacement
  rule, truncation, and the tool list agents see.
-/
import LodeTests.Util
import Lode.Tools
import Lode.Prompt

open Lode.Tools

namespace LodeTests.Tools

-- ── Arguments ───────────────────────────────────────────────────────────────

#guard match Args.parse "read" "{\"path\": \"a.lean\"}" with
  | .ok (.read p o l) => p == "a.lean" && o == 1 && l == maxLines
  | _ => false
#guard match Args.parse "read" "{\"path\": \"a\", \"offset\": 10, \"limit\": 99999}" with
  | .ok (.read _ o l) => o == 10 && l == maxLines
  | _ => false
#guard (Args.parse "read" "{\"path\": \"a\", \"offset\": 0}").toOption.isNone
#guard (Args.parse "read" "{}").toOption.isNone
#guard (Args.parse "read" "[1]").toOption.isNone
#guard (Args.parse "read" "{oops").toOption.isNone
#guard match Args.parse "ls" "" with | .ok (.ls ".") => true | _ => false
#guard match Args.parse "edit" "{\"path\": \"a\", \"old\": \"x\", \"new\": \"y\"}" with
  | .ok (.edit _ _ _ all) => !all
  | _ => false
#guard match Args.parse "bash" "{\"command\": \"ls\"}" with | .ok (.bash _ 120) => true | _ => false
#guard (Args.parse "bash" "{\"command\": \"ls\", \"timeout\": 99999}").toOption.isNone
#guard (Args.parse "todo" "{\"todos\": [{\"content\": \"x\", \"status\": \"doing\"}]}").toOption.isNone
#guard match Args.parse "check" "{\"targets\": [\"Demo.Hello\", \"+Mod\"]}" with
  | .ok (.check ts) => ts == #["Demo.Hello", "+Mod"]
  | _ => false
#guard (Args.parse "check" "{\"targets\": [\"--help\"]}").toOption.isNone
#guard (Args.parse "check" "{\"targets\": [\"a;rm -rf /\"]}").toOption.isNone
#guard (Args.parse "publish" "{\"message\": \"  \"}").toOption.isNone
#guard (Args.parse "lun_call" "{\"kind\": \"cell\", \"name\": \"math.double\"}").toOption.isSome
#guard (Args.parse "lun_call" "{\"kind\": \"both\", \"name\": \"x\"}").toOption.isNone
#guard (Args.parse "lun_call" "{\"kind\": \"dag\", \"name\": \"../x\"}").toOption.isNone
#guard (Args.parse "rm" "{}").toOption.isNone

-- ── read ────────────────────────────────────────────────────────────────────

#guard numberLines "a\nb\nc\n" 1 2000 == "1\ta\n2\tb\n3\tc"
#guard numberLines "a\nb\nc" 2 1 == "2\tb\n\n(1 more lines; continue with offset=3)"
#guard numberLines "" 1 10 == "(empty file)"
#guard (numberLines "a\nb" 5 10).startsWith "(the file has 2 lines"
-- Numbers are right-aligned to the widest shown.
#guard (numberLines (String.intercalate "\n" ((List.range 10).map toString)) 9 5) == " 9\t8\n10\t9"

-- ── edit ────────────────────────────────────────────────────────────────────

#guard applyEdit "x = 1\ny = 2\n" "y = 2" "y = 3" false == .ok ("x = 1\ny = 3\n", 1)
#guard (applyEdit "a a" "a" "b" false).toOption.isNone
#guard applyEdit "a a" "a" "b" true == .ok ("b b", 2)
#guard (applyEdit "abc" "z" "y" false).toOption.isNone
#guard (applyEdit "abc" "" "y" false).toOption.isNone
#guard (applyEdit "abc" "b" "b" false).toOption.isNone
#guard occurrences "aaaa" "aa" == 2

-- ── Truncation ──────────────────────────────────────────────────────────────

#guard truncateHead "1\n2\n3" 2 == ("1\n2", true)
#guard truncateHead "1\n2\n3" 5 == ("1\n2\n3", false)
#guard truncateTail "1\n2\n3" 2 == ("2\n3", true)
#guard truncateTail "aaaa\nbb" 10 4 == ("bb", true)
#guard clipLine "abc" 2 == "ab …(line truncated)"

-- ── Todos, and which agent has which tools ──────────────────────────────────

#guard renderTodos #[{ content := "a", status := "completed" }, { content := "b", status := "in_progress" }] == "[x] a\n[~] b"
#guard (specsFor Lode.Prompt.plan.tools).all fun s => !["write", "edit", "bash", "publish", "lun_build"].contains s.name
#guard (specsFor Lode.Prompt.build.tools).size == specs.size
-- Every tool the agents name exists, and every spec is an object schema.
#guard (Lode.Prompt.build.tools ++ Lode.Prompt.plan.tools).all fun n => specs.any (·.name == n)
#guard specs.all fun s => s.schema.getObjValAs? String "type" == .ok "object"

end LodeTests.Tools
