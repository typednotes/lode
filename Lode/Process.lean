/-
  Lode.Process — run a command to completion, with a deadline

  Everything lode runs (`git`, `tar`, `lake`, the model's `bash` commands)
  goes through `run`: stdout and stderr captured, optional stdin, and a
  timeout after which the whole process group is killed (the child is started
  in its own session, so `lake`'s `lean` workers and a shell's children go
  with it). An optional abort flag is polled too, so a session abort stops a
  long `lake build` promptly. Same shape as `lun/Lun/Process.lean`.
-/

namespace Lode.Process

/-- How a command ended. -/
structure Result where
  /-- The exit code, or `none` if it was killed (deadline or abort). -/
  exitCode : Option UInt32
  stdout : String
  stderr : String

/-- It exited with `0`. -/
def Result.ok (r : Result) : Bool := r.exitCode == some 0

/-- Write the input, then drop the handle, which closes the child's stdin. -/
private def feed (h : IO.FS.Handle) (input : Option String) : IO Unit := do
  if let some s := input then
    -- A child that exits without reading closes the pipe; that is its answer.
    try h.putStr s; h.flush catch _ => pure ()

/-- Wait for `child`, killing its process group at `deadline` or when `abort`
    is set. -/
private def await (child : IO.Process.Child cfg) (deadline : Nat) (abort : Option (IO.Ref Bool)) :
    IO (Option UInt32) := do
  let mut code : Option UInt32 := none
  repeat
    match ← child.tryWait with
    | some c => code := some c; break
    | none =>
      let aborted ← match abort with
        | some r => r.get
        | none => pure false
      if aborted || (← IO.monoMsNow) ≥ deadline then
        child.kill
        let _ ← child.wait
        break
      IO.sleep 20
  return code

/-- Run `cmd args` in `cwd`, feeding `input` on stdin, killing it (and its
    process group) after `timeoutMs` milliseconds or once `abort` is set. -/
def run (cmd : String) (args : Array String) (timeoutMs : Nat)
    (cwd : Option System.FilePath := none) (env : Array (String × Option String) := #[])
    (input : Option String := none) (abort : Option (IO.Ref Bool) := none) : IO Result := do
  let child ← IO.Process.spawn
    { cmd, args, cwd, env, setsid := true
      stdin := .piped, stdout := .piped, stderr := .piped }
  let out ← IO.asTask child.stdout.readToEnd .dedicated
  let err ← IO.asTask child.stderr.readToEnd .dedicated
  let (stdin, child) ← child.takeStdin
  feed stdin input
  let code ← await child ((← IO.monoMsNow) + timeoutMs) abort
  let stdout ← IO.ofExcept (← IO.wait out)
  let stderr ← IO.ofExcept (← IO.wait err)
  return { exitCode := code, stdout, stderr }

/-- Run a command whose stdout is binary (`git cat-file blob …`); throws
    unless it exits with `0`. -/
def runBytes (cmd : String) (args : Array String) (timeoutMs : Nat)
    (cwd : Option System.FilePath := none) (env : Array (String × Option String) := #[]) :
    IO ByteArray := do
  let child ← IO.Process.spawn
    { cmd, args, cwd, env, setsid := true
      stdin := .null, stdout := .piped, stderr := .piped }
  let out ← IO.asTask child.stdout.readBinToEnd .dedicated
  let err ← IO.asTask child.stderr.readToEnd .dedicated
  let code ← await child ((← IO.monoMsNow) + timeoutMs) none
  let stdout ← IO.ofExcept (← IO.wait out)
  let stderr ← IO.ofExcept (← IO.wait err)
  unless code == some 0 do
    throw (IO.userError s!"{cmd} {" ".intercalate args.toList} failed: {stderr.trimAscii}")
  return stdout

/-- The environment `git` and `lake` run with: the host's global and system
    git configuration ignored (a `url.insteadOf` rewrite, a credential helper
    or commit signing there would change what is fetched or make a command
    hang), git never prompting, and a fixed committer identity. -/
def hermeticGit : Array (String × Option String) :=
  #[("GIT_CONFIG_GLOBAL", some "/dev/null"), ("GIT_CONFIG_NOSYSTEM", some "1"),
    ("GIT_TERMINAL_PROMPT", some "0"), ("GIT_ASKPASS", some "true"),
    ("GIT_AUTHOR_NAME", some "lode"), ("GIT_AUTHOR_EMAIL", some "lode@typednotes.org"),
    ("GIT_COMMITTER_NAME", some "lode"), ("GIT_COMMITTER_EMAIL", some "lode@typednotes.org")]

/-- lode's own configuration, removed from the environment of everything
    the model runs (`bash`, and `lake build`, which runs a project's
    lakefile): the API token, lun's token and a direct model key must not
    reach model-driven code. -/
def ownVariables : Array String :=
  #["LODE_TOKEN", "LODE_MODEL_API_KEY", "LODE_LUN_TOKEN", "LODE_LUN_URL", "LODE_LIAISON_URL",
    "LODE_MODEL_API", "LODE_MODEL_NAME", "LODE_MODEL_BASE_URL", "LODE_MODEL_MAX_TOKENS",
    "LODE_MODEL_CONTEXT_WINDOW", "LODE_WORKDIR", "LODE_PORT", "LODE_ALLOW_LOCAL"]

/-- The environment of model-driven commands: `hermeticGit`, without lode's
    own variables. -/
def toolEnv : Array (String × Option String) :=
  hermeticGit ++ ownVariables.map (·, none)

/-- A one-line account of a failed command, for error messages and logs. -/
def Result.describe (r : Result) (what : String) : String :=
  let reason := match r.exitCode with
    | none => "was stopped (timeout or abort)"
    | some c => s!"exited with {c}"
  let detail := (if r.stderr.trimAscii.isEmpty then r.stdout else r.stderr).trimAscii.toString
  let detail := if detail.length > 2000 then (detail.take 2000).toString ++ "…" else detail
  s!"{what} {reason}" ++ (if detail.isEmpty then "" else s!": {detail}")

end Lode.Process
