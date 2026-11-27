/-
  Lode.Cli — a native, one-task stdio interface to the session engine.

  No HTTP server is started. stdin is a UTF-8 task, through EOF; stdout
  carries assistant answers; stderr carries progress and tool results.
  Sessions use the same persisted metadata, policy and log as the service.
-/
import Lode.Session
import Lode.Settings
import Lode.Output

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
  settingsFile : Option String := none
  resume : Option String := none
  deriving BEq, Repr

/-- CLI usage; normal invocation without a subcommand still serves HTTP. -/
def usage : String :=
  "Usage:\n" ++
  "  lode [serve] [--settings FILE]        Start the HTTP service\n" ++
  "  lode run --repo PATH_OR_URL [--branch main] [--path DIR] [--agent build|plan]\n" ++
  "  lode run --config FILE               Launch from a session-request JSON file\n" ++
  "  lode run --resume ID                 Continue a persisted session\n\n" ++
  "  lode output ID [--format cell|executable|git|source-package] [--output NEW_DIR]\n" ++
  "      Default: cell, output/<format>/<session>. Build a signed cell with\n" ++
  "      --target NAME --build-record FILE --key FINGERPRINT, or verify a package\n" ++
  "      with --package DIR --admission FILE.\n" ++
  "      Executables require --target NAME. Git returns immutable coordinates as JSON.\n" ++
  "      Example: lode output ID --format source-package --output output/release-source\n\n" ++
  "  lode oauth BASE_URL ID [--open]       Start model OAuth using LODE_TOKEN\n" ++
  "      Example: lode oauth http://127.0.0.1:8080 ID --open\n\n" ++
  "  lode secrets store-model-key [--settings FILE] [--yes | --dry-run]\n" ++
  "      Store LODE_MODEL_API_KEY at the configured Secrets KV path.\n\n" ++
  "  lode cell manifest IDENTITY_JSON ARTIFACT\n" ++
  "  lode cell sign MANIFEST ARTIFACT --key FINGERPRINT\n" ++
  "  lode cell verify MANIFEST ARTIFACT [--signature FILE --keyring FILE]\n\n" ++
  "  lode cell package BUILD_JSON WORKER NEW_DIR --key FINGERPRINT\n" ++
  "      Package a checked compiler worker in Linen's v2 format.\n\n" ++
  "run reads one UTF-8 task from stdin through EOF (at most 1 MB).\n" ++
  "Assistant answers go to stdout; progress and tool results go to stderr.\n" ++
  "Exit codes: 0 finished, 1 run/setup failure, 2 invalid arguments/stdin.\n" ++
  "serve and run accept --settings FILE (TOML or JSON), or LODE_SETTINGS.\n" ++
  "Environment values override settings. --config still names a session request.\n" ++
  "run enables local mode. LODE_MODEL_* configure the default model.\n" ++
  "LODE_WORKDIR defaults to $HOME/.local/state/lode for run.\n" ++
  "Do not run concurrent processes against the same LODE_WORKDIR.\n"

/-- Arguments for the operator's Secrets write. -/
private inductive StoreMode where
  | confirm | apply | preview

private def storeOptions (args : List String) : Except String (Option String × StoreMode) :=
  let rec parse (args : List String) (path : Option String) (mode : Option StoreMode) :
      Except String (Option String × StoreMode) :=
    match args with
    | [] => .ok (path, mode.getD .confirm)
    | "--settings" :: value :: rest => do
      unless path.isNone && !value.isEmpty && !value.startsWith "--" do
        throw "--settings needs one filename"
      parse rest (some value) mode
    | ["--settings"] => .error "--settings needs one filename"
    | flag :: rest => do
      unless mode.isNone do throw "choose one of --yes or --dry-run"
      let mode ← match flag with
        | "--yes" => pure StoreMode.apply
        | "--dry-run" => pure StoreMode.preview
        | _ => throw s!"unknown argument: {flag}"
      parse rest path (some mode)
  parse args none none

/-- Write the operator's model key as a new Secrets KV version. A dry run
    names the destination without accessing the vault. -/
def storeModelKey (args : List String) : IO UInt32 := do
  let (settingsPath, mode) ← match storeOptions args with
    | .ok options => pure options
    | .error error => IO.eprintln s!"lode: {error}\n{usage}"; return 2
  let cfg ← Settings.runtime (← Settings.load settingsPath)
  let some vault := cfg.modelKeySecret | throw (IO.userError "configure a Secrets model key destination")
  IO.eprintln s!"Secrets destination {vault.baseUrl}/v1/secret/data/{vault.path} for {vault.modelBaseUrl}"
  match mode with
  | .preview => return 0
  | .apply => pure ()
  | .confirm =>
    let stdin ← IO.getStdin
    unless ← stdin.isTty do throw (IO.userError "pass --yes to write non-interactively")
    let stderr ← IO.getStderr
    stderr.putStr "Write a new Secrets KV version? Type yes to confirm. "
    stderr.flush
    unless (← stdin.getLine).trimAscii.toString == "yes" do return 1
  let some key := cfg.modelApiKey | throw (IO.userError "set LODE_MODEL_API_KEY")
  vault.store key
  IO.eprintln "Stored a new Secrets KV version."
  return 0

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
        | "--settings" => pure { opts with settingsFile := ← set opts.settingsFile }
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

