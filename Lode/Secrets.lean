/- The direct model key in an operator-selected Typednotes Secrets KV entry. -/
import Lode.Http
import Lode.Validate
import Lean.Data.Json

namespace Lode.Secrets

open Lean (Json)
open Network.HTTP.Types (StdMethod)

/-- A vault entry and the model endpoint its key is for. Never printable. -/
structure ModelKey where
  private mk ::
  baseUrl : String
  path : String
  modelBaseUrl : String
  token : String

/-- Keys and bearer tokens are bounded, visible ASCII header values. -/
def validKey (key : String) : Bool :=
  !key.isEmpty && key.length ≤ 4096 && key.all (fun c => c.toNat > 0x20 && c.toNat < 0x7f)

/-- Validate a configured Secrets namespace. Plain HTTP is restricted to
    loopback in local mode. The path is relative to the KV data mount. -/
def ModelKey.configure (url path modelBaseUrl token : String) (allowLocal : Bool) : Except String ModelKey := do
  unless (Validate.credentialUrl url allowLocal).isSome do
    throw "secrets.baseUrl must be HTTPS, or loopback HTTP in local mode"
  unless !path.isEmpty && Validate.projectPath path do throw "secrets.modelKeyPath must contain plain relative components"
  unless validKey token do throw "LODE_SECRETS_TOKEN is not a valid bearer token"
  return ⟨url, path, modelBaseUrl, token⟩

/-- Read a Secrets KV response and check the key's endpoint binding. Errors
    can be reported to the operator without quoting the response. -/
def decodeModelKey (body modelBaseUrl : String) : Except String String := do
  let invalid := "Secrets returned an invalid model key record"
  let json ← (Json.parse body).mapError (fun _ => invalid)
  let data ← (json.getObjVal? "data").mapError (fun _ => invalid)
  let base ← (data.getObjValAs? String "modelBaseUrl").mapError (fun _ => invalid)
  unless base == modelBaseUrl do throw "Secrets model key was stored for a different model endpoint"
  let key ← (data.getObjValAs? String "apiKey").mapError (fun _ => invalid)
  unless validKey key do throw invalid
  return key

private def request (vault : ModelKey) (method : StdMethod) (body : Option String := none) :
    IO Network.HTTP.Client.Response := do
  try
    Http.request method (vault.baseUrl ++ "/v1/secret/data/" ++ vault.path)
      [("authorization", s!"Bearer {vault.token}"), ("content-type", "application/json")] body 10000
  catch _ => throw (IO.userError "could not reach the configured Secrets service")

/-- Read the current model key. Call before inference to pick up vault rotations. -/
def ModelKey.read (vault : ModelKey) : IO String := do
  let response ← request vault .GET
  unless Http.status response == 200 do throw (IO.userError s!"Secrets model key read failed (HTTP {Http.status response})")
  IO.ofExcept ((decodeModelKey (Http.text response) vault.modelBaseUrl).mapError IO.userError)

/-- Store a new KV version for the configured endpoint. -/
def ModelKey.store (vault : ModelKey) (key : String) : IO Unit := do
  unless validKey key do throw (IO.userError "LODE_MODEL_API_KEY is not a valid API key")
  let body := Json.mkObj [("modelBaseUrl", .str vault.modelBaseUrl), ("apiKey", .str key)]
  let response ← request vault .POST (some body.compress)
  unless Http.status response == 204 do throw (IO.userError s!"Secrets model key write failed (HTTP {Http.status response})")

end Lode.Secrets
