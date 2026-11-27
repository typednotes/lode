import Lode.Mcp

open Lean Lode

private def validate (json : Json) : Except String Json := do
  let value ← json.getObjValAs? String "value"
  return Json.mkObj [("value", .str value)]

/-- Exercise the compiled adapters against a real subprocess or HTTP fixture. -/
def main (args : List String) : IO Unit := do
  let schema := Json.mkObj [("type", "object")]
  let context : Extension.Context := { project := ".", abort := ← IO.mkRef false, timeoutMs := 10000 }
  let tool ← match args with
    | [] => pure (Mcp.stdioTool { command := "python3", args := #["test/mock_mcp.py"] }
        "fixture_echo" "echo" "Echo the fixture argument." schema validate)
    | [url] => do
      let target ← IO.ofExcept ((Mcp.HttpEndpoint.check url (some "fixture-mcp-token") true).mapError IO.userError)
      let tools ← Mcp.listHttpTools target context
      unless tools.map (·.name) == #["other", "fixture_echo"] do throw (IO.userError "MCP HTTP discovery lost a page")
      pure (Mcp.httpTool target "fixture_echo" "echo" "Echo the fixture argument." schema validate)
    | _ => throw (IO.userError "expected one fixture URL")
  let catalog ← IO.ofExcept ((Extension.Catalog.check [tool]).mapError IO.userError)
  let rejected ← catalog.dispatch context "echo" (Json.mkObj [("value", toJson 42)])
  unless rejected.2 do throw (IO.userError "MCP adapter accepted an invalid argument")
  let (text, isError) ← catalog.dispatch context "echo" (Json.mkObj [("value", "hello")])
  unless !isError && text == "{\"echo\":\"hello\"}" do throw (IO.userError "MCP round trip failed")
  IO.println "PASS: MCP initialization, notification, typed call and cleanup"
