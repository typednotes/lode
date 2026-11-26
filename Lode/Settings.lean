/-
  Operator settings for HTTP and stdio. Both file formats share one schema.
  Credentials come from the process environment or authenticated requests.
-/
import Lake.Toml.Load
import Lode.Session

namespace Lode.Settings

open Lean (FromJson Json fromJson? toJson)

/-- The operator's default model. `provider` supplies protocol and endpoint
    defaults, and `api` can select an explicit supported protocol. -/
structure ModelFile where
  provider : Option String := none
  api : Option String := none
  name : Option String := none
  baseUrl : Option String := none
  maxTokens : Option Nat := none
  contextWindow : Option Nat := none
  deriving FromJson

/-- The non-secret location of the operator's direct model key. -/
structure SecretsFile where
  baseUrl : Option String := none
  modelKeyPath : Option String := none
  deriving FromJson

/-- Non-secret startup settings accepted in TOML and JSON. Timeouts are in seconds. -/
structure File where
  port : Option Nat := none
  workdir : Option String := none
  allowLocal : Option Bool := none
  liaisonUrl : Option String := none
  lunUrl : Option String := none
  lunBuildTimeout : Option Nat := none
  lunCallTimeout : Option Nat := none
  maxSteps : Option Nat := none
  modelTimeout : Option Nat := none
  gitTimeout : Option Nat := none
  checkTimeout : Option Nat := none
  packageCache : Option String := none
  linenRev : Option String := none
  toolchain : Option String := none
  model : Option ModelFile := none
  secrets : Option SecretsFile := none
  deriving FromJson

private def fields (label : String) (allowed : List String) (json : Json) : Except String Unit := do
  let obj ← json.getObj?.mapError (fun _ => s!"{label} must be an object")
  unless obj.toList.all (fun (key, _) => allowed.contains key) do
    throw s!"{label} contains an unsupported field"

/-- Decode the shared settings schema. Reject misspellings and credential fields. -/
def parse (json : Json) : Except String File := do
  fields "settings" ["port", "workdir", "allowLocal", "liaisonUrl", "lunUrl", "lunBuildTimeout",
    "lunCallTimeout", "maxSteps", "modelTimeout", "gitTimeout", "checkTimeout", "packageCache",
    "linenRev", "toolchain", "model", "secrets"] json
  if let .ok model := json.getObjVal? "model" then
    unless model == .null do
      fields "settings.model" ["provider", "api", "name", "baseUrl", "maxTokens", "contextWindow"] model
  if let .ok secrets := json.getObjVal? "secrets" then
    unless secrets == .null do fields "settings.secrets" ["baseUrl", "modelKeyPath"] secrets
  (fromJson? json).mapError (fun _ => "settings contain a value of the wrong type")

private def tomlScalar : Lake.Toml.Value → Except String Json
  | .string _ text => pure (.str text)
  | .integer _ number => pure (toJson number)
  | .boolean _ flag => pure (.bool flag)
  | _ => throw "settings values must be strings, integers or booleans"

private def tomlObject (table : Lake.Toml.Table) (value : Lake.Toml.Value → Except String Json) :
    Except String Json := do
  return Json.mkObj (← table.items.toList.mapM fun (key, val) => do
    let .str .anonymous name := key | throw "settings keys must be simple names"
    return (name, ← value val))

private def env? (name : String) : IO (Option String) := do
  return (← IO.getEnv name).filter (!·.isEmpty)

/-- An explicit path wins over `LODE_SETTINGS`. Settings direct authenticated
    requests, so loading a file always requires an operator-selected path.
    Errors identify the file without quoting its contents. -/
def load (path : Option String := none) : IO File := do
  let some path := path <|> (← env? "LODE_SETTINGS") | return {}
  let text ← IO.FS.readFile path
  let result ← if path.endsWith ".json" then
    pure (Json.parse text |>.mapError (fun _ => "invalid JSON"))
  else if path.endsWith ".toml" then do
    match ← (Lake.Toml.loadToml (Lean.Parser.mkInputContext text path)).toBaseIO with
    | .error _ => pure (.error "invalid TOML")
    | .ok table => pure (tomlObject table fun
        | .table _ nested => tomlObject nested tomlScalar
        | value => tomlScalar value)
  else pure (.error "expected a .toml or .json filename")
  IO.ofExcept ((result >>= parse).mapError (fun error => IO.userError s!"{path}: {error}"))

private def text (name : String) (file : Option String) : IO (Option String) := do
  return (← env? name) <|> file

private def number (name : String) (file : Option Nat) : IO (Option Nat) := do
  let some value ← env? name | return file
  let some parsed := value.toNat? | throw (IO.userError s!"{name} must be a nonnegative integer")
  return some parsed

private def seconds (name : String) (file : Option Nat) (fallbackMs : Nat) : IO Nat := do
  return ((← number name file).map (· * 1000)).getD fallbackMs

private def localMode (settings : File) : IO Bool := do
  match ← env? "LODE_ALLOW_LOCAL" with
  | some "1" => pure true
  | some "0" => pure false
  | none => pure (settings.allowLocal.getD false)
  | some _ => throw (IO.userError "LODE_ALLOW_LOCAL must be 0 or 1")

