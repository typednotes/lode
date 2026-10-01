/-
  Lode.Tools — what the model can do

  A small, sharp set, after pi (`read`, `write`, `edit`, `bash`, plus the
  read-only `ls` and `grep`) and OpenCode (`todo`, and compiler feedback after
  edits: `check`), and three that are lode's mission — `publish` the
  workspace to the shared repository, `lun_build` it, `lun_call` what lun
  built.

  **Parse, don't validate.** A tool call's arguments are the model's text.
  Each tool parses them into a typed value (`Args`) before anything runs; a
  parse error is the tool's result, sent back to the model, which corrects
  itself. File paths are resolved by `Validate.resolve` (never outside the
  checkout) and writes refused under `.git` and `.lake` (`Validate.writable`).
  `bash` can of course do anything the container lets it: the container is
  the boundary, as it is for lun.

  Everything a session provides (publishing, lun, the todo list) comes in
  through `Env`, so this module knows nothing about sessions.
-/
import Lean.Data.Json
import Lode.Message
import Lode.Model
import Lode.Process
import Lode.Validate
import Lode.ToolPolicy
import Lode.Lsp
import Linen.System.LakeLog
import Linen.Control.Monad.Effect.FileSystem

namespace Lode.Tools

open Lean (Json ToJson FromJson toJson fromJson?)
open System (FilePath)

-- ── Truncation ──────────────────────────────────────────────────────────────

/-- The most a tool result may carry, in lines and in characters (pi's
    limits): a larger output is cut, and the cut is said. -/
def maxLines : Nat := 2000
def maxChars : Nat := 50000

