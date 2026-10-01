/-
  Lode.Lsp — bounded, read-only Lean 4.34 language-server queries.

  One `lake serve` process group per call, with service credentials stripped.
  The worker consumes private document/position witnesses, never a caller's
  method, URI, JSON-RPC payload, command or code action. Like `lake build`,
  elaboration and the lakefile run inside the existing container trust boundary.
-/
import Lean.Data.Lsp.Communication
import Lean.Data.Lsp.LanguageFeatures
import Lean.Data.Lsp.Diagnostics
import Lean.Data.Lsp.Extra
import Lean.Data.Lsp.Utf16
import Lode.Process

namespace Lode.Lsp

open Lean (Json toJson fromJson?)
open System (FilePath)

/-- Fixed budgets, including notifications discarded while waiting for a reply. -/
def maxDocumentBytes : Nat := 1048576
def maxFrameBytes : Nat := 262144
def maxWireBytes : Nat := 1048576
def maxHeaderBytes : Nat := 1024
def maxMessages : Nat := 256
def maxResultBytes : Nat := 50000
def maxTimeoutMs : Nat := 30000

/-- No arbitrary RPC, mutation, resolve, execute-command or code-action case. -/
inductive Query where
  | hover | definition | completion | diagnostics | goals
  deriving DecidableEq, Repr

def Query.name : Query → String
  | .hover => "hover" | .definition => "definition" | .completion => "completion"
  | .diagnostics => "diagnostics" | .goals => "goals"

def Query.method : Query → String
  | .hover => "textDocument/hover"
  | .definition => "textDocument/definition"
  | .completion => "textDocument/completion"
  | .diagnostics => "textDocument/waitForDiagnostics"
  | .goals => "$/lean/plainGoal"

def Query.parse : String → Except String Query
  | "hover" => .ok .hover | "definition" => .ok .definition
  | "completion" => .ok .completion | "diagnostics" => .ok .diagnostics
  | "goals" => .ok .goals
  | _ => .error "lsp.operation: hover, definition, completion, diagnostics or goals"

theorem Query.read_only (q : Query) : q.method ∈
    ["textDocument/hover", "textDocument/definition", "textDocument/completion",
     "textDocument/waitForDiagnostics", "$/lean/plainGoal"] := by
  cases q <;> simp [Query.method]

/-- A deliberately narrow relative document grammar, not a URI grammar.
    Unicode names and spaces are supported; separators, controls, percent
    escapes, dot components and bookkeeping directories are not. -/
def validDocumentPath (p : String) : Bool :=
  !p.isEmpty && p.utf8ByteSize ≤ 1024 && p.endsWith ".lean" &&
  ((p.splitOn "/").getLast!).length > 5 &&
  (p.splitOn "/").all (fun c => !c.isEmpty && c != "." && c != ".." &&
    c != ".git" && c != ".lake" && c.all (fun ch =>
      ch.toNat ≥ 32 && ch.toNat != 127 && !"\\:%?#".toList.contains ch))

/-- Only the parser can construct a relative document name. -/
structure DocumentPath where
  private mk ::
  value : String
  valid : validDocumentPath value = true

def DocumentPath.parse (p : String) : Except String DocumentPath :=
  if h : validDocumentPath p = true then .ok ⟨p, h⟩
  else .error "lsp.path: expected a relative .lean file without traversal, URI escapes or bookkeeping directories"

theorem DocumentPath.validated (p : DocumentPath) : validDocumentPath p.value = true := p.valid

/-- Raw tool data; UTF-16 position validity is checked against the disk snapshot. -/
structure Arguments where
  query : Query
  path : DocumentPath
  position : Option Lean.Lsp.Position

/-- Reject unknown fields rather than silently accepting method/URI injection. -/
def Arguments.parse (j : Json) : Except String Arguments := do
  let fields ← j.getObj?
  unless fields.toList.all (fun (k, _) => ["operation", "path", "line", "character"].contains k) do
    throw "lsp: only operation, path, line and character are accepted"
  let query ← Query.parse (← j.getObjValAs? String "operation")
  let path ← DocumentPath.parse (← j.getObjValAs? String "path")
  if query == .diagnostics then
    unless !(j.getObjVal? "line").isOk && !(j.getObjVal? "character").isOk do
      throw "lsp.diagnostics: positions are not accepted"
    return ⟨query, path, none⟩
  let line ← j.getObjValAs? Nat "line"
  let character ← j.getObjValAs? Nat "character"
  unless line ≤ maxDocumentBytes && character ≤ maxDocumentBytes do
    throw "lsp: position exceeds document budget"
  return ⟨query, path, some ⟨line, character⟩⟩

