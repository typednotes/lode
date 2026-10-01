import Lode.RuntimeContext

open Lean Lode.Runtime

namespace LodeTests.Runtime

def execution (effects domains : List String := []) : Json := Json.mkObj [
  ("policy", Json.mkObj [("effects", toJson effects), ("domains", toJson domains)]),
  ("binding", Json.mkObj [("org_id", "org"), ("user_id", "actor"), ("graph_id", "graph")]),
  ("connectors", Json.mkObj []), ("functions", toJson (["double", "trace"] : List String)),
  ("graphs", toJson (["main"] : List String))]

def parse := Context.parse (execution ["HTTP", "Trace"] ["example.org"])
def launch := parse.toOption.map (·.bounds)

#guard parse.isOk
#guard (Context.parse ((execution).setObjVal! "_runtime" (Json.mkObj []))).toOption.isNone
#guard (Context.parse ((execution).setObjVal! "liaisonUrl" "http://evil")).toOption.isNone
#guard (Context.parse (execution ["IO"])).toOption.isNone
#guard (Context.parse (execution ["HTTP", "HTTP"])).toOption.isNone
#guard (Context.parse ((execution).setObjVal! "functions" (toJson (["double", "double"] : List String)))).toOption.isNone
#guard (inputBody "function" (Json.mkObj [("policy", Json.mkObj [])])).toOption.isNone
#guard (inputBody "graph" (Json.mkObj [("input", Json.null)])).toOption.isNone
#guard (Call.inputOnly "function" "double" (Json.mkObj [("input", toJson (21 : Nat))])).isOk

def transition (child : Json) (credentialsOnly : Bool := false) : Except String Unit := do
  let initial ← parse
  let child ← Context.parse child
  let _ ← refresh initial.bounds initial.bounds child credentialsOnly

#guard (transition (execution ["Trace"] [])).isOk
#guard (transition (execution ["Trace"] []) true).toOption.isNone
#guard (transition (execution ["HTTP", "Trace"] ["example.org"]) true).isOk
#guard (transition (execution ["HTTP", "Trace", "FileSystem"] [])).toOption.isNone
#guard (transition (execution ["HTTP"] ["other.org"])).toOption.isNone
#guard (transition ((execution).setObjVal! "binding" (Json.mkObj [("org_id", "org"), ("user_id", "other"), ("graph_id", "graph")]))).toOption.isNone
#guard (transition ((execution).setObjVal! "functions" (toJson (["other"] : List String)))).toOption.isNone

def restoreRemoved : Except String Unit := do
  let initial ← parse
  let child ← Context.parse (execution ["Trace"] [])
  let _ ← refresh initial.bounds initial.bounds child false
  let _ ← refresh initial.bounds child.bounds initial false

#guard restoreRemoved.toOption.isNone

def call (name : String) : Except String Call := do
  let initial ← parse
  let some caller := AuthenticatedCaller.check? (some "fixture") "Bearer fixture" | throw "fixture authentication failed"
  let initial := initial.authenticate caller
  let bounded ← Bounded.check initial.bounds initial
  bounded.call "function" name (Json.mkObj [("input", toJson (21 : Nat))]) 0 (some "fixture")

#guard (call "double").isOk
#guard (call "other").toOption.isNone
#guard (AuthenticatedCaller.check? none "Bearer fixture").isNone
#guard (AuthenticatedCaller.check? (some "") "Bearer ").isNone
#guard (AuthenticatedCaller.check? (some "fixture") "Bearer different").isNone

def unauthenticated : Except String Call := do
  let initial ← parse
  let bounded ← Bounded.check initial.bounds initial
  bounded.call "function" "double" (Json.mkObj []) 0 (some "fixture")

#guard unauthenticated.toOption.isNone
#guard ((call "double").toOption.map (fun call => (call.body.getObjVal? "binding").toOption)) ==
  some ((execution).getObjVal? "binding").toOption

-- These laws are indexed by the context consumed by the actual HTTP call.
example {ceiling : Bounds} (b : Bounded ceiling) :
    _root_.Lun.executionNarrows b.context.bounds.execution ceiling.execution = true := b.attenuated
example (call : Call) : call.body = call.authority.mergeObj call.input := call.correspondence
example {ceiling : Bounds} (b : Bounded ceiling) :
    _root_.Lun.executionNarrows b.context.bounds.execution b.previous.execution = true := b.current_attenuated
example {context : Context} {now : UInt64} (fresh : FreshOperation context now) :
    fresh.warrant.permits fresh.request := fresh.permitted

end LodeTests.Runtime
