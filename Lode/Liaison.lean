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
   requests are built with `Body.connector` and replies read with
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
  /-- Independent named-operation warrants; none widens the primary warrant. -/
  operations : List (String × Warrant) := []

/-- The provider the warrant is for. -/
def Credentials.provider (c : Credentials) : String := c.grant.provider.value

/-- Credentials as a request carries them. -/
structure OperationCredentialJson where
  operation : String
  warrant : Json
  deriving FromJson

structure CredentialsJson where
  warrant : Json
  account : String
  cost : Option Nat := none
  operations : Option (List OperationCredentialJson) := none
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
  let mut operations := []
  for entry in c.operations.getD [] do
    let token ← decodeWarrantJson entry.warrant
    let bound ← Request.ofWarrant token 0 (c.cost.getD 0)
    unless bound.provider == grant.provider && bound.orgId == grant.orgId &&
        bound.resource == grant.resource && bound.action.value == entry.operation do
      throw s!"{ctx}.operations: operation warrant identity mismatch"
    unless !operations.any (fun pair => pair.1 == entry.operation) do
      throw s!"{ctx}.operations: duplicate operation warrant"
    operations := operations ++ [(entry.operation, token)]
  return { warrant, account := c.account, grant, cost := c.cost.getD 0, operations }

/-- Parse credentials from a request's JSON. -/
def Credentials.parse (j : Json) (ctx : String) (providers : List String) :
    Except String Credentials := do
  Credentials.ofJson (← (fromJson? j).mapError (s!"{ctx}: " ++ ·)) ctx providers

-- ── Calling ─────────────────────────────────────────────────────────────────

/-- The current Unix time in seconds for SDK caveat checks. The broker verifies
    expiry independently against its own clock. -/
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
def connectorBody (c : Credentials) (now : UInt64) (operation : String) (resource : List String)
    (payload : Json) : Except String Body := do
  let token ← if c.grant.action.value == operation then pure c.warrant else
    match c.operations.find? (fun pair => pair.1 == operation) with
    | some (_, token) => pure token
    | none => throw s!"no warrant for native operation {operation}"
  Body.connector token now c.cost { account := c.account, operation, resource, payload := payload.compress }

def call (base : String) (c : Credentials) (operation : String) (resource : List String)
    (payload : Json) (timeoutMs : Nat) : IO Response := do
  let body ← IO.ofExcept <| (connectorBody c (← nowSeconds).toUInt64 operation resource payload).mapError IO.userError
  let target := (if base.endsWith "/" then (base.dropEnd 1).toString else base) ++ "/v0/egress"
  let a ← Http.request .POST target [("content-type", "application/json")] (some body.encode) timeoutMs
  match ← IO.ofExcept ((decodeReply (Http.status a) (Http.text a)).mapError IO.userError) with
  | .relayed r => return r
  | .refused st code => throw (IO.userError (refusal st code))

/-- Structured conversation metadata, never caller-selected auth headers. The
    broker derives gateway headers from these fields using its own adapter. -/
structure NativeContext where
  sessionId : String
  initiator : String
  client : String := "typednotes-lode"
  deriving Lean.ToJson

/-- The production model envelope is URL-free. Its action is checked by the
    SDK against the warrant; the broker owns native routing and credentials. -/
def inferenceBody (c : Credentials) (now : UInt64) (model : String) (payload : Json)
    (context : NativeContext) : Except String Json := do
  let native : _root_.Liaison.Wire.NativeContext :=
    { sessionId := context.sessionId, initiator := context.initiator, client := context.client }
  unless native.valid do throw "inference context: invalid session, initiator or client identity"
  let body ← Body.connector c.warrant now c.cost
    { account := c.account, operation := "inference.generate", resource := model.splitOn "/", payload := payload.compress,
      context := some native }
  body.toValue.toLeanJson

def inference (base : String) (c : Credentials) (model : String) (payload : Json)
    (context : NativeContext) (timeoutMs : Nat) : IO Response := do
  let body ← IO.ofExcept ((inferenceBody c (← nowSeconds).toUInt64 model payload context).mapError IO.userError)
  let target := (if base.endsWith "/" then (base.dropEnd 1).toString else base) ++ "/v0/egress"
  let a ← Http.request .POST target [("content-type", "application/json")] (some body.compress) timeoutMs
  match ← IO.ofExcept ((decodeReply (Http.status a) (Http.text a)).mapError IO.userError) with
  | .relayed r => return r
  | .refused st code => throw (IO.userError (refusal st code))

end Lode.Liaison
