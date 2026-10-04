/-
  Lode.Spec — a session request, parsed and validated

  ```jsonc
  {
    "source": {
      "url": "https://github.com/owner/repo",   // as for `git clone`
      "branch": "main",                          // an existing branch; lode commits on it
      "path": "lean",                            // optional: the project directory
      "credentials": {                           // optional: a `github`/`gitlab` connection
        "warrant": { … }, "account": "{user_id}/{connection_id}" }
    },
    "model": {                                   // optional if the server has a default model
      "api": "anthropic",                        // or "openai"; implied by the credentials' provider
      "name": "claude-sonnet-4-5",
      "baseUrl": "https://api.anthropic.com/v1", // implied for anthropic, mistral, openai
      "maxTokens": 8192, "contextWindow": 200000,
      "credentials": {                           // an `anthropic`/`mistral`/`openai`/`openai-compatible` connection
        "warrant": { … }, "account": "…", "cost": 10 }
    },
    "lun": { "credentials": { … } },             // optional: the warrant lun reads the repository with
                                                 // (default: the repository's)
    "agent": "build",                            // or "plan"
    "message": "Write a function that …"             // optional: starts a run at once
  }
  ```

  Parsing is the only place a request is interpreted: everything downstream
  receives values whose every string has passed `Lode.Validate`.
  Credentials are held in memory only (`CredentialSet`), never persisted.
-/
import Lean.Data.Json
import Lode.Validate
import Lode.Liaison
import Lode.Model
import Lode.Workspace
import Lode.Prompt
import Lode.RuntimeContext
import Lode.Lun

namespace Lode

open Lean (Json ToJson FromJson fromJson?)

/-- The credentials a session holds, each optional. -/
structure CredentialSet where
  /-- The repository's connection (`github`/`gitlab`): open and publish. -/
  repo : Option Liaison.Credentials := none
  /-- The model's connection. -/
  model : Option Liaison.Credentials := none
  /-- What lun reads the repository with (defaults to `repo`). -/
  lun : Option Liaison.Credentials := none
  /-- Trusted runtime grants, memory-only; public ceilings are stored separately. -/
  execution : Option Runtime.Context := none

/-- Later credentials replace earlier ones, field by field (warrants expire
    within minutes: a caller refreshes them). -/
def CredentialSet.merge (old new : CredentialSet) : CredentialSet :=
  { repo := new.repo <|> old.repo, model := new.model <|> old.model, lun := new.lun <|> old.lun,
    execution := new.execution <|> old.execution }

-- ── Requests, as JSON ───────────────────────────────────────────────────────

/-! The shapes of requests, decoded by derived `FromJson` (whose errors name
    the field); every string is then checked by `Lode.Validate`. -/

/-- `source`. -/
structure SourceJson where
  url : String
  branch : String
  path : Option String := none
  credentials : Option Liaison.CredentialsJson := none
  deriving FromJson

/-- `model`: a configuration, and the model connection's credentials. -/
structure ModelJson extends Model.ConfigJson where
  credentials : Option Liaison.CredentialsJson := none
  deriving FromJson

/-- `lun`. -/
structure LunJson where
  credentials : Option Liaison.CredentialsJson := none
  deriving FromJson

/-- `POST /v0/sessions`. -/
structure SessionRequest where
  source : SourceJson
  model : Option ModelJson := none
  lun : Option LunJson := none
  agent : Option String := none
  message : Option String := none
  tools : Option Tools.Policy := none
  execution : Option Json := none
  buildContracts : Option Json := none
  background : Option Bool := none
  requestKey : Option String := none
  deriving FromJson

/-- Fresh credentials, field by field (`PUT …/credentials`, or with a message). -/
structure CredentialsRefresh where
  repo : Option Liaison.CredentialsJson := none
  model : Option Liaison.CredentialsJson := none
  lun : Option Liaison.CredentialsJson := none
  execution : Option Json := none
  deriving FromJson

/-- `POST …/messages`. -/
structure MessageRequest where
  text : String
  credentials : Option CredentialsRefresh := none
  agent : Option String := none
  tools : Option Tools.Policy := none
  execution : Option Json := none
  /-- Apply a checked narrowing without enqueueing a paid model turn. -/
  controlOnly : Option Bool := none
  messageKey : Option String := none
  deriving FromJson

