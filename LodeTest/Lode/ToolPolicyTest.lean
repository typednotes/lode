import LodeTest.Util
import Lode.Spec

open Lean (Json toJson)
open Lode.Tools

namespace LodeTests.ToolPolicy

def policy (names : List String) := Policy.parse (toJson names)

#guard policy [] == .ok ⟨[]⟩
#guard policy ["read", "todo"] == .ok ⟨[.read, .todo]⟩
#guard (policy ["read", "remote_fetch"]).toOption.isNone
#guard (policy ["read", "read"]).toOption.isNone
#guard (Policy.parse Json.null).toOption.isNone
#guard (Policy.parse (Json.mkObj [("read", toJson true)])).toOption.isNone
#guard Operation.all.map Operation.name == specs.toList.map (·.name)
#guard (specsForPolicy ⟨[.read, .todo]⟩ Lode.Prompt.build.tools).map (·.name) == #["read", "todo"]
#guard (specsForPolicy ⟨[.write, .todo]⟩ Lode.Prompt.plan.tools).map (·.name) == #["todo"]
#guard (AuthorizedArgs.check ⟨[.read]⟩ ["read", "write"] (.write "x" "y")).toOption.isNone
#guard (AuthorizedArgs.check Policy.all ["read"] (.bash "true" 1)).toOption.isNone
#guard (AuthorizedArgs.check ⟨[]⟩ (Operation.all.map Operation.name) (.todo #[])).toOption.isNone
#guard (BoundedPolicy.initial ⟨[.read, .todo]⟩ |>.narrow ⟨[.read]⟩).toOption.isSome
#guard ((BoundedPolicy.initial ⟨[.read, .todo]⟩ |>.narrow ⟨[.read]⟩) >>= (·.narrow ⟨[.read, .todo]⟩)).toOption.isNone
#guard ((BoundedPolicy.initial Policy.all |>.narrow ⟨[]⟩) >>= (·.narrow ⟨[.read]⟩)).toOption.isNone

-- The execution witness bounds actual parsed arguments, independently of the
-- model's name and advertised schema. This is kernel-checked, not a #guard.
example (p : BoundedPolicy ceiling) (a : AuthorizedArgs p.policy agent) :
    ceiling.permits a.args.operation := AuthorizedArgs.authority_bounded p a

def launch := Json.mkObj [("source", Json.mkObj [("url", "file:///tmp/fixture"), ("branch", "main")]),
  ("model", Json.mkObj [("api", "scripted")])]

#guard (Lode.SessionSpec.parse launch none true).toOption.map (·.tools) == some Policy.all
#guard (Lode.SessionSpec.parse (launch.setObjVal! "tools" (toJson ([] : List String))) none true).toOption.map (·.tools) == some ⟨[]⟩
#guard (Lode.SessionSpec.parse (launch.setObjVal! "tools" Json.null) none true).toOption.isNone
#guard (Lode.SessionSpec.parse (launch.setObjVal! "tools" (toJson ["fetch"])) none true).toOption.isNone
#guard (Lode.MessageRequest.parse (Json.mkObj [("text", "hi"), ("tools", Json.null)])).toOption.isNone
#guard (Lode.MessageRequest.parse (Json.mkObj [("text", "hi"), ("credentials", Json.mkObj [("tools", toJson ["bash"])] )])).toOption.isNone

end LodeTests.ToolPolicy
