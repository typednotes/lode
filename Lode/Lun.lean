/-
  Lode.Lun — having lun build and run what lode wrote

  lun (`typednotes/lun`) compiles a Lean project at a commit into typed
  services: one per **function** (a function of the project under a declared
  signature ending in linen's `Eff`) and one per **graph** of functions (a
  program in linen's `Reactive` monad). lode's product is exactly such a
  project, so its last steps are lun's: build the published commit, read the
  diagnostics lun attributes to each function and graph, fix, publish again,
  and call the result. The vocabulary is lun's (≥ 0.2.0), which is linen's:
  functions and graphs.

  **`lun.json`.** What to build is part of the project, not of the
  conversation: a `lun.json` in the project directory, which the model
  writes and publishes with the code —

  ```jsonc
  {
    "open": ["MyProject"],                        // optional
    "functions": [{ "name": "math.double", "module": "MyProject.Math",
                    "function": "MyProject.Math.double", "signature": "Nat → Eff [] Nat" }],
    "graphs": [{ "name": "main", "program": "do\n  let x ← input \"x\" Nat\n  math.double x" }]
  }
  ```

  — so the user (or the typednotes app) can submit the same build later from
  the repository alone. lode adds the `source` (the repository, branch,
  published commit, project path and, for a private repository, the
  repository warrant, re-encoded by `Liaison.Wire` as lun decodes it) and
  submits it; lun validates the rest. lun's answers are read through derived
  `FromJson` shapes.
-/
import Lean.Data.Json
import Lode.Liaison
import Lode.Http
import Lode.Validate
import Lode.Workspace
import Lode.RuntimeContext

namespace Lode.Lun

open Lean (Json ToJson FromJson toJson fromJson?)

/-- Where lun is. -/
structure Config where
  url : String
  token : Option String := none
  /-- How long `lun_build` waits for a build. -/
  buildTimeoutMs : Nat := 3600 * 1000
  /-- How long one call may take. -/
  callTimeoutMs : Nat := 120 * 1000

-- ── The request ─────────────────────────────────────────────────────────────

/-- `lun.json`: the functions and graphs (lun validates each), namespaces to
    open. -/
structure Manifest where
  «open» : Option (Array String) := none
  functions : Array Json
  graphs : Option (Array Json) := none
  deriving ToJson, FromJson

/-- Immutable caller-owned pins, independent of the model-written manifest.
    Unlisted outputs are inferred and may evolve with dependent Lean code. -/
structure BuildContracts where
  outputs : Json := Json.mkObj []
  inputs : Json := Json.mkObj []
  dependencies : Json := Json.mkObj []
  graph : Option String := none
  deriving ToJson, FromJson

def BuildContracts.parse (j : Json) : Except String BuildContracts := do
  let fields ← j.getObj?
  unless fields.toList.all (fun (name,_) => ["outputs","inputs","dependencies","graph"].contains name) do throw "unknown build contract field"
  let graph ← match j.getObjVal? "graph" with
    | .error _ | .ok .null => pure none
    | .ok value => some <$> value.getStr?
  let c : BuildContracts := {
    outputs := (j.getObjVal? "outputs").toOption.getD (Json.mkObj [])
    inputs := (j.getObjVal? "inputs").toOption.getD (Json.mkObj [])
    dependencies := (j.getObjVal? "dependencies").toOption.getD (Json.mkObj [])
    graph }
  for values in [c.outputs,c.inputs] do
    let fields ← values.getObj?
    unless fields.size ≤ 1000 do throw "too many pinned types"
    for (name,value) in fields.toList do
      unless Validate.functionName name do throw "invalid pinned name"
      let ty ← value.getStr?
      unless !ty.trimAscii.isEmpty && ty.utf8ByteSize ≤ 4096 && !ty.contains '\x00' do throw "invalid pinned type"
  let deps ← c.dependencies.getObj?
  unless deps.size ≤ 1000 do throw "too many wiring contracts"
  for (name,value) in deps.toList do
    unless Validate.functionName name do throw "invalid wired function"
    let args : List String ← fromJson? value
    unless args.length ≤ 1000 && args.all Validate.functionName do throw "invalid wired arguments"
  if let some name := c.graph then unless Validate.functionName name do throw "invalid contract graph"
  else unless (← c.inputs.getObj?).isEmpty && deps.isEmpty do throw "input/wiring contracts require a graph"
  return c

def BuildContracts.outputsMatch (c : BuildContracts) (m : Manifest) : Bool :=
  match c.outputs.getObj? with
  | .error _ => false
  | .ok fields => fields.toList.all fun (name,ty) => m.functions.any fun f =>
      (f.getObjValAs? String "name").toOption == some name && (f.getObjVal? "outputType").toOption == some ty

def BuildContracts.graphMatches (c : BuildContracts) (m : Manifest) : Bool :=
  match c.graph with
  | none => true
  | some name => (m.graphs.getD #[]).any fun g =>
      (g.getObjValAs? String "name").toOption == some name &&
      (g.getObjVal? "inputTypes").toOption == some c.inputs &&
      (g.getObjVal? "dependencies").toOption == some c.dependencies

/-- Execution consumes equality with the caller's pins, never manifest authority.
    Lun then generates kernel-checked Output/Source/Wiring type contracts. -/
structure PinnedManifest (c : BuildContracts) where
  private mk ::
  manifest : Manifest
  outputsPreserved : c.outputsMatch manifest = true
  graphPreserved : c.graphMatches manifest = true

def BuildContracts.pin (c : BuildContracts) (m : Manifest) : Except String (PinnedManifest c) := do
  let _ ← BuildContracts.parse (toJson c)
  let mut functions := #[]
  for f in m.functions do
    let _ ← f.getObj?
    let name ← f.getObjValAs? String "name"
    let f := match c.outputs.getObjVal? name with
      | .ok ty => f.setObjVal! "outputType" ty
      | .error _ => f
    functions := functions.push f
  let graphs ← m.graphs.mapM fun gs => gs.mapM fun g => do
    let _ ← g.getObj?
    if (g.getObjValAs? String "name").toOption == c.graph then
      return (g.setObjVal! "inputTypes" c.inputs).setObjVal! "dependencies" c.dependencies
    return g
  let next := { m with functions, graphs }
  if ho : c.outputsMatch next = true then
    if hg : c.graphMatches next = true then return ⟨next,ho,hg⟩
    else throw "manifest omitted the caller's graph"
  else throw "manifest omitted a pinned output function"

/-- Read `lun.json`. Only the shape is checked; lun checks the rest and its
    errors go back to the model. -/
def parseManifest (text : String) : Except String Manifest := do
  let j ← (Json.parse text).mapError ("lun.json is not valid JSON: " ++ ·)
  -- lun has no aliases for its old vocabulary; say what the key is now.
  for (old, new) in [("cells", "functions"), ("dags", "graphs")] do
    if (j.getObjVal? old).isOk then
      throw s!"lun.json: \"{old}\" is now \"{new}\" (lun ≥ 0.2.0 has functions and graphs)"
  let m : Manifest ← (fromJson? j).mapError ("lun.json: " ++ ·)
  unless !m.functions.isEmpty || !(m.graphs.getD #[]).isEmpty do throw "lun.json must declare functions or graphs"
  return m

/-- Credentials as lun reads them. -/
structure CredentialsJson where
  warrant : Json
  account : String
  deriving ToJson

/-- The `source` of a build request. -/
structure SourceJson where
  url : String
  branch : String
  commit : String
  path : Option String := none
  credentials : Option CredentialsJson := none
  deriving ToJson

/-- lun's build request. -/
structure Request where
  source : SourceJson
  «open» : Option (Array String) := none
  functions : Array Json
  graphs : Option (Array Json) := none
  deriving ToJson

/-- lun's build request for the published commit. -/
def buildRequest (src : Workspace.Source) (commit : String) (creds : Option Liaison.Credentials)
    (m : Manifest) : Json :=
  toJson ({
    source := { url := src.repo.cloneUrl, branch := src.branch, commit
                path := if src.path.isEmpty then none else some src.path
                credentials := creds.map fun c =>
                  { warrant := Liaison.warrantJson c.warrant, account := c.account } }
    «open» := m.open, functions := m.functions, graphs := m.graphs } : Request)

/-- Only the checked manifest enters the writer's actual lun_build request. -/
def checkedBuildRequest (src : Workspace.Source) (commit : String) (creds : Option Liaison.Credentials)
    (m : Manifest) (c : BuildContracts) : Except String Json := do
  let checked ← c.pin m
  return buildRequest src commit creds checked.manifest

-- ── lun's answers ───────────────────────────────────────────────────────────

/-- A diagnostic, as lun attributes it. -/
structure Diagnostic where
  scope : Option String := none
  name : Option String := none
  file : Option String := none
  line : Option Nat := none
  column : Option Nat := none
  severity : Option String := none
  message : Option String := none
  hint : Option String := none
  deriving FromJson

/-- Something with a name (a function or a graph of a ready build). -/
structure Named where
  name : String
  deriving FromJson

/-- A build's status. -/
structure Status where
  id : String
  state : String
  error : Option String := none
  diagnostics : Option (Array Diagnostic) := none
  functions : Option (Array Named) := none
  /-- Each graph's structure (inputs, nodes, sources, sinks), shown to the
      model as is. -/
  graphs : Option (Array Json) := none
  deriving FromJson

/-- A build's state is final. -/
def finished (state : String) : Bool := state == "ready" || state == "failed"

-- ── Talking to lun ──────────────────────────────────────────────────────────

private def headers (cfg : Config) : List (String × String) :=
  [("content-type", "application/json"), ("accept", "application/json")] ++
    (cfg.token.map fun t => [("authorization", s!"Bearer {t}")]).getD []

private def base (cfg : Config) : String :=
  if cfg.url.endsWith "/" then (cfg.url.dropEnd 1).toString else cfg.url

/-- lun's `{"error": …}`, or the whole answer. -/
private structure ErrorJson where
  error : String
  deriving FromJson

private def errorOf (text : String) : String :=
  match Json.parse text >>= fromJson? with
  | .ok (e : ErrorJson) => e.error
  | .error _ => text

private def statusOf (text : String) : IO Status :=
  IO.ofExcept <| (Json.parse text >>= fromJson?).mapError (fun e => IO.userError s!"lun's answer: {e}")

/-- Submit a build; returns its status. -/
def submit (cfg : Config) (request : Json) : IO Status := do
  let a ← Http.request .POST s!"{base cfg}/v0/builds" (headers cfg) (some request.compress) cfg.callTimeoutMs
  unless Http.status a == 200 || Http.status a == 202 do
    throw (IO.userError s!"lun refused the build ({Http.status a}): {errorOf (Http.text a)}")
  statusOf (Http.text a)

/-- A build's status. -/
def status (cfg : Config) (id : String) : IO Status := do
  let a ← Http.request .GET s!"{base cfg}/v0/builds/{id}" (headers cfg) (timeoutMs := cfg.callTimeoutMs)
  unless Http.status a == 200 do
    throw (IO.userError s!"lun: build {id}: {Http.status a} {errorOf (Http.text a)}")
  statusOf (Http.text a)

/-- Submit and wait until the build is ready or failed (or `abort` is set, or
    the time runs out). -/
def build (cfg : Config) (request : Json) (abort : IO.Ref Bool) : IO Status := do
  let mut s ← submit cfg request
  let deadline := (← IO.monoMsNow) + cfg.buildTimeoutMs
  unless Validate.buildId s.id do throw (IO.userError "lun answered without a build id")
  repeat
    if finished s.state then break
    if ← abort.get then throw (IO.userError s!"aborted while lun build {s.id} was {s.state}")
    if (← IO.monoMsNow) ≥ deadline then
      throw (IO.userError s!"lun build {s.id} is still {s.state} after {cfg.buildTimeoutMs / 1000} s")
    IO.sleep 3000
    s ← status cfg s.id
  return s

/-- Call a function (`kind = "function"`) or run a graph (`kind = "graph"`)
    of a ready build; returns lun's HTTP status and answer. -/
def call (cfg : Config) (id : String) (request : Runtime.Call) : IO (Nat × String) := do
  let a ← Http.request .POST s!"{base cfg}/v0/builds/{id}/{request.kind}s/{request.name}" (headers cfg)
    (some request.body.compress) cfg.callTimeoutMs
  return (Http.status a, Http.text a)

-- ── For the model ───────────────────────────────────────────────────────────

/-- A diagnostic as the model reads it:
    `[function math.double] File.lean:3:4: error: …`. -/
def renderDiagnostic (d : Diagnostic) : String :=
  let scope := match d.scope, d.name with
    | some sc, some nm => s!"[{sc} {nm}] "
    | some sc, none => s!"[{sc}] "
    | _, _ => ""
  let loc := match d.file, d.line, d.column with
    | some f, some l, some c => s!"{f}:{l}:{c}: "
    | some f, _, _ => s!"{f}: "
    | none, some l, some c => s!"line {l}:{c}: "
    | _, _, _ => ""
  let hint := match d.hint with | some h => s!"\n  hint: {h}" | none => ""
  s!"{scope}{loc}{d.severity.getD "error"}: {d.message.getD ""}{hint}"

/-- A build's status as the model reads it. -/
def renderStatus (s : Status) : String :=
  let diags := s.diagnostics.getD #[]
  let names (xs : Option (Array Named)) := ", ".intercalate ((xs.getD #[]).toList.map (·.name))
  let head := s!"lun build {s.id}: {s.state}"
  let err := match s.error with | some e => s!"\nerror: {e}" | none => ""
  let ds := if diags.isEmpty then "" else
    s!"\n\n{diags.size} diagnostic(s):\n" ++ "\n\n".intercalate (diags.toList.take 60 |>.map renderDiagnostic)
  let graphs := s.graphs.getD #[]
  let ready := if s.state == "ready" then
    s!"\n\nfunctions: {names s.functions}\ngraphs: {", ".intercalate (graphs.toList.filterMap fun g =>
      (g.getObjValAs? String "name").toOption)}" ++
      (if graphs.isEmpty then "" else s!"\ngraph structure: {(Json.arr graphs).compress}")
    else ""
  head ++ err ++ ds ++ ready

end Lode.Lun
