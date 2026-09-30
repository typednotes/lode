/- Actual Linen HTTP client and native SDK against the compiled broker. Fixture
   credentials arrive on stdin, stay in memory, and are never printed. -/
import Lode.Model

def main : IO Unit := do
  let json ← IO.ofExcept ((Lean.Json.parse (← (← IO.getStdin).getLine)).mapError IO.userError)
  let base ← IO.ofExcept ((json.getObjValAs? String "broker").mapError IO.userError)
  let provider := (json.getObjValAs? String "provider").toOption.getD "openai"
  let credentials ← IO.ofExcept ((json.getObjVal? "credentials" >>= fun value =>
    Lode.Liaison.Credentials.parse value "fixture" [provider]).mapError IO.userError)
  let model := if provider == "radius" then "radius-fixture" else "gpt-4o-mini"
  if provider == "openai" then
    let response ← Lode.Liaison.call base credentials "inference.generate" [model]
      (Lean.Json.mkObj [("messages", Lean.toJson #[Lean.Json.mkObj [("role", "user"), ("content", "hello")]])]) 5000
    unless response.status == 200 do throw (IO.userError "native SDK fixture was not relayed")
    let answer ← IO.ofExcept ((Lean.Json.parse (Lode.Liaison.text response) >>= Lode.Model.openaiReply).mapError IO.userError)
    unless answer.text == "hello" do throw (IO.userError "unexpected native provider fixture reply")
    IO.println "PASS: real native SDK inference transport and model reply parser"
  let abort ← IO.mkRef false
  let config : Lode.Model.Config := { api := if provider == "radius" then .pi else .openai, name := model, baseUrl := "https://fixture.invalid/v1" }
  let reply ← Lode.Model.complete config (.liaison base credentials) "Fixture writer"
    #[{name := "todo", description := "Local fixture function", schema := Lean.Json.mkObj [("type", "object")]}]
    #[.user "hello"] 0 5000 abort "fixture-session" (some "user")
  unless reply.text == "hello" do throw (IO.userError "unexpected native writer fixture reply")
  IO.println s!"PASS: real native writer context/function-tool transport ({provider})"
  let recovered ← Lode.Model.complete config (.liaison base credentials) "Fixture writer"
    #[{name := "todo", description := "Current local metadata", schema := Lean.Json.mkObj [("type", "object")]}]
    #[.user "hello", .assistant "old exchange" #[{id := "retired-read", name := "read", arguments := "{}"}],
      .toolResults #[{id := "retired-read", name := "read", content := "retired result", isError := false}]]
    1 5000 abort "fixture-session" (some "agent")
  unless recovered.text == "hello" do throw (IO.userError "narrowed writer history did not recover")
  IO.println s!"PASS: retired tool history recovered within new broker bounds ({provider})"