/-- Scalar boundaries in UTF-16, including the end of the line. A supplementary
    scalar occupies two units: its middle is never a valid cursor position. -/
def utf16Boundaries (s : String) : List Nat :=
  (s.toList.foldl (fun (acc : List Nat × Nat) c =>
    let n := acc.2 + (Lean.Char.utf16Size c).toNat
    (n :: acc.1, n)) ([0], 0)).1

def validPosition (text : String) (p : Lean.Lsp.Position) : Bool :=
  match (text.splitOn "\n")[p.line]? with
  | none => false
  | some line => (utf16Boundaries ((line.dropSuffix "\r").toString)).contains p.character

private def components (p : FilePath) : List String := p.components.filter (!·.isEmpty)

/-- Canonical paths use component-wise containment, not a vulnerable string prefix. -/
def within (root file : FilePath) : Prop := (components root).isPrefixOf (components file) = true
instance (root file : FilePath) : Decidable (within root file) :=
  inferInstanceAs (Decidable ((components root).isPrefixOf (components file) = true))

/-- Validated canonical file and bounded UTF-8 disk snapshot. The OS realpath,
    regular-file check and subsequent open are the trusted filesystem boundary. -/
structure WorkspaceDocument (root : FilePath) where
  private mk ::
  path : FilePath
  confined : within root path
  leanFile : path.toString.endsWith ".lean" = true
  text : String
  bounded : text.utf8ByteSize ≤ maxDocumentBytes

theorem WorkspaceDocument.scope_confined (d : WorkspaceDocument root) : within root d.path := d.confined
theorem WorkspaceDocument.size_bounded (d : WorkspaceDocument root) : d.text.utf8ByteSize ≤ maxDocumentBytes := d.bounded

private def boundedFile (path : FilePath) : IO String := do
  let info ← path.metadata
  unless info.type == .file && info.byteSize.toNat ≤ maxDocumentBytes do
    throw (IO.userError "lsp: document must be a regular file within the byte budget")
  IO.FS.withFile path .read fun h => do
    let mut bytes := ByteArray.empty
    repeat
      let chunk ← h.read (min 8192 (maxDocumentBytes + 1 - bytes.size)).toUSize
      if chunk.isEmpty then break
      bytes := bytes ++ chunk
      if bytes.size > maxDocumentBytes then throw (IO.userError "lsp: document byte budget exceeded")
    let some text := String.fromUTF8? bytes | throw (IO.userError "lsp: document is not UTF-8")
    return text

private def openDocument (root project : FilePath) (p : DocumentPath) : IO (WorkspaceDocument root) := do
  let project ← IO.FS.realPath project
  unless within root project do throw (IO.userError "lsp: project leads outside the checkout")
  let path ← IO.FS.realPath (project / p.value)
  if hc : within root path then
    if hl : path.toString.endsWith ".lean" = true then
      -- The resolved name must not lead into .git/.lake either.
      unless validDocumentPath ("/".intercalate ((components path).drop (components root).length)) do
        throw (IO.userError "lsp: resolved document is not an authorized Lean document")
      let text ← boundedFile path
      if hb : text.utf8ByteSize ≤ maxDocumentBytes then return ⟨path, hc, hl, text, hb⟩
      else throw (IO.userError "lsp: document byte budget exceeded")
    else throw (IO.userError "lsp: resolved document is not a .lean file")
  else throw (IO.userError "lsp: document leads outside the checkout")

/-- Execution consumes both workspace and position evidence, with a finite method. -/
structure Request (root : FilePath) where
  private mk ::
  document : WorkspaceDocument root
  query : Query
  position : Option Lean.Lsp.Position
  positionValid : ∀ p ∈ position, validPosition document.text p = true
  positionShape : (query = .diagnostics ↔ position = none)

def Request.method (r : Request root) : String := r.query.method
theorem Request.method_read_only (r : Request root) : r.method ∈
    ["textDocument/hover", "textDocument/definition", "textDocument/completion",
     "textDocument/waitForDiagnostics", "$/lean/plainGoal"] := Query.read_only r.query

private def validateRequest (doc : WorkspaceDocument root) (a : Arguments) : IO (Request root) := do
  if hv : ∀ p ∈ a.position, validPosition doc.text p = true then
    if hs : a.query = .diagnostics ↔ a.position = none then return ⟨doc, a.query, a.position, hv, hs⟩
    else throw (IO.userError "lsp: this operation requires a position")
  else throw (IO.userError "lsp: position is outside the document or splits a UTF-16 surrogate pair")

