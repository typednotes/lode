/-
  Lode.Cli — a native, one-task stdio interface to the session engine.

  No HTTP server is started. stdin is a UTF-8 task, through EOF; stdout
  carries assistant answers; stderr carries progress and tool results.
  Sessions use the same persisted metadata, policy and log as the service.
-/
import Lode.Session

namespace Lode.Cli

open Lean (Json toJson)

-- ── Arguments ───────────────────────────────────────────────────────────────

/-- Launch settings, or a persisted session to resume. -/
structure Options where
  repo : Option String := none
  branch : Option String := none
  path : Option String := none
  agent : Option String := none
  configFile : Option String := none
  resume : Option String := none
  deriving BEq, Repr

/-- CLI usage; normal invocation without a subcommand still serves HTTP. -/
def usage : String :=
  "Usage:\n" ++
  "  lode [serve]                         Start the HTTP service\n" ++
  "  lode run --repo PATH_OR_URL [--branch main] [--path DIR] [--agent build|plan]\n" ++
  "  lode run --config FILE               Launch from a session-request JSON file\n" ++
  "  lode run --resume ID                 Continue a persisted session\n\n" ++
  "run reads one UTF-8 task from stdin through EOF (at most 1 MB).\n" ++
  "Assistant answers go to stdout; progress and tool results go to stderr.\n" ++
  "Exit codes: 0 finished, 1 run/setup failure, 2 invalid arguments/stdin.\n" ++
  "run enables local mode. LODE_MODEL_* configure the default model.\n" ++
  "LODE_WORKDIR defaults to $HOME/.local/state/lode for run.\n" ++
  "Do not run concurrent processes against the same LODE_WORKDIR.\n"

/-- Interpret flags once; refuse duplicates and ambiguous launch modes. -/
def Options.parse (args : List String) : Except String Options := do
  let rec go : List String → Options → Except String Options
    | [], opts => pure opts
    | flag :: value :: rest, opts => do
      unless !value.isEmpty && !value.startsWith "--" do throw s!"{flag}: requires a value"
      let set (old : Option String) : Except String (Option String) := do
        unless old.isNone do throw s!"{flag}: given more than once"
        return some value
      let opts ← match flag with
        | "--repo" => pure { opts with repo := ← set opts.repo }
        | "--branch" => pure { opts with branch := ← set opts.branch }
        | "--path" => pure { opts with path := ← set opts.path }
        | "--agent" => pure { opts with agent := ← set opts.agent }
        | "--config" => pure { opts with configFile := ← set opts.configFile }
        | "--resume" => pure { opts with resume := ← set opts.resume }
        | _ => throw s!"unknown argument: {flag}"
      go rest opts
    | [flag], _ => throw s!"{flag}: requires a value"
  let opts ← go args {}
  unless ([opts.repo, opts.configFile, opts.resume].filterMap id).length == 1 do
    throw "choose exactly one of --repo, --config or --resume"
  if opts.repo.isNone && (opts.branch.isSome || opts.path.isSome || opts.agent.isSome) then
    throw "--branch, --path and --agent require --repo"
  if let some branch := opts.branch then
    unless System.Git.isBranchName branch do throw "--branch: not a valid branch name"
  if let some path := opts.path then
    unless Validate.projectPath path do throw "--path: must be relative, of plain components"
  if let some agent := opts.agent then
    unless (Prompt.agent? agent).isSome do throw "--agent: 'build' or 'plan'"
  if let some id := opts.resume then
    unless Validate.sessionId id do throw "--resume: not a session id"
  return opts

/-- Build a request from shorthand flags; the shared parser validates its model
    and repository just as it does for an HTTP request. -/
def Options.request (opts : Options) (url : String) : Json :=
  Json.mkObj [
    ("source", Json.mkObj [("url", Json.str url),
      ("branch", Json.str (opts.branch.getD "main")), ("path", Json.str (opts.path.getD ""))]),
    ("agent", Json.str (opts.agent.getD "build"))]

-- ── Streams ─────────────────────────────────────────────────────────────────

private def line (s : String) : String :=
  if s.isEmpty || s.endsWith "\n" then s else s ++ "\n"

/-- Render one entry as `(stdout, stderr)`. Tool-use narration belongs to
    progress, not to a piped answer. Tool failures remain results for the model. -/
