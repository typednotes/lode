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

namespace Lode

open Lean (Json FromJson fromJson?)

/-- The credentials a session holds, each optional. -/
structure CredentialSet where
  /-- The repository's connection (`github`/`gitlab`): open and publish. -/
  repo : Option Liaison.Credentials := none
  /-- The model's connection. -/
  model : Option Liaison.Credentials := none
  /-- What lun reads the repository with (defaults to `repo`). -/
  lun : Option Liaison.Credentials := none

/-- Later credentials replace earlier ones, field by field (warrants expire
    within minutes: a caller refreshes them). -/
def CredentialSet.merge (old new : CredentialSet) : CredentialSet :=
  { repo := new.repo <|> old.repo, model := new.model <|> old.model, lun := new.lun <|> old.lun }

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
  deriving FromJson

/-- Fresh credentials, field by field (`PUT …/credentials`, or with a message). -/
structure CredentialsRefresh where
  repo : Option Liaison.CredentialsJson := none
  model : Option Liaison.CredentialsJson := none
  lun : Option Liaison.CredentialsJson := none
  deriving FromJson

/-- `POST …/messages`. -/
structure MessageRequest where
  text : String
  credentials : Option CredentialsRefresh := none
  agent : Option String := none
  deriving FromJson

-- ── Checking them ───────────────────────────────────────────────────────────

/-- A validated session request. -/
structure SessionSpec where
  source : Workspace.Source
  agent : String
  model : Model.Config
  creds : CredentialSet
  message : Option String

/-- The providers a repository warrant may be for. -/
def repoProviders (repo : Validate.Repo) : Except String (List String) :=
  match repo.host.provider? with
  | some p => pure [p]
  | none => throw "credentials are only usable for github.com and gitlab.com repositories"

private def repoCreds (c : Liaison.CredentialsJson) (ctx : String) (repo : Validate.Repo) :
    Except String Liaison.Credentials := do
  Liaison.Credentials.ofJson c ctx (← repoProviders repo)

/-- Check fresh credentials against the session's repository. -/
def CredentialsRefresh.check (r : CredentialsRefresh) (repo : Validate.Repo) : Except String CredentialSet := do
  return { repo := ← r.repo.mapM (repoCreds · "credentials.repo" repo)
           model := ← r.model.mapM (Liaison.Credentials.ofJson · "credentials.model" Model.providers)
           lun := ← r.lun.mapM (repoCreds · "credentials.lun" repo) }

/-- Parse a credentials refresh. -/
def CredentialSet.parse (j : Json) (repo : Validate.Repo) : Except String CredentialSet := do
  let r : CredentialsRefresh ← (fromJson? j).mapError ("credentials: " ++ ·)
  r.check repo

/-- A user message: non-empty, at most 1 MB. -/
def checkText (t : String) (ctx : String) : Except String String := do
  unless !t.trimAscii.isEmpty do throw s!"{ctx}: must not be empty"
  unless t.utf8ByteSize ≤ 1024 * 1024 do throw s!"{ctx}: at most 1 MB"
  return t

/-- Parse a message request. -/
def MessageRequest.parse (j : Json) : Except String MessageRequest := do
  let m : MessageRequest ← (fromJson? j).mapError ("message: " ++ ·)
  let _ ← checkText m.text "message.text"
  return m

/-- Parse a session request. `defaultModel` is the server's model, if it has
    one; `allowLocal` admits `file://` repositories and the `scripted` model. -/
def SessionSpec.parse (j : Json) (defaultModel : Option Model.Config) (allowLocal : Bool) :
    Except String SessionSpec := do
  let r : SessionRequest ← (fromJson? j).mapError ("request: " ++ ·)
  let repo ← Validate.repo r.source.url allowLocal |>.mapError ("source.url: " ++ ·)
  unless Validate.branch r.source.branch do throw "source.branch: not a valid branch name"
  let path := r.source.path.getD ""
  unless Validate.projectPath path do throw "source.path: must be relative, of plain components"
  let sourceCreds ← r.source.credentials.mapM (repoCreds · "source.credentials" repo)
  let mj := r.model.getD {}
  let modelCreds ← mj.credentials.mapM (Liaison.Credentials.ofJson · "model.credentials" Model.providers)
  let provider := modelCreds.map (·.provider)
  let model ← Model.Config.ofConfigJson mj.toConfigJson provider defaultModel allowLocal
  if let some p := provider then
    unless model.api == Model.apiOfProvider p do
      throw s!"model.api: a '{p}' connection speaks {(Model.apiOfProvider p).toString}"
  let lunCreds ← (r.lun.bind (·.credentials)).mapM (repoCreds · "lun.credentials" repo)
  let agent := r.agent.getD "build"
  unless (Prompt.agent? agent).isSome do throw "agent: 'build' or 'plan'"
  let message ← r.message.mapM (checkText · "message")
  return { source := { repo, branch := r.source.branch, path }, agent, model
           creds := { repo := sourceCreds, model := modelCreds, lun := lunCreds }, message }

end Lode