-- ── Checking them ───────────────────────────────────────────────────────────

/-- A validated session request. -/
structure SessionSpec where
  source : Workspace.Source
  agent : String
  model : Model.Config
  creds : CredentialSet
  message : Option String
  tools : Tools.Policy := Tools.Policy.all
  execution : Option Runtime.Context := none
  buildContracts : Lun.BuildContracts := {}
  background : Bool := false
  requestKey : Option String := none

/-- A bounded caller retry key; it is identity, never execution authority. -/
def checkRetryKey (value : String) : Except String String := do
  unless !value.isEmpty && value.utf8ByteSize ≤ 128 && value.all (fun c => c.isAlphanum || c == '-' || c == '_') do
    throw "retry key must contain 1–128 identifier bytes"
  return value

/-- The providers a repository warrant may be for. -/
def repoProviders (repo : System.Git.Repository) : Except String (List String) :=
  match repo.host.provider? with
  | some p => pure [p]
  | none => throw "credentials are only usable for github.com and gitlab.com repositories"

private def repoCreds (c : Liaison.CredentialsJson) (ctx : String) (repo : System.Git.Repository) :
    Except String Liaison.Credentials := do
  Liaison.Credentials.ofJson c ctx (← repoProviders repo)

/-- Check fresh credentials against the session's repository. -/
def CredentialsRefresh.check (r : CredentialsRefresh) (repo : System.Git.Repository) : Except String CredentialSet := do
  return { repo := ← r.repo.mapM (repoCreds · "credentials.repo" repo)
           model := ← r.model.mapM (Liaison.Credentials.ofJson · "credentials.model" Model.providers)
           lun := ← r.lun.mapM (repoCreds · "credentials.lun" repo)
           execution := ← r.execution.mapM Runtime.Context.parse }

/-- Parse a credentials refresh. -/
def CredentialSet.parse (j : Json) (repo : System.Git.Repository) : Except String CredentialSet := do
  if (j.getObjVal? "buildContracts").isOk then throw "build contracts are immutable; start a new session"
  if (j.getObjVal? "tools").isOk then throw "credentials: tool policy updates belong on messages"
  let r : CredentialsRefresh ← (fromJson? j).mapError ("credentials: " ++ ·)
  r.check repo

/-- A user message: non-empty, at most 1 MB. -/
def checkText (t : String) (ctx : String) : Except String String := do
  unless !t.trimAscii.isEmpty do throw s!"{ctx}: must not be empty"
  unless t.utf8ByteSize ≤ 1024 * 1024 do throw s!"{ctx}: at most 1 MB"
  return t

/-- Parse a message request. -/
def MessageRequest.parse (j : Json) : Except String MessageRequest := do
  if (j.getObjVal? "buildContracts").isOk then throw "build contracts are immutable; start a new session"
  let m : MessageRequest ← (fromJson? j).mapError ("message: " ++ ·)
  if m.controlOnly == some true && m.tools.isNone && m.execution.isNone then throw "controlOnly requires a policy narrowing"
  if let .ok tools := j.getObjVal? "tools" then let _ ← Tools.Policy.parse tools
  if let .ok credentials := j.getObjVal? "credentials" then
    if (credentials.getObjVal? "tools").isOk then throw "credentials: tool policy updates belong on messages"
    if (credentials.getObjVal? "execution").isOk then throw "message execution belongs at the top level"
  let _ ← m.execution.mapM Runtime.Context.parse
  let _ ← checkText m.text "message.text"
  let _ ← m.messageKey.mapM checkRetryKey
  return m

/-- Parse a session request. `defaultModel` is the server's model, if it has
    one; `allowLocal` admits `file://` repositories and the `scripted` model. -/
