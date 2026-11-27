/- MCP stdio and bounded Streamable HTTP for individually configured tools. -/
import Lode.Extension
import Lode.Http
import Lode.Process
import Lode.Secrets
import Linen.System.Worker

namespace Lode.Mcp

open Lean (Json toJson)
open System.Worker (Worker Line)
open Network.HTTP.Client (Response)
open Network.HTTP.Types (StdMethod hContentType)

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

private def initializeParams : Json := Json.mkObj [
    ("protocolVersion", .str protocolVersion), ("capabilities", Json.mkObj []),
    ("clientInfo", Json.mkObj [("name", "lode"), ("version", "1")])]

private def initialized : String := "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"

private def checkInit (result : Json) : IO Unit := do
  unless (result.getObjValAs? String "protocolVersion").toOption == some protocolVersion do
    throw (IO.userError "MCP server did not negotiate the offered protocol version")
  let caps := (result.getObjVal? "capabilities").toOption
  unless caps.any (fun caps => ((caps.getObjVal? "tools").toOption.bind (·.getObj?.toOption)).isSome) do
    throw (IO.userError "MCP server did not advertise tools")

private def initializeWorker (worker : Worker) (deadline : Nat) : IO Unit := do
  checkInit (← call worker deadline "initialize" 1 initializeParams)
  -- The initialization request has been consumed and the input pipe is empty.
  -- This fixed notification fits in a single atomic pipe write.
  worker.child.stdin.putStrLn initialized
  worker.child.stdin.flush

private def renderResult (result : Json) : IO (String × Bool) := do
  let content ← IO.ofExcept ((result.getObjValAs? (Array Json) "content").mapError (fun _ =>
    IO.userError "MCP tool result must contain a content array"))
  let isError ← match result.getObjVal? "isError" with
    | .ok value => IO.ofExcept (value.getBool?.mapError (fun _ => IO.userError "MCP tool error flag must be boolean"))
    | .error _ => pure false
  let output := (result.getObjVal? "structuredContent").toOption.getD (.arr content)
  return (output.compress, isError)

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
    renderResult (← call worker deadline "tools/call" 2 (Json.mkObj [("name", .str remoteName), ("arguments", input)]))
  finally
    done.set true
    worker.stop
    let _ ← IO.wait watchdog

/-- Adapt one statically named MCP tool into Lode's compiled catalog. The
    supplied decoder validates model data before a subprocess is started. -/
def stdioTool (server : Stdio) (remoteName name description : String) (schema : Json)
    (validate : Json → Except String Json) : Extension.Tool :=
  Extension.Tool.define name description schema validate (invoke server remoteName)

-- ── Streamable HTTP ─────────────────────────────────────────────────────────

/-- An operator-selected server endpoint and optional direct bearer. -/
structure HttpEndpoint where
  private mk ::
  url : String
  bearer : Option String

/-- Accept HTTPS or explicitly enabled loopback HTTP. The model cannot set
    this endpoint or its authentication headers. -/
def HttpEndpoint.check (url : String) (bearer : Option String := none) (allowLocal : Bool := false) :
    Except String HttpEndpoint := do
  unless (Validate.credentialUrl url allowLocal).isSome do throw "invalid MCP endpoint"
  unless bearer.all Secrets.validKey do throw "invalid MCP bearer token"
  return ⟨url, bearer⟩

/-- Decode a finite POST SSE response. The client declares no reverse RPC
    capabilities. Interleaved notifications carry no executable authority. -/
def sseResponse (id : Nat) (body : String) : Except String Json := do
  unless body.utf8ByteSize ≤ 65536 do throw "MCP event stream exceeds 64 KiB"
  let normalized := (body.replace "\r\n" "\n").replace "\r" "\n"
  let mut result : Option Json := none
  for frame in (normalized.splitOn "\n\n").dropLast do
    let fragments := (frame.splitOn "\n").filterMap fun line => do
      unless line.startsWith "data:" do none
      let text := (line.drop 5).toString
      pure (if text.startsWith " " then (text.drop 1).toString else text)
    let text := "\n".intercalate fragments
    if text.isEmpty then continue
    let json ← (Json.parse text).mapError (fun _ => "invalid MCP event data")
    if (json.getObjVal? "method").isOk then
      unless (json.getObjValAs? String "jsonrpc").toOption == some "2.0" &&
          (json.getObjValAs? String "method").isOk && !(json.getObjVal? "id").isOk do
        throw "MCP server requests are unavailable on the direct HTTP tool adapter"
    else
      unless result.isNone do throw "duplicate MCP response"
      result := some (← response id text)
  match result with
  | some value => pure value
  | none => throw "MCP event stream ended without a complete response"