/-- Keep the first lines of `s` within the limits (for `read`, `grep`). -/
def truncateHead (s : String) (lines : Nat := maxLines) (chars : Nat := maxChars) : String × Bool :=
  let ls := s.splitOn "\n"
  let (kept, _, cut) := ls.foldl (init := (#[], 0, false)) fun (acc, n, cut) l =>
    if cut then (acc, n, cut)
    else if acc.size ≥ lines || n + l.length + 1 > chars then (acc, n, true)
    else (acc.push l, n + l.length + 1, false)
  ("\n".intercalate kept.toList, cut)

/-- Keep the last lines of `s` within the limits (for `bash`, `check`: the
    end of a log is where the failure is). -/
def truncateTail (s : String) (lines : Nat := maxLines) (chars : Nat := maxChars) : String × Bool :=
  let ls := (s.splitOn "\n").reverse
  let (kept, _, cut) := ls.foldl (init := (#[], 0, false)) fun (acc, n, cut) l =>
    if cut then (acc, n, cut)
    else if acc.size ≥ lines || n + l.length + 1 > chars then (acc, n, true)
    else (acc.push l, n + l.length + 1, false)
  ("\n".intercalate kept.toList.reverse, cut)

/-- Cut one over-long line (minified files, generated JSON). -/
def clipLine (l : String) (max : Nat := 2000) : String :=
  if l.length > max then (l.take max).toString ++ " …(line truncated)" else l

-- ── Pure tool logic ─────────────────────────────────────────────────────────

/-- `read`'s rendering: lines `offset ..< offset + limit` (1-based), each
    prefixed with its number, and a note if more follow. -/
def numberLines (text : String) (offset limit : Nat) : String :=
  let all := text.splitOn "\n"
  let all := if text.endsWith "\n" then all.dropLast else all
  let start := offset - 1
  let chosen := (all.drop start).take limit
  let width := (toString (start + chosen.length)).length
  let pad (n : Nat) := String.ofList (List.replicate (width - (toString n).length) ' ') ++ toString n
  let body := "\n".intercalate (chosen.zipIdx.map fun (l, i) => s!"{pad (start + i + 1)}\t{clipLine l}")
  let rest := all.length - start - chosen.length
  if all.isEmpty || (all.length == 1 && all.head! == "") then "(empty file)"
  else if start ≥ all.length then s!"(the file has {all.length} lines; offset {offset} is past its end)"
  else if rest > 0 then
    body ++ s!"\n\n({rest} more lines; continue with offset={start + chosen.length + 1})"
  else body

/-- The number of non-overlapping occurrences of `pat` in `s`. -/
def occurrences (s pat : String) : Nat :=
  if pat.isEmpty then 0 else (s.splitOn pat).length - 1

/-- `edit`'s replacement: `old` must occur exactly once, or at least once
    with `all`. Returns the new text and the number of replacements. -/
def applyEdit (text old new : String) (all : Bool) : Except String (String × Nat) := do
  if old.isEmpty then throw "`old` is empty; use `write` to create a file"
  if old == new then throw "`old` and `new` are the same"
  let n := occurrences text old
  if n == 0 then
    throw "`old` was not found in the file. It must match exactly, whitespace and indentation included; read the file again and copy the text"
  if n > 1 && !all then
    throw s!"`old` occurs {n} times; include more surrounding lines to make it unique, or set `all` to true"
  return (text.replace old new, n)

-- ── Todo list ───────────────────────────────────────────────────────────────

/-- One item of the model's task list. -/
structure Todo where
  content : String
  /-- `pending`, `in_progress`, `completed` or `cancelled`. -/
  status : String
  deriving DecidableEq, Repr, Inhabited, ToJson, FromJson

/-- The statuses an item may have. -/
def Todo.statuses : List String := ["pending", "in_progress", "completed", "cancelled"]

/-- The list, as the model reads it back. -/
def renderTodos (ts : Array Todo) : String :=
  if ts.isEmpty then "(the task list is empty)" else
  "\n".intercalate (ts.toList.map fun t =>
    let box := match t.status with
      | "completed" => "[x]" | "in_progress" => "[~]" | "cancelled" => "[-]" | _ => "[ ]"
    s!"{box} {t.content}")

-- ── Arguments ───────────────────────────────────────────────────────────────

/-! Each tool's arguments, as the model writes them (decoded by derived
    `FromJson`, whose errors name the field), then checked. -/

structure ReadArgs where
  path : String
  offset : Option Nat := none
  limit : Option Nat := none
  deriving FromJson

structure LsArgs where
  path : Option String := none
  deriving FromJson

structure GrepArgs where
  pattern : String
  path : Option String := none
  deriving FromJson

structure WriteArgs where
  path : String
  content : String
  deriving FromJson

structure EditArgs where
  path : String
  old : String
  new : String
  all : Option Bool := none
  deriving FromJson

structure BashArgs where
  command : String
  timeout : Option Nat := none
  deriving FromJson

structure TodoArgs where
  todos : Array Todo
  deriving FromJson

structure CheckArgs where
  targets : Option (Array String) := none
  deriving FromJson

structure PublishArgs where
  message : String
  deriving FromJson

structure LunCallArgs where
  kind : String
  name : String
  body : Option Json := none
  deriving FromJson

/-- A writer may supply runtime input data, never execution ceilings, bindings,
    connector grants or credentials. There is no arbitrary request-body case. -/
inductive RuntimeInput where
  | function (input : Option Json)
  | batch (inputs : Array Json)
  | graph (inputs : Option Json)

def RuntimeInput.kind : RuntimeInput → String
  | .graph _ => "graph" | _ => "function"

def RuntimeInput.field : RuntimeInput → String
  | .function _ => "input" | _ => "inputs"

def RuntimeInput.value : RuntimeInput → Option Json
  | .function input | .graph input => input
  | .batch inputs => some (Json.arr inputs)

/-- Only a fixed input field can be emitted at the protocol's top level. -/
def RuntimeInput.body (input : RuntimeInput) : Json :=
  Json.mkObj ((input.value.map (fun value => [(input.field, value)])).getD [])

theorem RuntimeInput.input_only (input : RuntimeInput) : input.field ∈ ["input", "inputs"] := by
  cases input <;> simp [RuntimeInput.field]

/-- A tool call's arguments, parsed and checked. -/
inductive Args where
  | read (path : String) (offset limit : Nat)
  | ls (path : String)
  | grep (pattern : String) (path : String)
  | write (path content : String)
  | edit (path old new : String) (all : Bool)
  | bash (command : String) (timeoutSec : Nat)
  | todo (items : Array Todo)
  | check (targets : Array String)
  | lsp (request : Lode.Lsp.Arguments)
  | publish (message : String)
  | lunBuild
  | lunCall (name : String) (input : RuntimeInput)

/-- The operation is derived from the arguments actually executed. -/
def Args.operation : Args → Operation
  | .read .. => .read | .ls .. => .ls | .grep .. => .grep
  | .write .. => .write | .edit .. => .edit | .bash .. => .bash
  | .todo .. => .todo | .check .. => .check | .lsp .. => .lsp | .publish .. => .publish
  | .lunBuild => .lunBuild | .lunCall .. => .lunCall

/-- Execution consumes evidence for both the launch/session ceiling and the
    selected agent. A checked name cannot be swapped for unrelated arguments. -/
structure AuthorizedArgs (policy : Policy) (agent : List String) where
  args : Args
  policyAllows : policy.permits args.operation
  agentAllows : args.operation.name ∈ agent

def AuthorizedArgs.check (policy : Policy) (agent : List String) (args : Args) :
    Except String (AuthorizedArgs policy agent) :=
  if hp : policy.permits args.operation then
    if ha : args.operation.name ∈ agent then .ok ⟨args, hp, ha⟩
    else .error s!"the tool '{args.operation.name}' is not available to this agent"
  else .error s!"the tool '{args.operation.name}' is denied by the session tool policy"

theorem AuthorizedArgs.authority_bounded (bounded : BoundedPolicy ceiling)
    (a : AuthorizedArgs bounded.policy agent) : ceiling.permits a.args.operation :=
  bounded.bounded _ a.policyAllows

/-- A lake target a model may name: letters, digits, `_`, `.`, `:`, `+`, `/`
    and `-` (`Mod.Sub`, `pkg/lib`, `+Mod`, `Lib:static`), nothing a shell or
    lake would read as an option. -/
def validTarget (s : String) : Bool :=
  !s.isEmpty && s.length ≤ 256 && !s.startsWith "-" &&
    s.all fun (c : Char) => c.isAlphanum || "_.:+/-".toList.contains c

/-- Parse the arguments of tool `name`. -/
def Args.parse (name : String) (arguments : String) : Except String Args := do
  if name == "lsp" then
    unless arguments.utf8ByteSize ≤ 4096 && Lode.Lsp.shallowJson arguments do
      throw "lsp: invalid or oversized arguments"
  let j ← match Json.parse (if arguments.trimAscii.isEmpty then "{}" else arguments) with
    | .ok j@(.obj _) => pure j
    | .ok _ => throw "the arguments must be a JSON object"
    | .error e => throw s!"the arguments are not valid JSON ({e})"
  let check (ok : Bool) (msg : String) : Except String Unit := unless ok do throw msg
  match name with
  | "read" =>
    let a : ReadArgs ← fromJson? j
    let offset := a.offset.getD 1
    check (offset ≥ 1) "read.offset: lines are numbered from 1"
    return .read a.path offset (min (a.limit.getD maxLines) maxLines)
  | "ls" =>
    let a : LsArgs ← fromJson? j
    return .ls (a.path.getD ".")
  | "grep" =>
    let a : GrepArgs ← fromJson? j
    return .grep a.pattern (a.path.getD ".")
  | "write" =>
    let a : WriteArgs ← fromJson? j
    return .write a.path a.content
  | "edit" =>
    let a : EditArgs ← fromJson? j
    return .edit a.path a.old a.new (a.all.getD false)
  | "bash" =>
    let a : BashArgs ← fromJson? j
    let t := a.timeout.getD 120
    check (t ≥ 1 && t ≤ 1800) "bash.timeout: between 1 and 1800 seconds"
    return .bash a.command t
  | "todo" =>
    let a : TodoArgs ← fromJson? j
    for t in a.todos do
      check (Todo.statuses.contains t.status) s!"todo: '{t.status}' is not one of {Todo.statuses}"
    return .todo a.todos
  | "check" =>
    let a : CheckArgs ← fromJson? j
    let targets := a.targets.getD #[]
    for t in targets do check (validTarget t) s!"check.targets: '{t}' is not a lake target"
    return .check targets
  | "lsp" => return .lsp (← Lode.Lsp.Arguments.parse j)
  | "publish" =>
    let a : PublishArgs ← fromJson? j
    let m := a.message
    check (!m.trimAscii.isEmpty && m.length ≤ 10000) "publish.message: a non-empty commit message"
    return .publish m
  | "lun_build" => return .lunBuild
  | "lun_call" =>
    let a : LunCallArgs ← fromJson? j
    check (a.kind == "function" || a.kind == "graph") "lun_call.kind: 'function' or 'graph'"
    check (Validate.functionName a.name) "lun_call.name: a function or graph name (dotted identifiers)"
    let body := a.body.getD (Json.mkObj [])
    let fields ← body.getObj? |>.mapError (fun _ => "lun_call.body: must be an input object")
    let allowed := if a.kind == "function" then ["input", "inputs"] else ["inputs"]
    check (fields.toList.all (fun (name, _) => allowed.contains name))
      "lun_call.body: only function input/inputs or graph inputs are accepted; execution policy and credentials are caller-owned"
    check (!((body.getObjVal? "input").isOk && (body.getObjVal? "inputs").isOk))
      "lun_call.body: choose input or inputs, not both"
    let input ← if a.kind == "graph" then do
      let inputs := (body.getObjVal? "inputs").toOption
      if let some value := inputs then
        check value.getObj?.isOk "lun_call.body.inputs: graph inputs must be an object"
      pure (RuntimeInput.graph inputs)
    else if let .ok inputs := body.getObjValAs? (Array Json) "inputs" then
      pure (RuntimeInput.batch inputs)
    else if (body.getObjVal? "inputs").isOk then
      throw "lun_call.body.inputs: function batch inputs must be an array"
    else pure (RuntimeInput.function (body.getObjVal? "input").toOption)
    return .lunCall a.name input
  | other => throw s!"there is no tool named '{other}'"

-- ── Specifications ──────────────────────────────────────────────────────────

private def prop (type description : String) : Json :=
  Json.mkObj [("type", type), ("description", description)]

private def object (props : List (String × Json)) (required : List String) : Json :=
  Json.mkObj [("type", "object"), ("properties", Json.mkObj props),
              ("required", toJson required.toArray)]

/-- Every tool, as the model is told about it. -/
def specs : Array Model.ToolSpec := #[
  { name := "read"
    description := "Read a text file, with line numbers. Paths are relative to the project directory. At most 2000 lines per call: use offset/limit for more. Read a file before editing it."
    schema := object [("path", prop "string" "File path"),
      ("offset", prop "integer" "First line to read (1-based, default 1)"),
      ("limit", prop "integer" "Number of lines (default and max 2000)")] ["path"] },
  { name := "ls"
    description := "List the files under a directory, recursively (tracked and untracked; .git, .lake and gitignored files are skipped)."
    schema := object [("path", prop "string" "Directory (default: the project directory)")] [] },
  { name := "grep"
    description := "Search file contents with an extended regular expression (git grep -n -E). Returns file:line:text."
    schema := object [("pattern", prop "string" "Regular expression"),
      ("path", prop "string" "Directory or file to search (default: the project directory)")] ["pattern"] },
  { name := "write"
    description := "Create or overwrite a file with the given content (parent directories are created). Prefer `edit` for changes to an existing file."
    schema := object [("path", prop "string" "File path"),
      ("content", prop "string" "The whole new content")] ["path", "content"] },
  { name := "edit"
    description := "Replace exact text in a file. `old` must match the file exactly (whitespace and indentation included) and occur exactly once, unless `all` is true."
    schema := object [("path", prop "string" "File path"),
      ("old", prop "string" "Exact text to replace"),
      ("new", prop "string" "Replacement text"),
      ("all", prop "boolean" "Replace every occurrence (default false)")] ["path", "old", "new"] },
  { name := "bash"
    description := "Run a bash command in the project directory. Returns the exit code and the last 2000 lines of stdout+stderr. Default timeout 120 s (max 1800). Not interactive."
    schema := object [("command", prop "string" "The command"),
      ("timeout", prop "integer" "Timeout in seconds")] ["command"] },
  { name := "todo"
    description := "Replace your task list. Use it for work with several steps: one item in_progress at a time, mark items completed as soon as they are done."
    schema := object [("todos", Json.mkObj [("type", "array"), ("items", object
      [("content", prop "string" "The task"),
       ("status", Json.mkObj [("type", "string"),
         ("enum", toJson #["pending", "in_progress", "completed", "cancelled"])])]
      ["content", "status"])])] ["todos"] },
  { name := "check"
    description := "Build the project with `lake build` and return its errors and warnings (file:line:col). Run it after changing Lean files, and until it is clean before publishing."
    schema := object [("targets", Json.mkObj [("type", "array"), ("items", prop "string" "A lake target"),
      ("description", "Targets to build (default: the default targets)")])] [] },
  { name := "lsp"
    description := "Read-only Lean language-server query of an existing workspace .lean file: hover, definition, completion, diagnostics or goals. Positions are zero-based lines and UTF-16 character offsets (not bytes/code points). Diagnostics takes no position. Uses a bounded ephemeral lake serve worker; definitions outside the checkout are omitted. No arbitrary RPC, commands, code actions or unsaved text."
    schema := object [
      ("operation", Json.mkObj [("type", "string"), ("enum", toJson #["hover", "definition", "completion", "diagnostics", "goals"])]),
      ("path", prop "string" "Existing relative .lean document, without traversal or URI escapes"),
      ("line", prop "integer" "Zero-based line (required except diagnostics)"),
      ("character", prop "integer" "Zero-based UTF-16 code-unit offset (required except diagnostics)")] ["operation", "path"] },
  { name := "publish"
    description := "Commit every change in the workspace and push it to the shared repository's branch. Returns the new commit. lun builds only published commits."
    schema := object [("message", prop "string" "Commit message")] ["message"] },
  { name := "lun_build"
    description := "Have lun build the last published commit, with the functions and graphs declared in lun.json in the project directory. Waits for the build; returns its state, diagnostics (attributed to functions, graphs or the project), and once ready its functions and graphs."
    schema := object [] [] },
  { name := "lun_call"
    description := "Call a function, or run a graph once, of the latest ready lun build. Function body: {\"input\": x} (x is the value, an array of values for several arguments, omitted for none) or {\"inputs\": [x1, x2]} for several calls. Graph body: {\"inputs\": {\"name\": value}}."
    schema := object [("kind", Json.mkObj [("type", "string"), ("enum", toJson #["function", "graph"])]),
      ("name", prop "string" "The function or graph name"),
      ("body", prop "object" "Input data only: function input or inputs, graph inputs. Execution policy, bindings and credentials are never model-selected.")] ["kind", "name"] } ]

/-- The tools of an agent, by name. -/
def specsFor (names : List String) : Array Model.ToolSpec := specs.filter (names.contains ·.name)

/-- Advertise the same intersection that execution consumes. -/
def specsForPolicy (policy : Policy) (agent : List String) : Array Model.ToolSpec :=
  specsFor (agent.filter policy.names.contains)

-- ── Execution ───────────────────────────────────────────────────────────────

/-- What a tool needs from its session. -/
structure Env where
  /-- The checkout's absolute path. -/
  root : FilePath
  /-- The project directory, as components under the checkout. -/
  project : List String
  abort : IO.Ref Bool
  checkTimeoutMs : Nat
  todos : IO.Ref (Array Todo)
  /-- Make the package cache available to the project before a build. -/
  seed : IO Unit
  publish : String → IO String
  /-- The report, and whether the build failed. -/
  lunBuild : IO (String × Bool)
  lunCall : String → String → Json → IO String

/-- The project directory's absolute path. -/
def Env.projectDir (env : Env) : FilePath :=
  env.project.foldl (fun (acc : FilePath) (c : String) => acc / c) env.root

/-- Resolve a path the model gave. -/
def Env.resolve (env : Env) (p : String) : Except String (List String × FilePath) := do
  let comps ← Validate.resolve env.root.toString env.project p
  return (comps, comps.foldl (fun (acc : FilePath) (c : String) => acc / c) env.root)

/-- A checkout path as the model sees it: relative to the project directory. -/
def Env.display (env : Env) (comps : List String) : String :=
  if env.project.isPrefixOf comps then
    let rest := comps.drop env.project.length
    if rest.isEmpty then "." else "/".intercalate rest
  else
    "/".intercalate (List.replicate env.project.length ".." ++ comps)

/-- A repository-relative path printed by git, as the model sees it. -/
def Env.displayGitPath (env : Env) (p : String) : String := env.display (p.splitOn "/")

/-- A path as components, for linen's `FileSystem` capabilities. -/
def pathComponents (p : FilePath) : List String := p.components.filter (!·.isEmpty)

open Control.Monad.Effect.FileSystem (Capability Op ScopedPath) in
/-- The workspace as a linen filesystem capability: read and write, only under
    the checkout (component-wise, so a sibling `checkout-evil` is outside). -/
def Env.capability (env : Env) : Capability :=
  { canRead := true, canWrite := true, scopes := [{ root := pathComponents env.root }] }

open Control.Monad.Effect.FileSystem (Op ScopedPath) in
/-- Where an access to `file` really lands, symbolic links followed: the
    deepest existing ancestor is resolved, then the path is checked against
    the workspace's capability (`Env.capability`), and for a write, kept out
    of `.git` and `.lake`. A link planted in the checkout therefore cannot
    carry an access outside it, or a write into lode's bookkeeping. Returns
    why not, if not. -/
def Env.confine (env : Env) (op : Op) (file : FilePath) (shown : String) : IO (Option String) := do
  let rec existing : Nat → FilePath → List String → IO (FilePath × List String)
    | 0, p, rest => pure (p, rest)
    | n + 1, p, rest => do
      if ← p.pathExists then pure (p, rest)
      else match p.parent, p.fileName with
        | some q, some name => existing n q (name :: rest)
        | _, _ => pure (p, rest)
  let (anc, rest) ← existing 256 file []
  let real := pathComponents (← IO.FS.realPath anc) ++ rest
  if (ScopedPath.check? env.capability op real).isNone then
    return some s!"'{shown}' leads outside the workspace (through a symbolic link)"
  if op == .write && !Validate.writable (real.drop (pathComponents env.root).length) then
    return some s!"'{shown}' may not be written (it leads into .git or .lake)"
  return none

private def git (env : Env) (args : Array String) : IO System.Process.Result :=
  System.Process.run "git" args 60000 (cwd := env.root) (env := Process.hermeticGit) (abort := env.abort)

private def pathspec (comps : List String) : String :=
  if comps.isEmpty then "." else "/".intercalate comps

private def withCut (text : String) (cut : Bool) (what : String) : String :=
  if cut then text ++ s!"\n\n({what} truncated)" else text

/-- Run `lake build`, seeding the package cache first, and report its
    diagnostics. -/
def check (env : Env) (targets : Array String) : IO (String × Bool) := do
  env.seed
  let r ← System.Process.run "lake" (#["build"] ++ targets) env.checkTimeoutMs (cwd := env.projectDir)
    (env := Process.toolEnv) (abort := env.abort)
  let log := r.stdout ++ "\n" ++ r.stderr
  let diags := (System.LakeLog.parse log).filter (!·.isSummary)
  let errors := diags.filter (·.severity == "error")
  let warnings := diags.filter (·.severity == "warning")
  let shown := (errors ++ warnings).take 60
  let listing := "\n\n".intercalate (shown.map System.LakeLog.Diagnostic.render)
  let more := if errors.length + warnings.length > shown.length then
    s!"\n\n({errors.length + warnings.length - shown.length} more not shown)" else ""
  if r.ok then
    return (if warnings.isEmpty then "Build succeeded, no warnings."
      else s!"Build succeeded with {warnings.length} warning(s):\n\n{listing}{more}", false)
  else if r.exitCode.isNone then
    return ("The build was stopped (timeout or abort).", true)
  else if diags.isEmpty then
    let (tail, cut) := truncateTail log 200 20000
    return (withCut s!"The build failed:\n\n{tail}" cut "log", true)
  else
    return (s!"The build failed: {errors.length} error(s), {warnings.length} warning(s).\n\n{listing}{more}", true)

/-- Lun reports effect/decoder failures in HTTP-200 JSON envelopes. Preserve
    their error status for the model without treating nested output data as errors. -/
def runtimeCallFailed (text : String) : Bool :=
  (Lean.Json.parse text >>= (·.getObjValAs? String "error")).isOk

private def runUnchecked (env : Env) : Args → IO (String × Bool)
  | .read p offset limit => do
    let (_, file) ← IO.ofExcept (env.resolve p |>.mapError IO.userError)
    unless ← file.pathExists do return (s!"'{p}' does not exist", true)
    if let some e ← env.confine .read file p then return (e, true)
    if ← file.isDir then return (s!"'{p}' is a directory; use `ls`", true)
    let bytes ← IO.FS.readBinFile file
    match String.fromUTF8? bytes with
    | none => return (s!"'{p}' is a binary file ({bytes.size} bytes)", true)
    | some text =>
      let (out, cut) := truncateHead (numberLines text offset limit) (maxLines + 4) maxChars
      return (withCut out cut "output", false)
  | .ls p => do
    let (comps, dir) ← IO.ofExcept (env.resolve p |>.mapError IO.userError)
    unless ← dir.pathExists do return (s!"'{p}' does not exist", true)
    let r ← git env #["ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate",
      "--", pathspec comps]
    unless r.ok do return (r.describe "git ls-files", true)
    let files := (r.stdout.splitOn "\n").filter (!·.isEmpty) |>.map env.displayGitPath
    if files.isEmpty then return ("(no files)", false)
    let (out, cut) := truncateHead ("\n".intercalate files) 1000 maxChars
    return (withCut out cut "listing", false)
  | .grep pattern p => do
    let (comps, _) ← IO.ofExcept (env.resolve p |>.mapError IO.userError)
    let r ← git env #["grep", "-n", "-I", "-E", "--untracked", "--no-color", "-e", pattern,
      "--", pathspec comps]
    match r.exitCode with
    | some 0 =>
      let lines := (r.stdout.splitOn "\n").filter (!·.isEmpty) |>.map fun l =>
        match l.splitOn ":" with
        | f :: rest => clipLine (":".intercalate (env.displayGitPath f :: rest))
        | [] => l
      let (out, cut) := truncateHead ("\n".intercalate lines) 500 maxChars
      return (withCut out cut "matches", false)
    | some 1 => return (if r.stderr.trimAscii.isEmpty then "(no matches)" else r.describe "git grep", r.stderr.trimAscii.isEmpty == false)
    | _ => return (r.describe "git grep", true)
  | .write p content => do
    let (comps, file) ← IO.ofExcept (env.resolve p |>.mapError IO.userError)
    unless Validate.writable comps do return (s!"'{p}' may not be written (.git and .lake are off limits)", true)
    if let some e ← env.confine .write file p then return (e, true)
    if ← file.isDir then return (s!"'{p}' is a directory", true)
    if let some dir := file.parent then IO.FS.createDirAll dir
    IO.FS.writeFile file content
    return (s!"Wrote {content.utf8ByteSize} bytes to {env.display comps}.", false)
  | .edit p old new all => do
    let (comps, file) ← IO.ofExcept (env.resolve p |>.mapError IO.userError)
    unless Validate.writable comps do return (s!"'{p}' may not be written (.git and .lake are off limits)", true)
    if let some e ← env.confine .write file p then return (e, true)
    unless ← file.pathExists do return (s!"'{p}' does not exist; use `write` to create it", true)
    let some text := String.fromUTF8? (← IO.FS.readBinFile file) | return (s!"'{p}' is not text", true)
    match applyEdit text old new all with
    | .error e => return (e, true)
    | .ok (text', n) =>
      IO.FS.writeFile file text'
      return (s!"Replaced {n} occurrence{if n == 1 then "" else "s"} in {env.display comps}.", false)
  | .bash command timeoutSec => do
    let r ← System.Process.run "bash" #["-c", command] (timeoutSec * 1000) (cwd := env.projectDir)
      (env := Process.toolEnv) (input := some "") (abort := env.abort)
    let out := (r.stdout ++ (if r.stderr.isEmpty then "" else
      (if r.stdout.isEmpty || r.stdout.endsWith "\n" then "" else "\n") ++ r.stderr)).trimAsciiEnd.toString
    let (tail, cut) := truncateTail out
    let aborted ← env.abort.get
    let status := match r.exitCode with
      | some c => s!"exit code {c}"
      | none => if aborted then "aborted" else s!"timed out after {timeoutSec} s"
    let body := if tail.isEmpty then "(no output)" else withCut tail cut "earlier output"
    return (s!"{status}\n{body}", !r.ok)
  | .todo items => do
    env.todos.set items
    return (renderTodos items, false)
  | .check targets => check env targets
  | .lsp request => Lode.Lsp.run env.root env.projectDir env.abort env.checkTimeoutMs request
  | .publish message => do
    try return (← env.publish message, false) catch e => return (s!"publish failed: {e}", true)
  | .lunBuild => do
    try env.lunBuild catch e => return (s!"lun_build failed: {e}", true)
  | .lunCall name input => do
    try
      let text ← env.lunCall input.kind name input.body
      return (text, runtimeCallFailed text)
    catch e => return (s!"lun_call failed: {e}", true)

/-- Run a tool call, if the agent has that tool; every failure becomes an
    error result for the model, never an exception. -/
def run (env : Env) (authorized : AuthorizedArgs policy agent) : IO (String × Bool) :=
  runUnchecked env authorized.args

/-- Parse then authorize the exact operation before any tool IO. -/
def execute (env : Env) (policy : Policy) (allowed : List String) (call : ToolCall) : IO ToolResult := do
  let result (content : String) (isError : Bool) : ToolResult :=
    { id := call.id, name := call.name, content, isError, nativeId := call.nativeId }
  unless allowed.contains call.name do
    return result s!"the tool '{call.name}' is not available (available: {", ".intercalate allowed})" true
  match Args.parse call.name call.arguments with
  | .error e => return result s!"invalid arguments: {e}" true
  | .ok args =>
    let authorized ← match AuthorizedArgs.check policy allowed args with
      | .ok a => pure a
      | .error e => return result e true
    try
      let (content, isError) ← run env authorized
      return result content isError
    catch e => return result (toString e) true

end Lode.Tools