def SessionSpec.parse (j : Json) (defaultModel : Option Model.Config) (allowLocal : Bool) :
    Except String SessionSpec := do
  let r : SessionRequest ← (fromJson? j).mapError ("request: " ++ ·)
  if let .ok tools := j.getObjVal? "tools" then let _ ← Tools.Policy.parse tools
  let repo ← System.Git.Repository.parse r.source.url allowLocal |>.mapError ("source.url: " ++ ·)
  unless System.Git.isBranchName r.source.branch do throw "source.branch: not a valid branch name"
  let path := r.source.path.getD ""
  unless Validate.projectPath path do throw "source.path: must be relative, of plain components"
  let sourceCreds ← r.source.credentials.mapM (repoCreds · "source.credentials" repo)
  let mj := r.model.getD {}
  let modelCreds ← mj.credentials.mapM (Liaison.Credentials.ofJson · "model.credentials" Model.providers)
  let provider := modelCreds.map (·.provider)
  let model ← Model.Config.ofConfigJson mj.toConfigJson provider defaultModel allowLocal
  if let some p := provider then
    unless Model.supportsApi p model.api do
      throw s!"model.api: '{p}' does not support {model.api.toString}"
    Model.checkProtocol p model
    unless (modelCreds.map (·.grant.action.value)) == some "inference.generate" do
      throw "model.credentials: the warrant must grant inference.generate"
  let lunCreds ← (r.lun.bind (·.credentials)).mapM (repoCreds · "lun.credentials" repo)
  let orgs := [sourceCreds, modelCreds, lunCreds].filterMap id |>.map (·.grant.orgId.value)
  if let some org := orgs.head? then
    unless orgs.all (· == org) do throw "credentials: every connection must belong to the session's organization"
  let agent := r.agent.getD "build"
  unless (Prompt.agent? agent).isSome do throw "agent: 'build' or 'plan'"
  let message ← r.message.mapM (checkText · "message")
  let execution ← r.execution.mapM Runtime.Context.parse
  let buildContracts ← r.buildContracts.mapM Lun.BuildContracts.parse
  let requestKey ← r.requestKey.mapM checkRetryKey
  if let some execution := execution then
    let org ← (← execution.execution.getObjVal? "binding").getObjValAs? String "org_id"
    unless orgs.all (· == org) do throw "execution and writer credentials belong to different organizations"
  return {
    source := { repo, branch := r.source.branch, path }, agent, model
    creds := { repo := sourceCreds, model := modelCreds, lun := lunCreds }, message
    tools := r.tools.getD Tools.Policy.all, execution, buildContracts := buildContracts.getD {}
    background := r.background.getD false, requestKey }

/-- Persisted connection identity, without warrant tags or credential material. -/
structure CredentialBinding where
  provider : String
  account : String
  orgId : String
  deriving DecidableEq, ToJson, FromJson

def CredentialBinding.ofCredentials (c : Liaison.Credentials) : CredentialBinding :=
  { provider := c.provider, account := c.account, orgId := c.grant.orgId.value }

structure CredentialBindings where
  repo : Option CredentialBinding := none
  model : Option CredentialBinding := none
  lun : Option CredentialBinding := none
  deriving ToJson, FromJson

def CredentialBindings.ofCredentials (c : CredentialSet) : CredentialBindings :=
  { repo := c.repo.map CredentialBinding.ofCredentials,
    model := c.model.map CredentialBinding.ofCredentials,
    lun := c.lun.map CredentialBinding.ofCredentials }

/-- Refreshes replace expiry/budget/run caveats, never organization, connection
    or native protocol. The broker authenticates each warrant independently. -/
def CredentialBindings.check (bindings : CredentialBindings) (model : Model.Config)
    (fresh : CredentialSet) : Except String CredentialBindings := do
  let check (ctx : String) (old : Option CredentialBinding) (new : Option Liaison.Credentials) := do
    let next := new.map CredentialBinding.ofCredentials
    if let some previous := old then
      if let some incoming := next then
        unless incoming == previous do throw s!"{ctx}: refresh cannot change provider, account or organization"
    return next <|> old
  if let some c := fresh.model then
    Model.checkProtocol c.provider model
    unless c.grant.action.value == "inference.generate" do
      throw "credentials.model: the warrant must grant inference.generate"
  let next : CredentialBindings := {
    repo := ← check "credentials.repo" bindings.repo fresh.repo
    model := ← check "credentials.model" bindings.model fresh.model
    lun := ← check "credentials.lun" bindings.lun fresh.lun }
  let all := [next.repo, next.model, next.lun].filterMap id
  if let some first := all.head? then
    unless all.all (·.orgId == first.orgId) do throw "credentials: every connection must belong to the session's organization"
  return next

end Lode