-- ── Bounded Content-Length transport ─────────────────────────────────────────

/-- Header parser shared by the real pipe reader and kernel-evaluated tests. -/
def frameLength (header : String) : Except String Nat := do
  unless header.utf8ByteSize ≤ maxHeaderBytes && header.endsWith "\r\n\r\n" do
    throw "lsp: malformed or oversized header"
  let lines := (header.dropEnd 4).toString.splitOn "\r\n"
  let mut length : Option Nat := none
  for line in lines do
    if line.startsWith "Content-Length: " then
      let value := (line.drop 16).toString
      unless length.isNone && !value.isEmpty && value.length ≤ 7 && value.all Char.isDigit do
        throw "lsp: invalid or duplicate Content-Length"
      length := value.toNat?
    else unless line == "Content-Type: application/vscode-jsonrpc; charset=utf-8" do
      throw "lsp: unsupported frame header"
  let some n := length | throw "lsp: missing Content-Length"
  unless n > 0 && n ≤ maxFrameBytes do throw "lsp: frame byte budget exceeded"
  return n

/-- Bound nesting and numeric tokens before Lean's recursive JSON decoder.
    Scientific exponents are not needed by this LSP subset and are refused:
    Lean's JSON decoder expands positive exponents into arbitrary-sized integers.
    Quoted brackets, digits and escaped quotes do not contribute to the budgets. -/
def shallowJson (s : String) : Bool := Id.run do
  let mut depth := 0
  let mut quoted := false
  let mut escaped := false
  let mut numberChars := 0
  for c in s.toList do
    if quoted then
      if escaped then escaped := false
      else if c == '\\' then escaped := true
      else if c == '"' then quoted := false
    else
      if c.isDigit || c == '-' || c == '.' then
        numberChars := numberChars + 1
        if numberChars > 20 then return false
      else
        if numberChars > 0 && (c == 'e' || c == 'E') then return false
        numberChars := 0
      if c == '"' then quoted := true
      else if c == '{' || c == '[' then
        depth := depth + 1
        if depth > 64 then return false
      else if c == '}' || c == ']' then
        if depth == 0 then return false
        depth := depth - 1
  return depth == 0 && !quoted

private def readFrame (h : IO.FS.Handle) : IO (Json × Nat) := do
  let mut header := ByteArray.empty
  let mut done_ := false
  for _ in [:maxHeaderBytes] do
    let byte ← h.read 1
    if byte.isEmpty then throw (IO.userError "lsp: unexpected EOF in header")
    header := header ++ byte
    if header.size ≥ 4 && header.extract (header.size - 4) header.size == "\r\n\r\n".toUTF8 then
      done_ := true
      break
  unless done_ do throw (IO.userError "lsp: header byte budget exceeded")
  let some text := String.fromUTF8? header | throw (IO.userError "lsp: invalid header encoding")
  let n ← IO.ofExcept ((frameLength text).mapError IO.userError)
  let mut body := ByteArray.empty
  repeat
    if body.size == n then break
    let bytes ← h.read (min 8192 (n - body.size)).toUSize
    if bytes.isEmpty then throw (IO.userError "lsp: unexpected EOF in body")
    body := body ++ bytes
  let some text := String.fromUTF8? body | throw (IO.userError "lsp: invalid response encoding")
  unless shallowJson text do throw (IO.userError "lsp: invalid or excessively nested JSON")
  let j ← IO.ofExcept ((Json.parse text).mapError (fun _ => IO.userError "lsp: malformed response JSON"))
  unless (j.getObjValAs? String "jsonrpc").toOption == some "2.0" do
    throw (IO.userError "lsp: invalid JSON-RPC envelope")
  return (j, header.size + n)

private def send (h : IO.FS.Handle) (id : Option Nat) (method : String) (params : Json) : IO Unit := do
  let fields : List (String × Json) := [("jsonrpc", "2.0"), ("method", toJson method), ("params", params)]
  let j := Json.mkObj (fields ++
    (id.map (fun n => [("id", toJson n)])).getD [])
  Lean.IO.FS.Stream.writeSerializedLspMessage (IO.FS.Stream.ofHandle h) j.compress

private structure Budget where
  bytes : Nat := 0
  messages : Nat := 0

