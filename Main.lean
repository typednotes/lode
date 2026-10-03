import Lode
import Linen.Network.WebApp.Server

/-- A number of seconds from the environment, in milliseconds. -/
def secondsEnv (name : String) (default : Nat) : IO Nat := do
  match ← IO.getEnv name with
  | none => return default * 1000
  | some v => match v.toNat? with
    | some n => return n * 1000
    | none => throw (IO.userError s!"{name} must be a number of seconds")

/-- A non-empty environment variable. -/
def env? (name : String) : IO (Option String) := do
  return (← IO.getEnv name).filter (!·.isEmpty)

/-- The server's default model, from `LODE_MODEL_*`. -/
def defaultModel (allowLocal : Bool) : IO (Option Lode.Model.Config) := do
  let some name ← env? "LODE_MODEL_NAME" | return none
  let api := (← env? "LODE_MODEL_API").getD "anthropic"
  let base ← match ← env? "LODE_MODEL_BASE_URL" with
    | some b => pure b
    | none => match Lode.Model.defaultBase? api with
      | some b => pure b
      | none => throw (IO.userError "LODE_MODEL_BASE_URL is required for this API")
  let nat (v : String) : IO (Option Nat) := do
    match ← env? v with
    | none => pure none
    | some s => match s.toNat? with
      | some n => pure (some n)
      | none => throw (IO.userError s!"{v} must be a number")
  let j : Lode.Model.ConfigJson :=
    { api := some api, name := some name, baseUrl := some base
      maxTokens := ← nat "LODE_MODEL_MAX_TOKENS", contextWindow := ← nat "LODE_MODEL_CONTEXT_WINDOW" }
  match Lode.Model.Config.ofConfigJson j none none allowLocal with
  | .ok c => return some c
  | .error e => throw (IO.userError s!"LODE_MODEL_*: {e}")

/-- Shared environment configuration; terminal runs enable local mode and keep
    state under the user's home unless `LODE_WORKDIR` is explicitly set. -/
def configFromEnv (cli : Bool := false) : IO Lode.Config := do
  let allowLocal := cli || (← IO.getEnv "LODE_ALLOW_LOCAL") == some "1"
  let workdir ← match ← env? "LODE_WORKDIR" with
    | some dir => pure dir
    | none =>
      if cli then do
        let some home ← env? "HOME" | throw (IO.userError "set HOME or LODE_WORKDIR for CLI state")
        pure s!"{home}/.local/state/lode"
      else pure "/var/lib/lode"
  let lun ← match ← env? "LODE_LUN_URL" with
    | none => pure none
    | some url => pure (some
        { url, token := ← env? "LODE_LUN_TOKEN"
          buildTimeoutMs := ← secondsEnv "LODE_LUN_BUILD_TIMEOUT" 3600
          callTimeoutMs := ← secondsEnv "LODE_LUN_CALL_TIMEOUT" 120 : Lode.Lun.Config })
  let cfg : Lode.Config :=
    { workdir := workdir
      token := ← env? "LODE_TOKEN"
      liaisonUrl := ← env? "LODE_LIAISON_URL"
      lun
      defaultModel := ← defaultModel allowLocal
      modelApiKey := ← env? "LODE_MODEL_API_KEY"
      allowLocal
      maxSteps := ((← env? "LODE_MAX_STEPS").bind String.toNat?).getD 200
      modelTimeoutMs := ← secondsEnv "LODE_MODEL_TIMEOUT" 600
      gitTimeoutMs := ← secondsEnv "LODE_GIT_TIMEOUT" 600
      checkTimeoutMs := ← secondsEnv "LODE_CHECK_TIMEOUT" 1800
      packageCache := (← env? "LODE_PACKAGE_CACHE").map System.FilePath.mk
      linenRev := (← env? "LODE_LINEN_REV").getD "v1.10.0"
      toolchain := (← env? "LODE_TOOLCHAIN").getD "leanprover/lean4:v4.34.0" }
  return cfg

/-- Start the HTTP service (also the no-argument behavior). -/
def serve : IO Unit := do
  let port : UInt16 := match (← IO.getEnv "LODE_PORT").bind String.toNat? with
    | some p => p.toUInt16
    | none => 8080
  let cfg ← configFromEnv
  let registry ← Lode.Registry.new cfg
  if cfg.allowLocal then IO.eprintln "lode: LOCAL MODE — file:// repositories and the scripted model accepted"
  if cfg.token.isNone then IO.eprintln "lode: LODE_TOKEN is not set — the API is unauthenticated"
  if cfg.lun.isNone then IO.eprintln "lode: LODE_LUN_URL is not set — lun_build and lun_call are unavailable"
  IO.println s!"lode listening on :{port}"
  Network.WebApp.Server.run port (Lode.application registry)

/-- Dispatch native stdio runs or the HTTP service, keeping diagnostics off stdout. -/
def main (args : List String) : IO UInt32 := do
  try
    match args with
    | [] | ["serve"] => serve; return 0
    | ["--help"] | ["-h"] | ["run", "--help"] | ["run", "-h"] =>
      IO.print Lode.Cli.usage
      return 0
    | "run" :: rest =>
      let opts ← match Lode.Cli.Options.parse rest with
        | .ok opts => pure opts
        | .error error => IO.eprintln s!"lode: {error}\n{Lode.Cli.usage}"; return 2
      Lode.Cli.run (← configFromEnv true) opts
    | _ => IO.eprintln s!"lode: unknown command\n{Lode.Cli.usage}"; return 2
  catch e =>
    IO.eprintln s!"lode: {e}"
    return 1