private def httpSend (server : HttpEndpoint) (headers : List (String × String)) (method : StdMethod)
    (body : Option String) (timeout : Nat) : IO Response := do
  let auth := (server.bearer.map (fun bearer => [("authorization", "Bearer " ++ bearer)])).getD []
  try Http.request method server.url ([("accept", "application/json, text/event-stream"),
    ("content-type", "application/json")] ++ auth ++ headers) body timeout
  catch _ => throw (IO.userError "MCP HTTP transport failed")

private def httpDecode (reply : Response) (id : Nat) : IO Json := do
  unless Http.status reply == 200 do throw (IO.userError s!"MCP HTTP request returned status {Http.status reply}")
  unless reply.body.size ≤ 65536 do throw (IO.userError "MCP reply exceeds 64 KiB")
  let mime := ((reply.findHeader hContentType).getD "").splitOn ";" |>.headD "" |>.trimAscii.toString.toLower
  let result := match mime with
    | "text/event-stream" => sseResponse id (Http.text reply)
    | "application/json" => response id (Http.text reply)
    | _ => .error "unsupported MCP HTTP response media type"
  IO.ofExcept (result.mapError IO.userError)

private abbrev Request := Nat → String → Json → IO Json

private def withHttp (server : HttpEndpoint) (ctx : Extension.Context) (run : Request → IO α) : IO α := do
  let deadline := (← IO.monoMsNow) + min ctx.timeoutMs 30000
  let checkedTime : IO Nat := do
    if ← ctx.abort.get then throw (IO.userError "MCP tool aborted")
    remaining deadline
  let initial ← httpSend server [] .POST (some (rpc "initialize" 1 initializeParams).compress) (← checkedTime)
  let session := initial.findHeader (Data.CI.mk' "Mcp-Session-Id")
  unless session.all Secrets.validKey do throw (IO.userError "invalid MCP session ID")
  let headers := [("mcp-protocol-version", protocolVersion)] ++ (session.map (fun value => [("mcp-session-id", value)])).getD []
  try
    checkInit (← httpDecode initial 1)
    let ready ← httpSend server headers .POST (some initialized) (← checkedTime)
    unless Http.status ready == 202 && ready.body.isEmpty do
      throw (IO.userError "MCP server did not accept the initialized notification")
    run fun id method params => do
      let reply ← httpSend server headers .POST (some (rpc method id params).compress) (← checkedTime)
      let _ ← checkedTime
      httpDecode reply id
  finally
    if session.isSome then
      -- Best-effort close, including after cancellation or a rejected tool.
      try discard <| httpSend server headers .DELETE none 1000 catch _ => pure ()

/-- Description supplied by an MCP server's tool discovery response. -/
structure ToolInfo where
  name : String
  description : Option String := none
  inputSchema : Json
  deriving Lean.FromJson

private def discover (send : Request) : Nat → Nat → Option String → Array ToolInfo → IO (Nat × Array ToolInfo)
  | 0, _, _, _ => throw (IO.userError "MCP discovery exceeded eight pages")
  | fuel + 1, id, cursor, seen => do
    let result ← send id "tools/list" (Json.mkObj ((cursor.map (fun value => [("cursor", .str value)])).getD []))
    let tools ← IO.ofExcept ((result.getObjValAs? (Array ToolInfo) "tools").mapError (fun _ =>
      IO.userError "invalid MCP tool catalog"))
    unless tools.all (fun tool => !tool.name.isEmpty && tool.name.utf8ByteSize ≤ 256 && tool.inputSchema.getObj?.isOk) do
      throw (IO.userError "invalid MCP tool description")
    let next ← match result.getObjVal? "nextCursor" with
      | .error _ => pure none
      | .ok value => some <$> IO.ofExcept (value.getStr?.mapError (fun _ => IO.userError "invalid MCP discovery cursor"))
    let all := seen ++ tools
    match next with
    | none => pure (id + 1, all)
    | some _ => discover send fuel (id + 1) next all

/-- List a configured HTTP server's currently available tools. Discovery
    results are data. Registering a callable extension still needs a decoder. -/
def listHttpTools (server : HttpEndpoint) (ctx : Extension.Context) : IO (Array ToolInfo) :=
  withHttp server ctx fun send => (·.2) <$> discover send 8 2 none #[]

/-- Adapt one HTTP MCP tool. Confirm availability via discovery, then call
    the compiled tool name with the locally validated arguments. -/
def httpTool (server : HttpEndpoint) (remoteName name description : String) (schema : Json)
    (validate : Json → Except String Json) : Extension.Tool :=
  Extension.Tool.define name description schema validate fun ctx input =>
    withHttp server ctx fun send => do
      let (id, tools) ← discover send 8 2 none #[]
      unless tools.any (·.name == remoteName) do throw (IO.userError "configured MCP tool is unavailable")
      renderResult (← send id "tools/call" (Json.mkObj [("name", .str remoteName), ("arguments", input)]))

end Lode.Mcp