private def receive (h : IO.FS.Handle) (budget : IO.Ref Budget) : IO Json := do
  let old ← budget.get
  unless old.messages < maxMessages && old.bytes + maxHeaderBytes + maxFrameBytes ≤ maxWireBytes do
    throw (IO.userError "lsp: wire/message budget exceeded")
  let (j, size) ← readFrame h
  budget.set ⟨old.bytes + size, old.messages + 1⟩
  return j

private def awaitReply (h : IO.FS.Handle) (budget : IO.Ref Budget) (id : Nat)
    (uri : String) (diagnostics : IO.Ref (Array Lean.Lsp.Diagnostic)) : IO Json := do
  repeat
    let j ← receive h budget
    -- Lean 4.34 unconditionally asks for a file watcher after initialization
    -- (Watchdog.initAndRunWatchdogAux). This ephemeral client has no watcher;
    -- like Lean's own test IPC client, discard this fixed registration only.
    if (j.getObjValAs? String "method").toOption == some "client/registerCapability" &&
        (j.getObjValAs? String "id").toOption == some "register_lean_watcher" then continue
    -- FileWorker.runRefreshTasks may issue these even when no editor feature
    -- was requested. This client has no hints/tokens to refresh; discarding the
    -- two fixed methods performs no action and does not widen query authority.
    if ["workspace/inlayHint/refresh", "workspace/semanticTokens/refresh"].contains
        ((j.getObjValAs? String "method").toOption.getD "") &&
        (j.getObjValAs? Nat "id").isOk &&
        (!(j.getObjVal? "params").isOk || (j.getObjVal? "params").toOption == some Json.null) then continue
    -- Server request IDs live in a separate direction/namespace: a harmless
    -- refresh can have the same number as the response we are awaiting.
    if (j.getObjVal? "id").toOption == some (toJson id) then
      unless !(j.getObjVal? "method").isOk &&
          ((j.getObjVal? "result").isOk != (j.getObjVal? "error").isOk) do
        throw (IO.userError "lsp: invalid response envelope")
      if (j.getObjVal? "error").isOk then throw (IO.userError "lsp: language server refused the request")
      return ← IO.ofExcept ((j.getObjVal? "result").mapError (fun _ => IO.userError "lsp: missing response result"))
    -- Server-initiated requests are not executed or reflected into a client tool.
    if (j.getObjVal? "id").isOk then throw (IO.userError "lsp: unsolicited server request/response")
    unless (j.getObjValAs? String "method").isOk do throw (IO.userError "lsp: invalid notification envelope")
    if (j.getObjValAs? String "method").toOption == some "textDocument/publishDiagnostics" then
      let p : Lean.Lsp.PublishDiagnosticsParams ← IO.ofExcept
        ((j.getObjValAs? Lean.Lsp.PublishDiagnosticsParams "params").mapError
          (fun _ => IO.userError "lsp: malformed diagnostics"))
      if p.uri == uri && p.version? == some 1 then
        if p.isIncremental?.getD false then diagnostics.modify (· ++ p.diagnostics)
        else diagnostics.set p.diagnostics
  throw (IO.userError "lsp: missing response")

-- ── Data-only result projection ──────────────────────────────────────────────

/-- Do not return raw server objects: strings carrying absolute paths or file
    URIs are suppressed, including Markdown links. Location objects are separately
    canonicalized. Commands, completion data/edits and diagnostic data are omitted. -/
def safeText (s : String) : String :=
  let tokens := s.toLower.splitOn "file:"
  let words := (s.map (fun c => if c.isWhitespace || "`\"'()[]<>=:;,".toList.contains c then ' ' else c)).splitOn " "
  if tokens.length > 1 || words.any (fun w => w.startsWith "/" || w.startsWith "\\" ||
      ((w.toList.drop 1).head? == some ':')) then
    "[text containing a filesystem path omitted]"
  else (s.take 12000).toString

/-- Data-only returned locations also carry confinement evidence. -/
structure WorkspaceLocation (root : FilePath) where
  private mk ::
  path : FilePath
  confined : within root path
  relativeValid : validDocumentPath ("/".intercalate ((components path).drop (components root).length)) = true

def WorkspaceLocation.relative (p : WorkspaceLocation root) : String :=
  "/".intercalate ((components p.path).drop (components root).length)

theorem WorkspaceLocation.scope_confined (p : WorkspaceLocation root) : within root p.path := p.confined
theorem WorkspaceLocation.relative_valid (p : WorkspaceLocation root) : validDocumentPath p.relative = true := p.relativeValid

