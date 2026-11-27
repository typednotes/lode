/- Browser authorization and refresh for an operator-configured model issuer. -/
import Lode.Model
import Lode.Secrets
import Linen.Data.Hex
import Linen.Network.OAuth2.AuthorizationRequest
import Linen.Network.OAuth2.Experiment.Pkce
import Linen.Network.OAuth2.TokenRequest

namespace Lode.OAuth

open Network.OAuth2.Internal (OAuth2 PostBody)
open Network.OAuth2
open Network.OAuth2.Experiment.Pkce (mkPkceParam)

/-- The server route that receives the browser's authorization response. -/
def callbackPath := "/v0/model-oauth/callback"

/-- A single issuer bound to the operator's direct model. No serialization. -/
structure Config where
  private mk ::
  service : OAuth2
  scope : Option String

/-- Direct protocols whose credential is sent as an Authorization bearer. -/
def supports (api : Model.Api) : Bool := api == .openai || api == .responses

/-- Validate an issuer and its registered callback. An absent secret selects
    a public OAuth client. -/
def Config.check (authorize token redirect clientId : String) (clientSecret scope : Option String)
    (allowLocal : Bool) : Except String Config := do
  let parse (field value : String) : Except String Network.URI.URI :=
    match Validate.credentialUrl value allowLocal with
    | some uri => .ok uri
    | none => .error s!"modelOAuth.{field} must be HTTPS or loopback HTTP in local mode"
  let authorization ← parse "authorizationUrl" authorize
  let exchange ← parse "tokenUrl" token
  let callback ← parse "redirectUri" redirect
  unless callback.uriPath == callbackPath do throw s!"modelOAuth.redirectUri must end at {callbackPath}"
  unless Secrets.validKey clientId do throw "modelOAuth.clientId must be a visible ASCII identifier"
  unless clientSecret.all Secrets.validKey do throw "LODE_OAUTH_CLIENT_SECRET is invalid"
  unless scope.all (fun text => text.utf8ByteSize ≤ 4096 && text.all (fun c => c.toNat ≥ 32 && c.toNat < 127)) do
    throw "modelOAuth.scope must be a space-separated scope string"
  let service : OAuth2 :=
    { oauth2ClientId := clientId
      oauth2ClientSecret := clientSecret.getD ""
      oauth2AuthorizeEndpoint := authorization
      oauth2TokenEndpoint := exchange
      oauth2RedirectUri := callback }
  return ⟨service, scope⟩

/-- A pending, single-use browser exchange. The PKCE verifier stays in memory. -/
structure Pending where
  private mk ::
  sessionId : String
  state : String
  verifier : String
  expiresAt : Nat

/-- Start a five-minute authorization using fresh state and a PKCE S256 challenge. -/
def Config.start (cfg : Config) (sessionId : String) : IO (Pending × String) := do
  let state := Data.Hex.encode (← Crypto.SecureRandom.randomBytes 32)
  let pkce ← mkPkceParam
  let params := [("state", state), ("code_challenge", pkce.codeChallenge.unCodeChallenge),
    ("code_challenge_method", "S256")] ++ (cfg.scope.map (fun s => [("scope", s)])).getD []
  let url := AuthorizationRequest.authorizationUrlWithParams params cfg.service
  return (⟨sessionId, state, pkce.codeVerifier.unCodeVerifier, (← IO.monoMsNow) + 300000⟩,
    Network.URI.uriToString Network.URI.defaultUserInfoMap url)

/-- A current bearer and optional rotating refresh token. Never printable. -/
structure Grant where
  private mk ::
  access : String
  refresh : Option String
  expiresAt : Option Nat
  refreshAt : Option Nat

/-- Browser authorization state owned by one session. -/
structure SessionState where
  attempt : Option String := none
  grant : Option Grant := none

private def request (cfg : Config) (fields : PostBody) (previous : Option String) : IO Grant := do
  let fields := fields ++ if cfg.service.oauth2ClientSecret.isEmpty then [("client_id", cfg.service.oauth2ClientId)]
    else TokenRequest.clientSecretPost cfg.service
  let body := "&".intercalate (fields.map fun (key, value) =>
    s!"{Network.HTTP.Types.urlEncode key}={Network.HTTP.Types.urlEncode value}")
  let url := Network.URI.uriToString Network.URI.defaultUserInfoMap cfg.service.oauth2TokenEndpoint
  let response ← try Http.request .POST url [("content-type", "application/x-www-form-urlencoded"),
    ("accept", "application/json")] (some body) 10000
    catch _ => throw (IO.userError "could not reach the configured OAuth token endpoint")
  unless Http.status response == 200 do
    throw (IO.userError s!"OAuth token endpoint returned HTTP {Http.status response}")
  let invalid := IO.userError "OAuth token endpoint returned an invalid bearer response"
  unless response.body.size ≤ 65536 do throw invalid
  let token ← IO.ofExcept ((Data.Json.Decode.decodeAs (α := TokenRequest.TokenResponse) (Http.text response)).mapError (fun _ => invalid))
  let refresh := (token.refreshToken.map (·.rtoken)) <|> previous
  unless token.tokenType.any (·.toLower == "bearer") && Secrets.validKey token.accessToken.atoken &&
      refresh.all Secrets.validKey && token.expiresIn.all (· > 0) do throw invalid
  let now ← IO.monoMsNow
  let ttl := token.expiresIn.map (fun seconds => seconds.toNat * 1000)
  return ⟨token.accessToken.atoken, refresh, ttl.map (now + ·),
    ttl.map (fun span => now + span - min 30000 (span / 10))⟩

/-- Exchange the consumed authorization code with the original verifier. -/
def Config.exchange (cfg : Config) (pending : Pending) (code : String) : IO Grant := do
  unless Secrets.validKey code do throw (IO.userError "invalid OAuth authorization code")
  let (_, fields) := TokenRequest.accessTokenUrl cfg.service ⟨code⟩
  request cfg (fields ++ [("code_verifier", pending.verifier)]) none

/-- Return the current bearer, refreshing near expiry when the issuer supplied
    a refresh token. Callers serialize this operation with session updates. -/
def Config.current (cfg : Config) (grant : Grant) : IO Grant := do
  let now ← IO.monoMsNow
  if let some refresh := grant.refresh then
    if grant.refreshAt.any (· ≤ now) then
      let (_, fields) := TokenRequest.refreshAccessTokenUrl cfg.service ⟨refresh⟩
      return ← request cfg fields (some refresh)
  if grant.expiresAt.any (· ≤ now) then
    throw (IO.userError "OAuth model access expired. Start a new browser authorization.")
  return grant

end Lode.OAuth
