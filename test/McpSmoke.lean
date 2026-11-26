import Lode.Mcp

open Lean Lode

/-- Exercise the compiled adapter against a real stdio subprocess. -/
def main : IO Unit := do
  let schema := Json.mkObj [("type", "object")]
  let tool := Mcp.stdioTool { command := "python3", args := #["test/mock_mcp.py"] }
    "fixture_echo" "echo" "Echo the fixture argument." schema fun json => do
      let value ← json.getObjValAs? String "value"
      return Json.mkObj [("value", .str value)]
  let catalog ← IO.ofExcept ((Extension.Catalog.check [tool]).mapError IO.userError)
  let context : Extension.Context := { project := ".", abort := ← IO.mkRef false, timeoutMs := 3000 }
  let rejected ← catalog.dispatch context "echo" (Json.mkObj [("value", toJson 42)])
  unless rejected.2 do throw (IO.userError "MCP adapter accepted an invalid argument")
  let (text, isError) ← catalog.dispatch context "echo" (Json.mkObj [("value", "hello")])
  unless !isError && text == "{\"echo\":\"hello\"}" do throw (IO.userError "MCP stdio round trip failed")
  IO.println "PASS: MCP initialization, notification, typed tool call and subprocess cleanup"
