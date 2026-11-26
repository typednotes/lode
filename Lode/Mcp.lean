/- An MCP stdio adapter for individually configured tools. -/
import Lode.Extension
import Lode.Process
import Linen.System.Worker

namespace Lode.Mcp

open Lean (Json toJson)
open System.Worker (Worker Line)

/-- A trusted executable and fixed arguments configured by the extension author. -/
structure Stdio where
  command : String
  args : Array String := #[]

/-- Protocol revision offered during initialization. -/
def protocolVersion := "2025-11-25"

private def rpc (method : String) (id : Nat) (params : Json) : Json :=
  Json.mkObj [("jsonrpc", "2.0"), ("id", toJson id), ("method", .str method), ("params", params)]

/-- Accept only the matching JSON-RPC result and reject error or mixed envelopes. -/
def response (id : Nat) (text : String) : Except String Json := do
  if text.utf8ByteSize > 64 * 1024 then throw "MCP reply exceeds 64 KiB"
  let envelope ← (Json.parse text).mapError (fun _ => "MCP reply is not JSON")
  unless (envelope.getObjValAs? String "jsonrpc").toOption == some "2.0" &&
      (envelope.getObjValAs? Nat "id").toOption == some id do
    throw "MCP reply has the wrong version or request id"
  if (envelope.getObjVal? "error").isOk then throw "MCP server returned a JSON-RPC error"
  (envelope.getObjVal? "result").mapError (fun _ => "MCP reply has no result")

private def remaining (deadline : Nat) : IO Nat := do
  let now ← IO.monoMsNow
  unless now < deadline do throw (IO.userError "MCP tool timed out")
  return deadline - now

private def call (worker : Worker) (deadline : Nat) (method : String) (id : Nat) (params : Json) : IO Json := do
  let line ← IO.ofExcept ((Line.check (rpc method id params).compress).mapError IO.userError)
  let raw ← worker.call line (← remaining deadline)
  IO.ofExcept ((response id raw).mapError IO.userError)

private def initializeWorker (worker : Worker) (deadline : Nat) : IO Unit := do
  let result ← call worker deadline "initialize" 1 (Json.mkObj [
    ("protocolVersion", .str protocolVersion), ("capabilities", Json.mkObj []),
    ("clientInfo", Json.mkObj [("name", "lode"), ("version", "1")])])
  unless (result.getObjValAs? String "protocolVersion").toOption == some protocolVersion do
    throw (IO.userError "MCP server did not negotiate the offered protocol version")
  let caps := (result.getObjVal? "capabilities").toOption
  unless caps.any (fun caps => ((caps.getObjVal? "tools").toOption.bind (·.getObj?.toOption)).isSome) do
    throw (IO.userError "MCP server did not advertise tools")
  -- The initialization request has been consumed and the input pipe is empty.
  -- This fixed notification fits in a single atomic pipe write.
  worker.child.stdin.putStrLn "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
  worker.child.stdin.flush

private def invoke (stdio : Stdio) (remoteName : String) (ctx : Extension.Context) (input : Json) :
    IO (String × Bool) := do
  if ← ctx.abort.get then return ("MCP tool aborted", true)
  let deadline := (← IO.monoMsNow) + min ctx.timeoutMs 30000
  let worker ← System.Worker.spawn stdio.command stdio.args Process.toolEnv
  let done ← IO.mkRef false
  let watchdog ← IO.asTask (do
    repeat
      if ← done.get then break
      if ← ctx.abort.get then
        worker.stop
        break
      IO.sleep 25) .dedicated
  try
    initializeWorker worker deadline
    let result ← call worker deadline "tools/call" 2 (Json.mkObj [("name", .str remoteName), ("arguments", input)])
    let content ← IO.ofExcept ((result.getObjValAs? (Array Json) "content").mapError (fun _ =>
      IO.userError "MCP tool result must contain a content array"))
    let isError ← match result.getObjVal? "isError" with
      | .ok value => IO.ofExcept (value.getBool?.mapError (fun _ => IO.userError "MCP tool error flag must be boolean"))
      | .error _ => pure false
    let output := (result.getObjVal? "structuredContent").toOption.getD (.arr content)
    return (output.compress, isError)
  finally
    done.set true
    worker.stop
    let _ ← IO.wait watchdog

/-- Adapt one statically named MCP tool into Lode's compiled catalog. The
    supplied decoder validates model data before a subprocess is started. -/
def stdioTool (server : Stdio) (remoteName name description : String) (schema : Json)
    (validate : Json → Except String Json) : Extension.Tool :=
  Extension.Tool.define name description schema validate (invoke server remoteName)

end Lode.Mcp
