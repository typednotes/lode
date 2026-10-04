/- Bounded user decisions. A reply cannot act as an execution grant: it is
   validated conversation data and all existing tool ceilings still apply. -/
import Lean.Data.Json
namespace Lode
open Lean

structure Question where
  private mk ::
  text : String
  options : Array String
  freeText : Bool
  textBound : 0 < text.utf8ByteSize ∧ text.utf8ByteSize ≤ 4096
  optionsBound : options.size ≤ 8 ∧ options.all (fun s => !s.isEmpty && s.utf8ByteSize ≤ 256) = true

instance : ToJson Question := ⟨fun q => Json.mkObj [("text",toJson q.text),("options",toJson q.options),("freeText",toJson q.freeText)]⟩
def Question.parse (j : Json) : Except String Question := do
  let text ← j.getObjValAs? String "text"
  let fields ← j.getObj?
  unless fields.toList.all (fun (k,_) => ["text","options","freeText"].contains k) do throw "unknown question field"
  let options ← match j.getObjVal? "options" with | .error _ => pure #[] | .ok v => fromJson? v
  let freeText ← match j.getObjVal? "freeText" with | .error _ => pure true | .ok v => fromJson? v
  if ht : 0 < text.utf8ByteSize ∧ text.utf8ByteSize ≤ 4096 then
    if ho : options.size ≤ 8 ∧ options.all (fun s => !s.isEmpty && s.utf8ByteSize ≤ 256) = true then
      unless freeText || !options.isEmpty do throw "question needs choices or a free-text answer"
      return ⟨text,options,freeText,ht,ho⟩
    else throw "question choices exceed their bounds"
  else throw "question must contain 1–4096 UTF-8 bytes"
instance : FromJson Question := ⟨Question.parse⟩

structure QuestionAnswer (q : Question) where
  private mk ::
  value : String
  bounded : 0 < value.utf8ByteSize ∧ value.utf8ByteSize ≤ 4096
  chosen : q.freeText = true ∨ q.options.contains value = true

def Question.answer (q : Question) (value : String) : Except String (QuestionAnswer q) :=
  if hb : 0 < value.utf8ByteSize ∧ value.utf8ByteSize ≤ 4096 then
    if hc : q.freeText = true ∨ q.options.contains value = true then .ok ⟨value,hb,hc⟩
    else .error "choose one of the offered answers"
  else .error "answer must contain 1–4096 UTF-8 bytes"

structure PendingQuestion where
  id : String
  question : Question
  deriving ToJson, FromJson
end Lode
