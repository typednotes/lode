/-
  Lode.Session — sessions, and the agent loop

  A **session** is one conversation about one branch of one repository: a
  checkout, an append-only log (`Lode.Entry`), the model and agent it runs,
  and the credentials it currently holds (in memory only). It lives under
  `{workdir}/sessions/{id}/`: `session.json` (its metadata, rewritten
  atomically), `log.jsonl` (one entry per line, appended) and `checkout/`.
  Sessions survive a restart; a run a restart interrupted is recorded as such
  (and any tool call it left unanswered is answered with an error the next
  time the model is called, `Lode.answerDangling`). Credentials do not
  survive: the caller sends fresh ones, as it must anyway (warrants expire
  within minutes).

  **Runs.** A user message starts a run if none is going; during a run it is
  queued and handed to the model between two steps — pi's *steering*: the
  user can redirect a working agent without stopping it. A run ends when the
  model answers without tool calls and nothing is queued, when it is aborted,
  when it fails, or when its fuel is spent. Only the run's own thread writes
  the log while it runs; starting and ending a run are atomic with respect to
  the queue (`control`), so no message is lost between the two.

  **The loop is total** (`typednotes/docs/services/agent.md` §4): `loop` is
  structural in its fuel — at most `maxSteps` model calls per run — so it
  cannot diverge whatever the model does; a run that spends its fuel says so.
-/
import Lean.Data.Json
import Std.Data.HashMap
import Std.Sync.Mutex
import Linen.Crypto.SecureRandom
import Linen.Data.Hex
import Linen.Data.Time.Clock
import Linen.Data.Time.ISO8601
import Lode.Spec
import Lode.Tools
import Lode.Prompt
import Lode.Compaction
import Lode.Lun
import Lode.Workspace

namespace Lode

open Lean (Json ToJson FromJson toJson fromJson?)
open System (FilePath)

-- ── Configuration ───────────────────────────────────────────────────────────

/-- lode's configuration (see `Main.lean` for the environment variables). -/
structure Config where
  workdir : FilePath
  /-- A bearer token every request must carry, if set. -/
  token : Option String := none
  liaisonUrl : Option String := none
  lun : Option Lun.Config := none
  /-- The server's model: what a session gets when it names none. -/
  defaultModel : Option Model.Config := none
  /-- A key for `defaultModel`'s endpoint, used directly (development). Only
      ever sent to `defaultModel.baseUrl`. -/
  modelApiKey : Option String := none
  /-- Local mode: `file://` repositories and the `scripted` model (tests). -/
  allowLocal : Bool := false
  /-- At most this many model calls per run. -/
  maxSteps : Nat := 200
  modelTimeoutMs : Nat := 600 * 1000
  gitTimeoutMs : Nat := 600 * 1000
  checkTimeoutMs : Nat := 1800 * 1000
  /-- Pre-built packages: `{cache}/linen/{rev}`. -/
  packageCache : Option FilePath := none
  /-- What new projects should require. -/
  linenRev : String := "v1.10.0"
  toolchain : String := "leanprover/lean4:v4.34.0"

-- ── Time ────────────────────────────────────────────────────────────────────

/-- Unix milliseconds. -/
def nowMs : IO Nat := do return (← Data.Time.getCurrentTime).nanosSinceEpoch / 1000000