private def defaultModel (allowLocal : Bool) (file : ModelFile) : IO (Option Model.Config) := do
  let some name ← text "LODE_MODEL_NAME" file.name | return none
  let provider ← text "LODE_MODEL_PROVIDER" file.provider
  if let some provider := provider then
    unless Model.providers.contains provider do throw (IO.userError "settings.model.provider is unsupported")
  let api ← text "LODE_MODEL_API" file.api
  let api := api.getD ((provider.map (fun p => (Model.apiForModel p name).toString)).getD "anthropic")
  let base ← text "LODE_MODEL_BASE_URL" file.baseUrl
  let protocolBase := match api with
    | "responses" => "openai"
    | "pi" => "radius"
    | other => other
  let fallback := Model.defaultBase? (provider.getD protocolBase)
  let request : Model.ConfigJson :=
    { api := some api, name := some name, baseUrl := base <|> fallback
      maxTokens := ← number "LODE_MODEL_MAX_TOKENS" file.maxTokens
      contextWindow := ← number "LODE_MODEL_CONTEXT_WINDOW" file.contextWindow }
  IO.ofExcept ((Model.Config.ofConfigJson request none none allowLocal).mapError IO.userError)

private def secret (allowLocal : Bool) (settings : Option SecretsFile) (model : Option Model.Config) :
    IO (Option Secrets.ModelKey) := do
  let file := settings.getD {}
  let base ← text "LODE_SECRETS_URL" file.baseUrl
  let path ← text "LODE_SECRETS_MODEL_KEY_PATH" file.modelKeyPath
  if settings.isNone && base.isNone && path.isNone then return none
  let some base := base | throw (IO.userError "set secrets.baseUrl or LODE_SECRETS_URL")
  let some path := path | throw (IO.userError "set secrets.modelKeyPath or LODE_SECRETS_MODEL_KEY_PATH")
  let some token ← env? "LODE_SECRETS_TOKEN" | throw (IO.userError "set LODE_SECRETS_TOKEN")
  let some model := model | throw (IO.userError "configure a default model to use a Secrets model key")
  unless model.api != .scripted do throw (IO.userError "a Secrets model key requires a network model")
  return some (← IO.ofExcept ((Secrets.ModelKey.configure base path model.baseUrl token allowLocal).mapError IO.userError))

/-- Resolve the service port. TCP ports outside 1–65535 are rejected before binding. -/
def port (file : File) : IO UInt16 := do
  let port := (← number "LODE_PORT" file.port).getD 8080
  unless port > 0 && port ≤ 65535 do throw (IO.userError "LODE_PORT or settings.port must be between 1 and 65535")
  return port.toUInt16

/-- Resolve runtime settings with environment overrides. Stdio keeps its existing
    local mode and state-directory defaults. -/
def runtime (file : File) (cli : Bool := false) : IO Config := do
  let workdir ← match ← text "LODE_WORKDIR" file.workdir with
    | some path => pure path
    | none =>
      if cli then do
        let some home ← env? "HOME" | throw (IO.userError "set HOME or LODE_WORKDIR for CLI state")
        pure s!"{home}/.local/state/lode"
      else pure "/var/lib/lode"
  let allowLocal := cli || (← localMode file)
  let lun ← match ← text "LODE_LUN_URL" file.lunUrl with
    | none => pure none
    | some url => pure (some
        { url, token := ← env? "LODE_LUN_TOKEN"
          buildTimeoutMs := ← seconds "LODE_LUN_BUILD_TIMEOUT" file.lunBuildTimeout 3600000
          callTimeoutMs := ← seconds "LODE_LUN_CALL_TIMEOUT" file.lunCallTimeout 120000 : Lun.Config })
  let defaultModel ← defaultModel allowLocal (file.model.getD {})
  let modelApiKey ← env? "LODE_MODEL_API_KEY"
  unless modelApiKey.all Secrets.validKey do throw (IO.userError "LODE_MODEL_API_KEY is not a valid API key")
  let cfg : Config := { workdir := workdir }
  return { cfg with
    allowLocal, lun
    token := ← env? "LODE_TOKEN"
    liaisonUrl := ← text "LODE_LIAISON_URL" file.liaisonUrl
    defaultModel
    modelApiKey
    modelKeySecret := ← secret allowLocal file.secrets defaultModel
    maxSteps := (← number "LODE_MAX_STEPS" file.maxSteps).getD cfg.maxSteps
    modelTimeoutMs := ← seconds "LODE_MODEL_TIMEOUT" file.modelTimeout cfg.modelTimeoutMs
    gitTimeoutMs := ← seconds "LODE_GIT_TIMEOUT" file.gitTimeout cfg.gitTimeoutMs
    checkTimeoutMs := ← seconds "LODE_CHECK_TIMEOUT" file.checkTimeout cfg.checkTimeoutMs
    packageCache := (← text "LODE_PACKAGE_CACHE" file.packageCache).map System.FilePath.mk
    linenRev := (← text "LODE_LINEN_REV" file.linenRev).getD cfg.linenRev
    toolchain := (← text "LODE_TOOLCHAIN" file.toolchain).getD cfg.toolchain }

end Lode.Settings