def renderEntry : Entry → String × String
  | .assistant reply _ _ =>
    if reply.calls.isEmpty then (line reply.text, "")
    else ("", line reply.text ++ String.join (reply.calls.toList.map fun call =>
      s!"[tool] {call.name}\n"))
  | .toolResults results _ => ("", String.join (results.toList.map fun result =>
      s!"[{if result.isError then "tool error" else "tool result"}] {result.name}\n" ++ line result.content))
  | .event kind detail _ => ("", s!"[lode] {kind}" ++ (if detail.isEmpty then "" else s!": {detail}") ++ "\n")
  | .compaction .. => ("", "[lode] context compacted\n")
  | .user .. => ("", "")

/-- A normal run is the only successful terminal event. -/
def exitCode (entries : Array Entry) : UInt32 :=
  match entries.back? with
  | some (.event "run_finished" _ _) => 0
  | _ => 1

/-- Read bounded bytes before UTF-8 decoding, preserving multi-line tasks. -/
private def readTask : IO String := do
  let stdin ← IO.getStdin
  let mut bytes := ByteArray.empty
  repeat
    let chunk ← stdin.read 65536
    if chunk.isEmpty then break
    bytes := bytes ++ chunk
    if bytes.size > 1024 * 1024 then throw (IO.userError "stdin: at most 1 MB")
  let some text := String.fromUTF8? bytes | throw (IO.userError "stdin: must be UTF-8")
  IO.ofExcept ((checkText text "stdin").mapError IO.userError)

/-- Follow a running session without losing the terminal entries to a race:
    read the running flag before taking the final log snapshot. -/
private def follow (s : Session) (after : Nat) : IO UInt32 := do
  let stdout ← IO.getStdout
  let stderr ← IO.getStderr
  let mut next := after
  repeat
    let running ← s.running
    let entries ← s.entries.get
    for entry in entries.toList.drop next do
      let (out, err) := renderEntry entry
      unless out.isEmpty do stdout.putStr out; stdout.flush
      unless err.isEmpty do stderr.putStr err; stderr.flush
    next := entries.size
    unless running do return exitCode entries
    IO.sleep 50

-- ── Sessions ────────────────────────────────────────────────────────────────

/-- Resolve local paths into the file URL the shared repository parser accepts. -/
private def repositoryUrl (repo : String) : IO String := do
  if repo.startsWith "https://" || repo.startsWith "file://" then return repo
  if (repo.splitOn "://").length > 1 then
    throw (IO.userError "--repo: use a local path, file:// or https:// URL")
  return "file://" ++ (← IO.FS.realPath repo).toString

/-- Parse CLI launch configuration through the HTTP session parser. Runtime
    execution grants need authenticated HTTP ingress, not terminal input. -/
def parseSpec (j : Json) (cfg : Config) : Except String SessionSpec := do
  let spec ← SessionSpec.parse j cfg.defaultModel cfg.allowLocal
  unless spec.execution.isNone do throw "execution grants require authenticated HTTP ingress"
  unless spec.message.isNone do throw "--config: omit message; supply the task on stdin"
  return spec

/-- One native run. Persisted sessions can be continued by a later invocation. -/
def run (cfg : Config) (opts : Options) : IO UInt32 := do
  let text ← try readTask catch e =>
    IO.eprintln s!"lode: {e}"
    return 2
  try
    let registry ← Registry.new cfg
    let session ← match opts.resume with
      | some id => do
        let some s ← registry.get? id | throw (IO.userError s!"session {id} not found")
        pure s
      | none => do
        let request ← match opts.configFile with
          | some file => IO.ofExcept ((Json.parse (← IO.FS.readFile file)).mapError IO.userError)
          | none => pure (opts.request (← repositoryUrl (opts.repo.getD "")))
        let spec ← IO.ofExcept ((parseSpec request cfg).mapError IO.userError)
        registry.create spec
    IO.eprintln s!"[lode] session {session.id}"
    IO.eprintln s!"[lode] checkout {checkoutDir cfg session.id}"
    let after := (← session.entries.get).size
    let _ ← session.send text
    follow session after
  catch e =>
    IO.eprintln s!"lode: {e}"
    return 1

end Lode.Cli