/-- `YYYY-MM-DD` of a Unix time in milliseconds (linen's ISO 8601). -/
def isoDate (ms : Nat) : String :=
  Data.Time.ISO8601.extendedDate (Data.Time.UTCTime.ofNanosSinceEpoch (ms * 1000000))

-- ── Metadata ────────────────────────────────────────────────────────────────

/-- What is persisted about a session (no credentials). -/
structure Meta where
  id : String
  created : Nat
  source : Workspace.Source
  agent : String
  model : Model.Config
  tools : Tools.Policy := Tools.Policy.all
  toolCeiling : Option Tools.Policy := none
  credentialBindings : CredentialBindings := {}
  executionCeiling : Option Runtime.Bounds := none
  executionBounds : Option Runtime.Bounds := none
  workspace : Workspace.State
  lastBuild : Option String := none
  buildContracts : Option Lun.BuildContracts := none
  todos : Array Tools.Todo := #[]
  usage : Usage := {}
  /-- How the last run ended, if it did not end well. -/
  error : Option String := none
  deriving ToJson, FromJson

/-- Read back persisted metadata. -/
def Meta.ofJson (j : Json) : Except String Meta :=
  (fromJson? j).mapError ("session.json: " ++ ·)

-- ── Paths ───────────────────────────────────────────────────────────────────

def sessionsDir (cfg : Config) : FilePath := cfg.workdir / "sessions"
def sessionDir (cfg : Config) (id : String) : FilePath := sessionsDir cfg / id
def metaFile (cfg : Config) (id : String) : FilePath := sessionDir cfg id / "session.json"
def logFile (cfg : Config) (id : String) : FilePath := sessionDir cfg id / "log.jsonl"
def checkoutDir (cfg : Config) (id : String) : FilePath := sessionDir cfg id / "checkout"

-- ── Sessions ────────────────────────────────────────────────────────────────

/-- Whether a run is going, and the messages waiting for it. -/
structure Control where
  running : Bool := false
  queue : Array String := #[]

/-- A live session. -/
structure Session where
  cfg : Config
  id : String
  info : IO.Ref Meta
  metaLock : Std.Mutex Unit
  entries : IO.Ref (Array Entry)
  creds : IO.Ref CredentialSet
  control : Std.Mutex Control
  abort : IO.Ref Bool
  todos : IO.Ref (Array Tools.Todo)
  /-- Model calls made by the current run. -/
  steps : IO.Ref Nat
  /-- Immutable launch ceiling; the current policy is proof-bounded by it. -/
  toolCeiling : Tools.Policy
  toolPolicy : Std.Mutex (Tools.BoundedPolicy toolCeiling)

/-- Write the metadata atomically (write, then rename), todos included. -/
private def Session.saveMetaUnlocked (s : Session) : IO Unit := do
  let m := { (← s.info.get) with todos := ← s.todos.get }
  s.info.set m
  let file := metaFile s.cfg s.id
  let tmp := file.withExtension "json.tmp"
  IO.FS.writeFile tmp (toJson m).pretty
  IO.FS.rename tmp file

/-- Serialize metadata replacement so a concurrent save cannot restore an older
    tool policy after an acknowledged narrowing, including after restart. -/
def Session.saveMeta (s : Session) : IO Unit :=
  s.metaLock.atomically (m := IO) s.saveMetaUnlocked

/-- Change the metadata and save it. -/
def Session.updateMeta (s : Session) (f : Meta → Meta) : IO Unit :=
  s.metaLock.atomically (m := IO) do
    s.info.modify f
    s.saveMetaUnlocked

/-- Append an entry to the log (memory and disk). -/
def Session.append (s : Session) (e : Entry) : IO Unit := do
  s.entries.modify (·.push e)
  let h ← IO.FS.Handle.mk (logFile s.cfg s.id) .append
  h.putStrLn (toJson e).compress
  h.flush

/-- The workspace context. -/
def Session.wctx (s : Session) : Workspace.Context :=
  { liaisonUrl := s.cfg.liaisonUrl, timeoutMs := s.cfg.gitTimeoutMs }

private def make (cfg : Config) (m : Meta) (entries : Array Entry) : IO Session := do
  let ceiling := m.toolCeiling.getD m.tools
  let policy ← IO.ofExcept ((Tools.BoundedPolicy.initial ceiling |>.narrow m.tools).mapError IO.userError)
  return {
    cfg, id := m.id, info := ← IO.mkRef m, metaLock := ← Std.Mutex.new (), entries := ← IO.mkRef entries
    creds := ← IO.mkRef {}, control := ← Std.Mutex.new {}, abort := ← IO.mkRef false
    todos := ← IO.mkRef m.todos, steps := ← IO.mkRef 0, toolCeiling := ceiling
    toolPolicy := ← Std.Mutex.new policy }

/-- Load a session from disk. A run a restart interrupted is recorded. -/
def Session.load (cfg : Config) (id : String) : IO Session := do
  let m ← IO.ofExcept (Json.parse (← IO.FS.readFile (metaFile cfg id)) >>= Meta.ofJson |>.mapError IO.userError)
  let lines ← if ← (logFile cfg id).pathExists then IO.FS.lines (logFile cfg id) else pure #[]
  let entries := lines.filterMap fun l => (Json.parse l >>= Entry.ofJson).toOption
  let s ← make cfg m entries
  let lastEvent := entries.foldl (init := none) fun acc e => match e with
    | .event k _ _ => some k
    | _ => acc
  if lastEvent == some "run_started" then
    s.append (.event "interrupted" "the run was interrupted by a restart" (← nowMs))
  return s

/-- 16 random bytes, hex. -/
def newId : IO String := Data.Hex.encode <$> Crypto.SecureRandom.randomBytes 16

/-- Create a session: open the workspace, persist, return it. -/
def Session.create (cfg : Config) (spec : SessionSpec) : IO Session := do
  let id ← newId
  let dir := sessionDir cfg id
  IO.FS.createDirAll dir
  try
    let wctx : Workspace.Context := { liaisonUrl := cfg.liaisonUrl, timeoutMs := cfg.gitTimeoutMs }
    let st ← Workspace.open wctx spec.source spec.creds.repo (checkoutDir cfg id)
    let m : Meta := {
      id, created := ← nowMs, source := spec.source, agent := spec.agent
      model := spec.model, workspace := st, tools := spec.tools
      toolCeiling := some spec.tools, credentialBindings := CredentialBindings.ofCredentials spec.creds
      executionCeiling := spec.execution.map (·.bounds), executionBounds := spec.execution.map (·.bounds), buildContracts := some spec.buildContracts }
    let s ← make cfg m #[]
    s.creds.set { spec.creds with execution := spec.execution }
    IO.FS.writeFile (logFile cfg id) ""
    s.saveMeta
    return s
  catch e =>
    IO.FS.removeDirAll dir
    throw e

-- ── Status ──────────────────────────────────────────────────────────────────

/-- The model, as a status shows it. -/
structure ModelView where
  api : String
  name : String
  baseUrl : String
  deriving ToJson

/-- The workspace, as a status shows it. -/
structure WorkspaceView where
  remoteHead : String
  deriving ToJson

/-- Which credentials a session holds (never the credentials). -/
structure CredentialsView where
  repo : Bool
  model : Bool
  lun : Bool
  execution : Bool := false
  deriving ToJson

/-- The session as `GET /v0/sessions/{id}` shows it. -/
structure StatusView where
  id : String
  created : Nat
  /-- `idle` or `running`. -/
  state : String
  /-- Model calls of the current run. -/
  steps : Option Nat := none
  queued : Nat
  source : Workspace.Source
  agent : String
  tools : Tools.Policy
  execution : Option Runtime.Bounds := none
  buildContracts : Lun.BuildContracts := {}
  model : ModelView
  workspace : WorkspaceView
  lastBuild : Option String := none
  todos : Array Tools.Todo
  usage : Usage
  entries : Nat
  credentials : CredentialsView
  error : Option String := none
  deriving ToJson

/-- The session's status. -/
def Session.status (s : Session) : IO Json := do
  let m ← s.info.get
  let c ← s.control.atomically (m := IO) get
  let cr ← s.creds.get
  let steps ← s.steps.get
  return toJson ({
    id := m.id, created := m.created, state := if c.running then "running" else "idle"
    steps := if c.running then some steps else none, queued := c.queue.size
    source := m.source, agent := m.agent, tools := m.tools, execution := m.executionBounds
    buildContracts := m.buildContracts.getD {}
    model := { api := m.model.api.toString, name := m.model.name, baseUrl := m.model.baseUrl }
    workspace := { remoteHead := m.workspace.remoteHead }, lastBuild := m.lastBuild
    todos := ← s.todos.get, usage := m.usage, entries := (← s.entries.get).size
    credentials := { repo := cr.repo.isSome, model := cr.model.isSome, lun := cr.lun.isSome, execution := cr.execution.isSome }
    error := m.error } : StatusView)

-- ── What a run needs ────────────────────────────────────────────────────────

/-- How this session's model is reached. The operator's key goes only to the
    operator's endpoint. -/
def Session.transport (s : Session) : IO Model.Transport := do
  let m := (← s.info.get).model
  if m.api == .scripted then return .none
  if let some c := (← s.creds.get).model then
    let some url := s.cfg.liaisonUrl
      | throw (IO.userError "the model has credentials, but LODE_LIAISON_URL is not set")
    return .liaison url c
  match s.cfg.modelApiKey, s.cfg.defaultModel with
  | some key, some d =>
    if d.baseUrl == m.baseUrl then return .direct key
    else throw (IO.userError "no model credentials for this model: send them with the message")
  | _, _ => throw (IO.userError "no model credentials: send model credentials with the message")

/-- `git show {localBase}:{path}/lun.json`: the manifest as published. -/
private def publishedManifest (s : Session) : IO String := do
  let m ← s.info.get
  let file := (if m.source.path.isEmpty then "" else m.source.path ++ "/") ++ "lun.json"
  let r ← System.Process.run "git" #["show", s!"{m.workspace.localBase}:{file}"] s.cfg.gitTimeoutMs
    (cwd := checkoutDir s.cfg s.id) (env := Process.hermeticGit)
  unless r.ok do
    throw (IO.userError s!"{file} is not in the published commit {m.workspace.remoteHead}: write it, then publish")
  return r.stdout

/-- The tools' view of this session. -/
def Session.toolEnv (s : Session) : IO Tools.Env := do
  let m ← s.info.get
  let root ← IO.FS.realPath (checkoutDir s.cfg s.id)
  let project := if m.source.path.isEmpty then [] else m.source.path.splitOn "/"
  let projectDir := project.foldl (fun (acc : FilePath) (c : String) => acc / c) root
  return {
    root, project, abort := s.abort, checkTimeoutMs := s.cfg.checkTimeoutMs, todos := s.todos
    seed := Workspace.seedCache s.cfg.packageCache projectDir s.cfg.gitTimeoutMs
    publish := fun message => do
      let m ← s.info.get
      let (st, report) ← Workspace.publish s.wctx m.source (← s.creds.get).repo (checkoutDir s.cfg s.id)
        m.workspace message
      s.updateMeta ({ · with workspace := st })
      return report
    lunBuild := do
      let some lun := s.cfg.lun | throw (IO.userError "no lun is configured on this server (LODE_LUN_URL)")
      let m ← s.info.get
      let pending ← Workspace.changes s.wctx (checkoutDir s.cfg s.id) m.workspace
      let manifest ← IO.ofExcept (Lun.parseManifest (← publishedManifest s) |>.mapError IO.userError)
      if let some bounds := m.executionBounds then
        for function in manifest.functions do
          let name ← IO.ofExcept ((function.getObjValAs? String "name").mapError IO.userError)
          unless bounds.functions.contains name do throw (IO.userError "lun.json declares a function outside caller execution bounds")
        for graph in manifest.graphs.getD #[] do
          let name ← IO.ofExcept ((graph.getObjValAs? String "name").mapError IO.userError)
          unless bounds.graphs.contains name do throw (IO.userError "lun.json declares a graph outside caller execution bounds")
      let cr ← s.creds.get
      let request ← IO.ofExcept ((Lun.checkedBuildRequest m.source m.workspace.remoteHead (cr.lun <|> cr.repo) manifest (m.buildContracts.getD {})).mapError IO.userError)
      let status ← Lun.build lun request s.abort
      s.updateMeta ({ · with lastBuild := some status.id })
      let note := if pending.isEmpty then "" else
        s!"Note: lun built the published commit {m.workspace.remoteHead}; the workspace has unpublished changes ({Workspace.summarize pending}).\n\n"
      let (text, _) := Tools.truncateHead (note ++ Lun.renderStatus status) 400 30000
      return (text, status.state != "ready")
    lunCall := fun kind name body => do
      let some lun := s.cfg.lun | throw (IO.userError "no lun is configured on this server (LODE_LUN_URL)")
      let m ← s.info.get
      let some id := m.lastBuild | throw (IO.userError "no lun build yet: run lun_build first")
      let context := (← s.creds.get).execution
      let now := (← Liaison.nowSeconds).toUInt64
      let request ← IO.ofExcept <| (do
        match m.executionCeiling, m.executionBounds, context with
        | some ceiling, some current, some context =>
          let bounded ← Runtime.refresh ceiling current context false
          bounded.call kind name body now s.cfg.token
        | none, none, none => Runtime.Call.inputOnly kind name body
        | _, _, _ => throw "execution credentials missing after restart; caller must refresh").mapError IO.userError
      let (code, text) ← Lun.call lun id request
      let (text, _) := Tools.truncateHead text 400 20000
      if code == 200 then return text
      else throw (IO.userError s!"lun answered {code}: {text}")
  }

-- ── The run ─────────────────────────────────────────────────────────────────

/-- How a run ended. -/
inductive Outcome where
  | done
  | aborted
  | outOfFuel
  | failed (message : String)

/-- What stays fixed during a run. -/
structure Run where
  agent : Prompt.Agent
  system : String
  env : Tools.Env

/-- The number of assistant messages in the log (the `scripted` model's
    position). -/
def assistantCount (entries : Array Entry) : Nat := (entries.filter Entry.isAssistant).size

/-- Summarize the oldest part of the context if the context is close to the
    model's window. -/
def Session.compactIfNeeded (s : Session) (_r : Run) : IO Unit := do
  let es ← s.entries.get
  let m := (← s.info.get).model
  unless Compaction.needed es m.contextWindow m.maxTokens do return
  let some cut := Compaction.cutPoint es | return
  let before := Compaction.estimateTokens es
  let summary ← if m.api == .scripted then pure "(scripted summary)" else do
    let text := Compaction.transcript es cut (m.contextWindow * 2)
    let reply ← Model.complete { m with maxTokens := min m.maxTokens 8192 } (← s.transport)
      Compaction.instructions #[] #[.user text] 0 s.cfg.modelTimeoutMs s.abort s.id (some "agent")
    s.updateMeta fun mt => { mt with usage := mt.usage + reply.usage }
    unless reply.calls.isEmpty && !reply.text.trimAscii.isEmpty &&
        reply.stop != "length" && reply.stop != "max_tokens" do
      throw (IO.userError "compaction returned an incomplete summary; the original context was preserved")
    pure reply.text
  s.append (.compaction summary cut before (← nowMs))

/-- End a run that finished normally, unless messages are waiting: then the
    run goes on. Atomic with respect to `send`. -/
def Session.tryFinish (s : Session) : IO Bool := do
  let steps ← s.steps.get
  s.control.atomically (m := IO) do
    let c ← get
    if !c.queue.isEmpty then return false
    s.append (.event "run_finished" s!"{steps} step(s)" (← nowMs))
    s.abort.set false
    set { c with running := false }
    return true

/-- End a run that did not finish normally. Waiting messages are kept in the
    log, as the conversation's next user turns. -/
def Session.finish (s : Session) (kind detail : String) : IO Unit := do
  s.updateMeta ({ · with error := if kind == "aborted" then none else some detail })
  s.control.atomically (m := IO) do
    let c ← get
    for text in c.queue do s.append (.user text (← nowMs))
    s.append (.event kind detail (← nowMs))
    s.abort.set false
    set ({ running := false, queue := #[] } : Control)

/-- Hand the model the messages that arrived during the run. -/
private def Session.drainQueue (s : Session) : IO Unit := do
  let msgs ← s.control.atomically (m := IO) do
    let c ← get
    set { c with queue := #[] }
    return c.queue
  for text in msgs do s.append (.user text (← nowMs))

/-- The loop: one model call per unit of fuel. -/
def Session.loop (s : Session) (r : Run) : Nat → IO Outcome
  | 0 => pure .outOfFuel
  | fuel + 1 => do
    if ← s.abort.get then return .aborted
    s.drainQueue
    s.compactIfNeeded r
    let es ← s.entries.get
    let m ← s.info.get
    let policy ← s.toolPolicy.atomically (m := IO) do return (← get).policy
    let system := r.system ++ "\n# Current writer tool policy\n\nAvailable tools: " ++
      (", ".intercalate (r.agent.tools.filter policy.names.contains)) ++
      ". Only these named tools may execute; removed tools stay unavailable after refresh or agent changes.\n"
    let reply ← Model.complete m.model (← s.transport) system (Tools.specsForPolicy policy r.agent.tools)
      (context es) (assistantCount es) s.cfg.modelTimeoutMs s.abort s.id
    s.steps.modify (· + 1)
    s.append (.assistant reply m.model.name (← nowMs))
    s.updateMeta fun mt => { mt with usage := mt.usage + reply.usage }
    if reply.calls.isEmpty then
      if reply.stop == "length" || reply.stop == "max_tokens" then
        -- Cut off mid-answer: let it continue.
        s.append (.user "(your reply was cut off by the output limit; continue)" (← nowMs))
        s.loop r fuel
      else if ← s.tryFinish then return .done
      else s.loop r fuel
    else
      let mut results : Array ToolResult := #[]
      for call in reply.calls do
        if ← s.abort.get then
          results := results.push {
            id := call.id, name := call.name, content := "(aborted by the user)", isError := true
            nativeId := call.nativeId }
        else
          -- Hold the policy lock across execution: a successful narrowing cannot
          -- race a previously authorized call into executing broader authority.
          let result ← s.toolPolicy.atomically (m := IO) do
            let bounded ← get
            Tools.execute r.env bounded.policy r.agent.tools call
          results := results.push result
      s.append (.toolResults results (← nowMs))
      s.saveMeta
      s.loop r fuel

/-- Prepare and run to the end, recording how it ended. -/
def Session.runToEnd (s : Session) : IO Unit := do
  s.steps.set 0
  let outcome ← try
      let m ← s.info.get
      let some agent := Prompt.agent? m.agent | throw (IO.userError s!"unknown agent {m.agent}")
      let env ← s.toolEnv
      let cr ← s.creds.get
      let canPublish := match Workspace.backend m.source.repo cr.repo.isSome with
        | .git => m.source.repo.host == .local
        | _ => true
      let penv : Prompt.Environment :=
        { repoUrl := m.source.repo.cloneUrl, branch := m.source.branch, projectPath := m.source.path
          remoteHead := m.workspace.remoteHead, canPublish, hasLun := s.cfg.lun.isSome
          toolchain := s.cfg.toolchain, linenRev := s.cfg.linenRev, date := isoDate (← nowMs) }
      let system := Prompt.system agent penv (← Prompt.contextFiles env.root env.project)
      s.updateMeta ({ · with error := none })
      s.loop { agent, system, env } s.cfg.maxSteps
    catch e => pure (.failed (toString e))
  match outcome with
  | .done => pure ()
  | .aborted => s.finish "aborted" "the run was aborted"
  | .outOfFuel => s.finish "out_of_fuel" s!"the run used its {s.cfg.maxSteps} steps without finishing"
  | .failed msg => s.finish "error" msg

/-- A user message: starts a run, or joins the running one's queue. Returns
    whether it was queued. -/
def Session.send (s : Session) (text : String) : IO Bool := do
  let started ← s.control.atomically (m := IO) do
    let c ← get
    if c.running then
      set { c with queue := c.queue.push text }
      return false
    s.abort.set false
    s.append (.event "run_started" "" (← nowMs))
    s.append (.user text (← nowMs))
    set { c with running := true }
    return true
  if started then
    let _ ← IO.asTask (prio := .dedicated) s.runToEnd
  return !started

/-- Ask the running run to stop (at its next step, or as soon as the tool or
    lun build it is in notices). -/
def Session.requestAbort (s : Session) : IO Bool := do
  let running := (← s.control.atomically (m := IO) get).running
  if running then s.abort.set true
  return running

/-- Whether a run is going. -/
def Session.running (s : Session) : IO Bool := return (← s.control.atomically (m := IO) get).running

/-- Validate all changes before mutation. Credentials cannot alter the immutable
    ceiling. Policy transitions are serialized with tool execution. -/
def Session.updateAccess (s : Session) (fresh : CredentialSet := {})
    (tools : Option Tools.Policy := none) (agent : Option String := none)
    (execution : Option Runtime.Context := none) (credentialsOnly : Bool := true) : IO (Except String Unit) :=
  s.toolPolicy.atomically (m := IO) do
    let old ← get
    let m ← s.info.get
    let next ← match tools.mapM old.narrow with
      | .ok next => pure (next.getD old)
      | .error e => return .error e
    let bindings ← match m.credentialBindings.check m.model fresh with
      | .ok b => pure b
      | .error e => return .error e
    let incoming := execution <|> fresh.execution
    if let some context := incoming then
      let org := ((context.execution.getObjVal? "binding") >>= (·.getObjValAs? String "org_id")).toOption
      unless ([bindings.repo, bindings.model, bindings.lun].filterMap (fun b => b)).all (fun binding => org == some binding.orgId) do
        return .error "execution and writer credentials belong to different organizations"
    let bounds ← match incoming with
      | none => pure m.executionBounds
      | some context =>
        let some ceiling := m.executionCeiling | return .error "execution authority cannot be added after launch"
        let some current := m.executionBounds | return .error "missing persisted execution bounds"
        match Runtime.refresh ceiling current context credentialsOnly with
        | .error e => return .error e
        | .ok bounded => pure (some bounded.context.bounds)
    if let some a := agent then
      unless (Prompt.agent? a).isSome do return .error "message.agent: 'build' or 'plan'"
      if ← s.running then return .error "the agent cannot change during a run"
    s.updateMeta fun mt =>
      { mt with tools := next.policy, toolCeiling := some s.toolCeiling
                credentialBindings := bindings, agent := agent.getD mt.agent
                executionBounds := bounds }
    s.creds.modify (·.merge { fresh with execution := incoming })
    set next
    return .ok ()

-- ── The registry ────────────────────────────────────────────────────────────

/-- Every session this process has touched, loaded on demand. -/
structure Registry where
  cfg : Config
  sessions : Std.Mutex (Std.HashMap String Session)

def Registry.new (cfg : Config) : IO Registry := do
  IO.FS.createDirAll (sessionsDir cfg)
  return { cfg, sessions := ← Std.Mutex.new {} }

/-- A session by id, loaded from disk the first time. -/
def Registry.get? (r : Registry) (id : String) : IO (Option Session) := do
  unless Validate.sessionId id do return none
  r.sessions.atomically (m := IO) do
    if let some s := (← get)[id]? then return some s
    unless ← (metaFile r.cfg id).pathExists do return none
    let s ← Session.load r.cfg id
    modify (·.insert id s)
    return some s

/-- Create a session and register it. -/
def Registry.create (r : Registry) (spec : SessionSpec) : IO Session := do
  let s ← Session.create r.cfg spec
  r.sessions.atomically (m := IO) (modify (·.insert s.id s))
  return s

/-- The ids of every session on disk, newest first. -/
def Registry.ids (r : Registry) : IO (Array String) := do
  let mut acc : Array (Nat × String) := #[]
  for e in ← (sessionsDir r.cfg).readDir do
    if Validate.sessionId e.fileName && (← (metaFile r.cfg e.fileName).pathExists) then
      let t := (← (metaFile r.cfg e.fileName).metadata).modified.sec.toNat
      acc := acc.push (t, e.fileName)
  return (acc.qsort (fun a b => a.1 > b.1)).map (·.2)

/-- Delete a session that is not running. -/
def Registry.delete (r : Registry) (s : Session) : IO Bool := do
  if ← s.running then return false
  r.sessions.atomically (m := IO) (modify (·.erase s.id))
  IO.FS.removeDirAll (sessionDir r.cfg s.id)
  return true

end Lode
