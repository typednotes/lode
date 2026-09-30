/-
  Tests for `Lode.Spec`: session requests — what is implied, what is
  refused (credentials for the wrong provider or host, a model connection
  speaking another API, local-only features outside local mode).
-/
import LodeTest.Util
import Lode.Spec

open Lean (Json)
open Lode

namespace LodeTests.Spec

def warrant (provider : String) : Json :=
  Json.mkObj [("id", "w"), ("orgId", "org"), ("tag", "00"), ("caveats", Json.arr #[
    Json.mkObj [("kind", "runId"), ("value", "run")],
    Json.mkObj [("kind", "resource"), ("value", "conn")],
    Json.mkObj [("kind", "capability"), ("provider", Json.str provider),
      ("action", if provider == "github" || provider == "gitlab" then "write" else "inference.generate")]])]
def creds (provider : String) : Json := Json.mkObj [("warrant", warrant provider), ("account", "user/conn")]

def request (url : String) (model : Json) (extra : List (String × Json) := []) : Json :=
  Json.mkObj ([("source", Json.mkObj [("url", Json.str url), ("branch", "main"), ("path", "lean"),
    ("credentials", creds "github")]), ("model", model)] ++ extra)

def claude : Json := Json.mkObj [("name", "claude"), ("credentials", creds "anthropic")]

#guard match SessionSpec.parse (request "https://github.com/o/r" claude) none false with
  | .ok s => s.agent == "build" && s.model.api == .anthropic && s.creds.repo.isSome && s.creds.model.isSome
      && s.source.path == "lean" && s.message.isNone
  | .error _ => false
-- Repository credentials must match the host.
#guard (SessionSpec.parse (request "https://gitlab.com/o/r" claude) none false).toOption.isNone
#guard (SessionSpec.parse (request "https://example.org/o/r" claude) none false).toOption.isNone
-- The model connection decides the API.
#guard (SessionSpec.parse (request "https://github.com/o/r"
  (Json.mkObj [("api", "openai"), ("name", "c"), ("credentials", creds "anthropic")])) none false).toOption.isNone
#guard (SessionSpec.parse (request "https://github.com/o/r"
  (Json.mkObj [("name", "c"), ("credentials", creds "github")])) none false).toOption.isNone
-- Agent and message.
#guard (SessionSpec.parse (request "https://github.com/o/r" claude [("agent", "yolo")]) none false).toOption.isNone
#guard (SessionSpec.parse (request "https://github.com/o/r" claude [("message", "go")]) none false).toOption.bind
  (·.message) == some "go"
#guard (SessionSpec.parse (request "https://github.com/o/r" claude [("message", "  ")]) none false).toOption.isNone
-- Local mode only: file:// and the scripted model.
#guard (SessionSpec.parse (Json.mkObj [("source", Json.mkObj [("url", "file:///tmp/r"), ("branch", "main")]),
  ("model", Json.mkObj [("api", "scripted")])]) none false).toOption.isNone
#guard (SessionSpec.parse (Json.mkObj [("source", Json.mkObj [("url", "file:///tmp/r"), ("branch", "main")]),
  ("model", Json.mkObj [("api", "scripted")])]) none true).toOption.isSome

-- Credentials refresh, field by field.
#guard match CredentialSet.parse (Json.mkObj [("model", creds "mistral")])
    { host := .github, segments := ["o", "r"], cloneUrl := "" } with
  | .ok c => c.model.isSome && c.repo.isNone
  | .error _ => false
#guard (CredentialSet.parse (Json.mkObj [("repo", creds "gitlab")])
    { host := .github, segments := ["o", "r"], cloneUrl := "" }).toOption.isNone
-- Messages.
#guard ((MessageRequest.parse (Json.mkObj [("text", "hi")])).toOption.map (·.text)) == some "hi"
#guard (MessageRequest.parse (Json.mkObj [("text", "")])).toOption.isNone
#guard (MessageRequest.parse (Json.mkObj [("text", (3 : Nat))])).toOption.isNone
#guard ((MessageRequest.parse (Json.mkObj [("text", "hi"), ("agent", "plan"),
  ("credentials", Json.mkObj [("model", creds "openai")])])).toOption.map fun m =>
    (m.agent, m.credentials.bind (·.model) |>.isSome)) == some (some "plan", true)
-- A request that is not the right shape names the field.
#guard match SessionSpec.parse (Json.mkObj [("source", Json.mkObj [("url", (1 : Nat))])]) none true with
  | .error e => (e.splitOn "url").length > 1
  | .ok _ => false

def parsedCreds (provider : String) (org := "org") (account := "user/conn") : Option Liaison.Credentials :=
  (Liaison.Credentials.parse ((creds provider).setObjVal! "warrant" ((warrant provider).setObjVal! "orgId" (Json.str org))
    |>.setObjVal! "account" (Json.str account)) "test" Model.providers).toOption
def modelConfig : Model.Config := { api := .anthropic, name := "claude", baseUrl := "https://api.anthropic.com/v1" }
def bindings := CredentialBindings.ofCredentials { model := parsedCreds "anthropic" }
#guard (bindings.check modelConfig { model := parsedCreds "anthropic" }).toOption.isSome
#guard (bindings.check modelConfig { model := parsedCreds "anthropic" "other-org" }).toOption.isNone
#guard (bindings.check modelConfig { model := parsedCreds "anthropic" "org" "other-user/conn" }).toOption.isNone
#guard (bindings.check modelConfig { model := parsedCreds "mistral" }).toOption.isNone
#guard (SessionSpec.parse (request "https://github.com/o/r"
  (claude.setObjVal! "credentials" ((creds "anthropic").setObjVal! "warrant" ((warrant "anthropic").setObjVal! "orgId" "other")))) none false).toOption.isNone

end LodeTests.Spec