/-- Command inputs for exporting an existing session. -/
structure OutputOptions where
  id : String
  request : Output.Request
  destination : System.FilePath
  settings : Option String

/-- Parse the output format and reject inapplicable or duplicate flags. -/
def OutputOptions.parse (id : String) (args : List String) : Except String OutputOptions := do
  unless Validate.sessionId id do throw "output requires a valid session id"
  let rec flags (args : List String) (seen : List (String × String)) :
      Except String (List (String × String)) :=
    match args with
    | [] => pure seen
    | flag :: value :: rest => do
      unless ["--format", "--output", "--target", "--package", "--admission", "--settings",
          "--build-record", "--key"].contains flag do
        throw s!"unknown output option: {flag}"
      unless !value.isEmpty && !value.startsWith "--" do throw s!"{flag} requires a value"
      unless (seen.lookup flag).isNone do throw s!"{flag} given more than once"
      flags rest ((flag, value) :: seen)
    | [flag] => throw s!"{flag} requires a value"
  let opts ← flags args []
  let format ← Output.Format.parse ((opts.lookup "--format").getD "cell")
  let required (flag : String) : Except String String :=
    match opts.lookup flag with
    | some value => .ok value
    | none => .error s!"{format.name} output requires {flag}"
  let allowed : List String := match format with
    | .cell => ["--package", "--admission", "--output", "--target", "--build-record", "--key"]
    | .executable => ["--target", "--output"]
    | .git => []
    | .sourcePackage => ["--output"]
  for (flag, _) in opts do
    unless ["--settings", "--format"].contains flag || allowed.contains flag do
      throw s!"{flag} is unavailable for {format.name} output"
  let request ← match format with
    | .cell => do
      if (["--target", "--build-record", "--key"].any fun key => (opts.lookup key).isSome) then
        unless (opts.lookup "--package").isNone && (opts.lookup "--admission").isNone do
          throw "choose either compiler inputs or package admission"
        pure (.cell (.compile (← required "--target") ⟨← required "--build-record"⟩ (← required "--key")))
      else pure (.cell (.admitted ⟨← required "--package"⟩ ⟨← required "--admission"⟩))
    | .executable => pure (.executable (← required "--target"))
    | .git => pure .git
    | .sourcePackage => pure .sourcePackage
  let destination := (opts.lookup "--output").getD s!"output/{format.name}/{id}"
  return ⟨id, request, ⟨destination⟩, opts.lookup "--settings"⟩

/-- Export a persisted session and print a single JSON receipt. -/
def output (opts : OutputOptions) : IO Unit := do
  let registry ← Registry.new (← Settings.runtime (← Settings.load opts.settings) true)
  let some session ← registry.get? opts.id | throw (IO.userError s!"session {opts.id} not found")
  IO.println (toJson (← Output.write session opts.request opts.destination)).compress

/-- Request a browser authorization URL from the selected Lode instance.
The URL is sent to stdout and can also open in the local default browser. -/
def modelOAuth (base id : String) (openBrowser : Bool) : IO Unit := do
  unless Validate.sessionId id do throw (IO.userError "oauth requires a valid session id")
  unless (Validate.credentialUrl base true).isSome do
    throw (IO.userError "oauth requires an HTTPS Lode base URL or loopback HTTP")
  let token : String ← (← IO.getEnv "LODE_TOKEN").getDM
    (throw (IO.userError "set LODE_TOKEN for the selected Lode instance") : IO String)
  unless Secrets.validKey token do throw (IO.userError "LODE_TOKEN is invalid")
  let reply ← try
    Http.request .POST (base ++ s!"/v0/sessions/{id}/model-oauth")
      [("authorization", "Bearer " ++ token), ("accept", "application/json")] none 10000
    catch _ => throw (IO.userError "could not reach the selected Lode instance")
  unless Http.status reply == 200 && reply.body.size ≤ 65536 do
    throw (IO.userError s!"Lode authorization request failed (HTTP {Http.status reply})")
  let url : String ← IO.ofExcept
    ((Json.parse (Http.text reply) >>= (·.getObjValAs? String "authorizationUrl")).mapError IO.userError)
  let host := (url.splitOn "?").headD ""
  unless (Validate.credentialUrl host true).isSome && url.utf8ByteSize ≤ 16384 &&
      !url.any (fun c => c.toNat ≤ 32 || c.toNat == 127) do
    throw (IO.userError "Lode returned an invalid authorization URL")
  if openBrowser then
    let opener := if System.Platform.isOSX then "open" else "xdg-open"
    let result ← System.Process.run opener #[url] 10000 (env := Process.toolEnv)
    unless result.ok do throw (IO.userError "could not open the browser. Run oauth without --open to print the URL")
  IO.println url

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
