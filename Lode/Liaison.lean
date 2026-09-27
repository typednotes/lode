/-
  Lode.Liaison — calling through liaison, with liaison's own wire module

  lode holds no third-party credential. Whatever it reaches on a user's
  behalf — the shared repository (a `github` or `gitlab` connection) and,
  usually, the model (an `anthropic`, `mistral`, `openai` or
  `openai-compatible` connection) — it reaches through liaison, with what the
  typednotes app hands out for a connection: a **warrant** minted for it
  (`typednotes/typednotes`'s `docs/connections.md` §7) and the connection's
  **account** (`{user_id}/{connection_id}`).

  The wire format is not lode's: it is `Liaison.Wire`, the module liaison's
  own server parses with (as lun uses it). A warrant is decoded with
  `decodeWarrant` when credentials arrive, so one liaison would refuse as
  malformed is refused then; the fields next to it are derived from its
  caveats (`Request.ofWarrant`, proven unable to disagree with the warrant);
  requests are built with `Body.provider` and replies read with
  `decodeReply`. JSON crosses between Lean core's `Lean.Json` (lode's) and
  linen's `Data.Json.Value` (liaison's) through linen's `Data.Json.Bridge`.

  Credentials are never persisted and never logged (no `ToJson`/`Repr`).
-/
import Lean.Data.Json
import Liaison.Wire
import Linen.Data.Json.Bridge
import Linen.Data.Time.Clock
import Lode.Http

namespace Lode.Liaison

open Lean (Json FromJson fromJson?)
open _root_.Liaison (Warrant Credits)
open _root_.Liaison.Wire

-- ── Credentials ─────────────────────────────────────────────────────────────

/-- A warrant for one connection, and the connection's account. -/
structure Credentials where
  warrant : Warrant
  account : String
  /-- What the warrant is for (provider, action, resource, run, org). -/
  grant : _root_.Liaison.Request
  /-- The credits each call holds (`0` for repository calls, whose warrants
      carry `budget(0)`). -/
  cost : Credits := 0

/-- The provider the warrant is for. -/
def Credentials.provider (c : Credentials) : String := c.grant.provider.value

/-- Credentials as a request carries them. -/
structure CredentialsJson where
  warrant : Json
  account : String
  cost : Option Nat := none
  deriving FromJson

/-- A warrant, from Lean core's JSON, decoded as liaison decodes it. -/
def decodeWarrantJson (j : Json) : Except String Warrant := do
  decodeWarrant (← Data.Json.Value.ofLeanJson j)

/-- A warrant as Lean core's JSON, as liaison reads it (to forward to lun). -/
def warrantJson (w : Warrant) : Json := Lean.toJson (encodeWarrant w)

/-- Check credentials: the warrant decodes, is for one of `providers`, and the
    account names its resource. -/
def Credentials.ofJson (c : CredentialsJson) (ctx : String) (providers : List String) :
    Except String Credentials := do
  let warrant ← decodeWarrantJson c.warrant |>.mapError (s!"{ctx}." ++ ·)
  let grant ← Request.ofWarrant warrant 0 0 |>.mapError (s!"{ctx}." ++ ·)
  unless providers.contains grant.provider.value do
    throw s!"{ctx}: the warrant is for '{grant.provider.value}', expected one of {providers}"
  unless accountMatchesResource c.account grant.resource.value do
    throw s!"{ctx}.account: must be {"{user_id}/{connection_id}"}, the connection being the warrant's resource"
  return { warrant, account := c.account, grant, cost := c.cost.getD 0 }

/-- Parse credentials from a request's JSON. -/
def Credentials.parse (j : Json) (ctx : String) (providers : List String) :
    Except String Credentials := do
  Credentials.ofJson (← (fromJson? j).mapError (s!"{ctx}: " ++ ·)) ctx providers

-- ── Calling ─────────────────────────────────────────────────────────────────

/-- The current Unix time in seconds (liaison checks warrant expiry against
    the caller's clock). -/
def nowSeconds : IO Nat := do
  return (← Data.Time.getCurrentTime).nanosSinceEpoch / 1000000000

/-- The text of a relayed body (empty if it is not UTF-8). -/
def text (r : Response) : String := (String.fromUTF8? r.body).getD ""

/-- Why liaison refused, as the model or the caller should read it. -/
def refusal (httpStatus : Nat) (code : String) : String :=
  let hint := if code == "expired" then " — the warrant expired; send fresh credentials" else ""
  s!"liaison refused the call ({httpStatus} {code}){hint}"

/-- Make `call` through liaison at `base` (e.g. `http://liaison:8080`), under
    `c`'s warrant. A refusal is an exception whose message starts with
    `liaison refused`. -/
def call (base : String) (c : Credentials) (x : ProviderCall) (timeoutMs : Nat) : IO Response := do
  let body ← IO.ofExcept <| (Body.provider c.warrant (← nowSeconds).toUInt64 c.cost x).mapError IO.userError
  let target := (if base.endsWith "/" then (base.dropEnd 1).toString else base) ++ "/v0/egress"
  let a ← Http.request .POST target [("content-type", "application/json")] (some body.encode) timeoutMs
  match ← IO.ofExcept ((decodeReply (Http.status a) (Http.text a)).mapError IO.userError) with
  | .relayed r => return r
  | .refused st code => throw (IO.userError (refusal st code))

end Lode.Liaison
