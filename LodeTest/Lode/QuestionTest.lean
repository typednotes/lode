import Lode.Question
import Lode.Tools
open Lean Lode
#guard (Question.parse (Json.mkObj [("text","Choose a rounding rule"),("options",toJson (["up","down"] : List String)),("freeText",.bool false)])).isOk
#guard (Question.parse (Json.mkObj [("text","")])).toOption.isNone
#guard (Question.parse (Json.mkObj [("text","Choose"),("options",.num 1)])).toOption.isNone
#guard (Question.parse (Json.mkObj [("text","Choose"),("policy",Json.mkObj [])])).toOption.isNone
def choice := Question.parse (Json.mkObj [("text","Choose"),("options",toJson (["up","down"] : List String)),("freeText",.bool false)])
#guard match choice with | .ok q => (q.answer "up").isOk | .error _ => false
#guard match choice with | .ok q => (q.answer "invented").toOption.isNone | .error _ => false
example (q : Question) : q.text.utf8ByteSize ≤ 4096 := q.textBound.2
example (q : Question) (a : QuestionAnswer q) : q.freeText = true ∨ q.options.contains a.value = true := a.chosen
#guard (Tools.Args.parse "ask_user" (Json.mkObj [("text","Pick a format")]).compress).isOk
#guard match Tools.Args.parse "ask_user" (Json.mkObj [("text","Pick a format")]).compress with
  | .ok args => (Tools.AuthorizedArgs.check ⟨[]⟩ ["ask_user"] args).toOption.isNone
  | .error _ => false
