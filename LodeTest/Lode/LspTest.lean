import LodeTest.Util
import Lode.Tools

open Lean (Json toJson)
open Lode.Lsp
open Lode.Tools

namespace LodeTests.Lsp

-- Kernel witnesses travel to execution, not merely the advertised schema.
example (q : Query) : q.method ∈ ["textDocument/hover", "textDocument/definition",
    "textDocument/completion", "textDocument/waitForDiagnostics", "$/lean/plainGoal"] := q.read_only
example (d : WorkspaceDocument root) : within root d.path := d.scope_confined
example (d : WorkspaceDocument root) : d.text.utf8ByteSize ≤ maxDocumentBytes := d.size_bounded
example (p : DocumentPath) : validDocumentPath p.value = true := p.validated
example (p : WorkspaceLocation root) : within root p.path := p.scope_confined
example (p : WorkspaceLocation root) : validDocumentPath p.relative = true := p.relative_valid
example (r : Request root) (p : Lean.Lsp.Position) (h : p ∈ r.position) :
    validPosition r.document.text p = true := r.positionValid p h
example (bounded : BoundedPolicy ceiling) (a : AuthorizedArgs bounded.policy agent) :
    ceiling.permits a.args.operation := AuthorizedArgs.authority_bounded bounded a

#guard ["Demo.lean", "Demo/Math.lean", "résumé/hello world.lean"].all validDocumentPath
#guard ["/tmp/Demo.lean", "../Demo.lean", "A/../Demo.lean", "./Demo.lean", "A//Demo.lean",
  "file:///tmp/A.lean", "A%2fB.lean", "A\\B.lean", "C:/A.lean", ".git/A.lean", ".lake/A.lean",
  "A.lean?query", "A.lean#fragment", "A.lean\n", "A.txt", ".lean", "A\u0000.lean"].all (!validDocumentPath ·)
#guard (Query.parse "$/lean/rpc/call").toOption.isNone
#guard (Query.parse "workspace/executeCommand").toOption.isNone
#guard validPosition "a😀b\nβ\r\n" ⟨0, 3⟩
#guard !validPosition "a😀b\nβ\r\n" ⟨0, 2⟩
#guard validPosition "a😀b\nβ\r\n" ⟨0, 4⟩
#guard validPosition "a😀b\nβ\r\n" ⟨1, 1⟩
#guard !validPosition "a😀b\nβ\r\n" ⟨1, 2⟩
#guard !validPosition "abc" ⟨1, 0⟩
#guard !validPosition "abc" ⟨0, 4⟩
#guard frameLength "Content-Length: 42\r\n\r\n" == .ok 42
#guard ["Content-Length: 0\r\n\r\n", "Content-Length: -1\r\n\r\n",
  "Content-Length: 9999999999\r\n\r\n", "Content-Length: 262145\r\n\r\n",
  "Content-Length: 4\r\nContent-Length: 4\r\n\r\n", "Content-Length: 1\n\n",
  "X: 4\r\n\r\n", "Content-Length: 4 \r\n\r\n"].all (frameLength · |>.toOption.isNone)
#guard shallowJson "{\"brackets\":\"[\\\"{\"}"
#guard !shallowJson (String.ofList (List.replicate 65 '[') ++ String.ofList (List.replicate 65 ']'))
#guard !shallowJson "{\"line\":1e999999999999999999}"
#guard !shallowJson "{\"line\":123456789012345678901}"
#guard shallowJson "{\"text\":\"1e99999999999999999999999\"}"
#guard safeText "ordinary Lean text" == "ordinary Lean text"
#guard safeText "[link](file:///private/Secret.lean)" == "[text containing a filesystem path omitted]"
#guard safeText "failed in /private/secret" == "[text containing a filesystem path omitted]"
#guard safeText "source:/private/secret" == "[text containing a filesystem path omitted]"
#guard safeText "[link](FILE:///private/Secret.lean)" == "[text containing a filesystem path omitted]"

def args (operation : String := "hover") : Json := Json.mkObj [
  ("operation", toJson operation), ("path", "Demo.lean"), ("line", toJson (0 : Nat)), ("character", toJson (0 : Nat))]

#guard (Args.parse "lsp" (args "hover").compress).isOk
#guard (Args.parse "lsp" (args "definition").compress).isOk
#guard (Args.parse "lsp" (args "completion").compress).isOk
#guard (Args.parse "lsp" (args "goals").compress).isOk
#guard (Args.parse "lsp" "{\"operation\":\"diagnostics\",\"path\":\"Demo.lean\"}").isOk
#guard (Args.parse "lsp" (args "diagnostics").compress).toOption.isNone
#guard (Args.parse "lsp" (args "rpc").compress).toOption.isNone
#guard (Args.parse "lsp" ((args).setObjVal! "method" "workspace/executeCommand").compress).toOption.isNone
#guard (Args.parse "lsp" ((args).setObjVal! "uri" "file:///private/Secret.lean").compress).toOption.isNone
#guard (Args.parse "lsp" ((args).setObjVal! "text" "#eval IO.println 1").compress).toOption.isNone
#guard (Args.parse "lsp" ((args).setObjVal! "character" (toJson (-1 : Int))).compress).toOption.isNone
#guard (Args.parse "lsp" ((args).setObjVal! "character" Json.null).compress).toOption.isNone
#guard (Args.parse "lsp" ((args).setObjVal! "line" (toJson (1048577 : Nat))).compress).toOption.isNone
#guard (Args.parse "lsp" (String.ofList (List.replicate 4097 ' '))).toOption.isNone

#guard Operation.parse "lsp" == .ok .lsp
#guard Operation.all.map Operation.name == specs.toList.map (·.name)
#guard (Policy.parse (toJson ["lsp"])).toOption.map (·.names) == some ["lsp"]
#guard ((Args.parse "lsp" (args).compress) >>= AuthorizedArgs.check ⟨[]⟩ ["lsp"]).toOption.isNone
#guard ((Args.parse "lsp" (args).compress) >>= AuthorizedArgs.check Policy.all ["read"]).toOption.isNone
#guard ((Args.parse "lsp" (args).compress) >>= AuthorizedArgs.check ⟨[.lsp]⟩ ["lsp"]).isOk
#guard (specsForPolicy ⟨[]⟩ ["lsp"]).isEmpty
#guard (specsForPolicy ⟨[.lsp]⟩ ["lsp"]).map (·.name) == #["lsp"]
#guard ((BoundedPolicy.initial ⟨[.read, .lsp]⟩ |>.narrow ⟨[.read]⟩) >>= (·.narrow ⟨[.lsp]⟩)).toOption.isNone

end LodeTests.Lsp