/-- Returned locations must be canonical file URIs inside the same checkout.
    No file is opened to follow a returned definition. -/
private def locationPath (root : FilePath) (uri : String) : IO (Option (WorkspaceLocation root)) := do
  unless uri.startsWith "file:///" do return none
  -- Core's fileUriToPath? calls String.fromUTF8! on percent-decoded bytes.
  -- Validate those bytes first, so hostile %FF/control sequences cannot panic
  -- or reach OS path APIs with an embedded NUL. URI rendering remains core's.
  let raw := (uri.drop 7).toString.toUTF8
  let hex (b : UInt8) : Option UInt8 :=
    if b ≥ 48 && b ≤ 57 then some (b - 48)
    else if b ≥ 65 && b ≤ 70 then some (b - 65 + 10)
    else if b ≥ 97 && b ≤ 102 then some (b - 97 + 10)
    else none
  let mut decoded := ByteArray.empty
  let mut i : Nat := 0
  while i < raw.size do
    if raw[i]! == 37 then
      if i + 2 ≥ raw.size then return none
      let some a := hex raw[i + 1]! | return none
      let some b := hex raw[i + 2]! | return none
      decoded := decoded.push (a * 16 + b)
      i := i + 3
    else
      decoded := decoded.push raw[i]!
      i := i + 1
  let some decodedPath := String.fromUTF8? decoded | return none
  unless decodedPath.all (fun (c : Char) => c.toNat ≥ 32 && c.toNat != 127) do return none
  let some path := System.Uri.fileUriToPath? uri | return none
  unless System.Uri.pathToUri path == uri do return none
  try
    let real ← IO.FS.realPath path
    if hc : within root real then
      if hr : validDocumentPath ("/".intercalate ((components real).drop (components root).length)) = true then
        return some ⟨real, hc, hr⟩
      else return none
    else return none
  catch _ => return none

private def projectResult (r : Request root) (result : Json)
    (diagnostics : Array Lean.Lsp.Diagnostic) : IO Json := do
  let decode (α : Type) [Lean.FromJson α] : IO α :=
    IO.ofExcept ((fromJson? result).mapError (fun _ => IO.userError "lsp: unexpected result shape"))
  match r.query with
  | .diagnostics =>
    return toJson (diagnostics.map fun d => Json.mkObj [
      ("range", toJson d.range), ("severity", toJson d.severity?), ("message", toJson (safeText d.message))])
  | .hover =>
    let hover : Option Lean.Lsp.Hover ← decode _
    return (hover.map fun h => Json.mkObj [
      ("text", toJson (safeText h.contents.value)), ("range", toJson h.range?)]).getD Json.null
  | .goals =>
    let goals : Option Lean.Lsp.PlainGoal ← decode _
    return (goals.map fun g => Json.mkObj [
      ("rendered", toJson (safeText g.rendered)), ("goals", toJson (g.goals.map safeText))]).getD Json.null
  | .completion =>
    let list : Lean.Lsp.CompletionList ← decode _
    -- Lean returns fuzzy matches in environment traversal order, not relevance
    -- order. Preserve exact-prefix matches before truncating the item budget.
    let pos := r.position.getD ⟨0, 0⟩
    let line := (r.document.text.splitOn "\n")[pos.line]?.getD ""
    let before := (line.take (Lean.String.utf16PosToCodepointPos line pos.character)).toString
    let prefixText := String.ofList ((before.toList.reverse.takeWhile
      (fun c => c.isAlphanum || c == '_' || c == '.' || c == '\'')).reverse)
    let exact := list.items.filter (fun item => item.label.startsWith prefixText)
    let other := list.items.filter (fun item => !item.label.startsWith prefixText)
    let items := exact ++ other
    return Json.mkObj [("isIncomplete", toJson list.isIncomplete), ("items", toJson
      ((items.take 100).map fun item => Json.mkObj [
        ("label", toJson (safeText item.label)), ("detail", toJson (item.detail?.map safeText)),
        ("kind", toJson item.kind?)])), ("truncated", toJson (decide (list.items.size > 100)))]
  | .definition =>
    let links ← result.getArr?.mapError (fun _ => IO.userError "lsp: unexpected definition shape") |> IO.ofExcept
    let mut locations := #[]
    let mut omitted := 0
    for link in links do
      let uri := (link.getObjValAs? String "targetUri").toOption.orElse
        (fun _ => (link.getObjValAs? String "uri").toOption)
      let range := (link.getObjValAs? Lean.Lsp.Range "targetSelectionRange").toOption.orElse
        (fun _ => (link.getObjValAs? Lean.Lsp.Range "range").toOption)
      if let (some uri, some range) := (uri, range) then
        if let some path ← locationPath root uri then
          locations := locations.push (Json.mkObj [("path", toJson path.relative), ("range", toJson range)])
        else omitted := omitted + 1
      else throw (IO.userError "lsp: malformed definition location")
    return Json.mkObj [("locations", toJson locations), ("omitted", toJson omitted)]

