/- Integration entry point: uses the actual typed and authorized dispatcher.
   Only test-controlled session Env values arrive on stdin. -/
import Lode.Tools

open Lean (Json toJson)

def main : IO Unit := do
  let request ← IO.ofExcept ((Json.parse (← (← IO.getStdin).getLine)).mapError IO.userError)
  let root : String ← IO.ofExcept ((request.getObjValAs? String "root").mapError IO.userError)
  let project := (request.getObjValAs? (List String) "project").toOption.getD []
  let timeout := (request.getObjValAs? Nat "timeoutMs").toOption.getD 30000
  let policy ← IO.ofExcept ((request.getObjValAs? Lode.Tools.Policy "policy").mapError IO.userError)
  let agent : List String ← IO.ofExcept ((request.getObjValAs? (List String) "agent").mapError IO.userError)
  let arguments ← IO.ofExcept ((request.getObjVal? "arguments").mapError IO.userError)
  let abort ← IO.mkRef ((request.getObjValAs? Bool "aborted").toOption.getD false)
  if let .ok delay := request.getObjValAs? Nat "abortAfterMs" then
    let _ ← IO.asTask (do IO.sleep delay.toUInt32; abort.set true) .dedicated
  let env : Lode.Tools.Env := {
    root := root
    project
    abort
    checkTimeoutMs := timeout
    todos := ← IO.mkRef #[]
    seed := pure ()
    publish := fun _ => throw (IO.userError "unexpected publication")
    lunBuild := throw (IO.userError "unexpected build")
    lunCall := fun _ _ _ => throw (IO.userError "unexpected runtime call") }
  let result ← Lode.Tools.execute env policy agent {
    id := "lsp-test", name := "lsp", arguments := arguments.compress }
  IO.println ((Json.mkObj [("content", toJson result.content), ("isError", toJson result.isError)]).compress)