private def converse (stdin stdout : IO.FS.Handle) (r : Request root) : IO Json := do
  let budget ← IO.mkRef ({} : Budget)
  let diagnostics ← IO.mkRef (#[] : Array Lean.Lsp.Diagnostic)
  let uri := System.Uri.pathToUri r.document.path
  send stdin (some 1) "initialize" (Json.mkObj [("processId", Json.null),
    ("rootUri", toJson (System.Uri.pathToUri root)), ("capabilities", Json.mkObj [])])
  let _ ← awaitReply stdout budget 1 uri diagnostics
  send stdin none "initialized" (Json.mkObj [])
  let params : Lean.Lsp.LeanDidOpenTextDocumentParams := {
    textDocument := {uri, languageId := "lean4", version := 1, text := r.document.text}
    dependencyBuildMode? := some .never }
  send stdin none "textDocument/didOpen" (toJson params)
  -- The reporter and all command snapshots finish before this barrier replies.
  send stdin (some 2) Query.diagnostics.method (toJson (Lean.Lsp.WaitForDiagnosticsParams.mk uri 1))
  let barrier ← awaitReply stdout budget 2 uri diagnostics
  let result ← if r.query == .diagnostics then pure barrier else do
    let params : Lean.Lsp.TextDocumentPositionParams := {textDocument := ⟨uri⟩, position := r.position.getD ⟨0, 0⟩}
    send stdin (some 3) r.method (toJson params)
    awaitReply stdout budget 3 uri diagnostics
  projectResult r result (← diagnostics.get)

/-- Internal protocol is isolated in a killable process group. Polling bounds
    blocked writes, partial frames, silent servers and aborts. Cleanup occurs on
    success as well as failure; no unbounded stdout/stderr capture is used. -/
private def worker (project : FilePath) (abort : IO.Ref Bool) (timeoutMs : Nat)
    (r : Request root) : IO Json := do
  if ← abort.get then throw (IO.userError "lsp: aborted")
  let child ← IO.Process.spawn {
    cmd := "lake"
    args := #["serve"]
    cwd := some project
    env := Process.toolEnv
    setsid := true
    stdin := .piped
    stdout := .piped
    stderr := .null }
  let (stdin, child) ← child.takeStdin
  let task ← IO.asTask (converse stdin child.stdout r) .dedicated
  let deadline := (← IO.monoMsNow) + min timeoutMs maxTimeoutMs
  try
    repeat
      if ← IO.hasFinished task then return ← IO.ofExcept (← IO.wait task)
      if ← abort.get then throw (IO.userError "lsp: aborted")
      if (← IO.monoMsNow) ≥ deadline then throw (IO.userError "lsp: timed out")
      IO.sleep 10
    throw (IO.userError "lsp: worker stopped")
  finally
    System.Process.killGroup child.pid
    let _ ← child.wait
    -- Killing the group closes both pipes and joins the bounded reader task.
    let _ ← IO.wait task

/-- Called only from the authorized Tools dispatcher. No session Env additions.
    Filesystem/OS errors are deliberately not reflected as raw host paths. -/
def run (root project : FilePath) (abort : IO.Ref Bool) (timeoutMs : Nat)
    (args : Arguments) : IO (String × Bool) := do
  try
    if ← abort.get then return ("lsp: aborted", true)
    let root ← IO.FS.realPath root
    let project ← IO.FS.realPath project
    let doc ← openDocument root project args.path
    let request ← validateRequest doc args
    let result ← worker project abort timeoutMs request
    let output := (Json.mkObj [("operation", toJson args.query.name),
      ("path", toJson args.path.value), ("positionEncoding", "utf-16"), ("result", result)]).compress
    if output.utf8ByteSize > maxResultBytes then return ("lsp: result byte budget exceeded", true)
    return (output, false)
  catch e =>
    let detail := e.toString
    if detail.startsWith "lsp:" then return (safeText detail, true)
    else return ("lsp: document or language server unavailable", true)

end Lode.Lsp
