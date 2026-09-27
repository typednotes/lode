/-
  Lode.Server — lode's HTTP API

  | Route | |
  |---|---|
  | `GET /_health` | `200` (liveness; linen's `healthCheck`) |
  | `POST /v0/sessions` | create a session (`Lode.Spec`): opens the workspace; `201` with its status (and starts a run if the request has a `message`) |
  | `GET /v0/sessions` | every session's status, newest first |
  | `GET /v0/sessions/{id}` | the session's status |
  | `DELETE /v0/sessions/{id}` | delete an idle session and its workspace (`409` while it runs) |
  | `POST /v0/sessions/{id}/messages` | `{"text", "credentials"?, "agent"?}`: start a run, or steer the running one; `202` |
  | `GET /v0/sessions/{id}/messages?after=n&wait=s` | the log from entry `n` on; with `wait`, hold the request up to `s` seconds (≤ 60) until there is something new or the run ends |
  | `POST /v0/sessions/{id}/abort` | stop the running run (`202`), or `409` if none |
  | `PUT /v0/sessions/{id}/credentials` | `{"repo"?, "model"?, "lun"?}`: refresh warrants; `200` with the status |
  | `GET /v0/sessions/{id}/diff` | the unpublished changes (`text/plain`) |

  Errors are `{"error": message}`. When `LODE_TOKEN` is set every route but
  `/_health` requires `Authorization: Bearer {token}`.
-/
import Lean.Data.Json
import Linen.Network.WebApp
import Linen.Network.WebApp.Extra.Middleware.HealthCheckEndpoint
import Linen.Network.WebApp.Extra.Middleware.RequestSizeLimit
import Lode.Session

namespace Lode

open Lean (Json toJson)
open Network.HTTP.Types

/-- The largest request body accepted. -/
def maxBodyBytes : Nat := 4 * 1024 * 1024

/-- The statuses lode answers with. -/
def statusOf : Nat → Network.HTTP.Types.Status
  | 200 => status200 | 201 => status201 | 202 => status202 | 400 => status400 | 401 => status401
  | 404 => status404 | 409 => status409 | 502 => status502
  | _ => status500

private def json (code : Nat) (body : Json) : Network.WebApp.Response :=
  Network.WebApp.responseLBS (statusOf code) [(hContentType, "application/json")] body.compress

private def error (code : Nat) (msg : String) : Network.WebApp.Response :=
  json code (Json.mkObj [("error", toJson msg)])

private def text (body : String) : Network.WebApp.Response :=
  Network.WebApp.responseLBS status200 [(hContentType, "text/plain; charset=utf-8")] body

/-- Read the body as JSON. Its size is bounded by linen's `requestSizeLimit`
    (`application`): a declared length over the limit is answered `413` before
    anything is read, and a chunked body stops being read at the limit. -/
private def readJson (req : Network.WebApp.Request) : IO (Except String Json) := do
  let bytes ← try Network.WebApp.strictRequestBody req
    catch _ => return .error "the request body is too large"
  let some t := String.fromUTF8? bytes | return .error "the request body is not UTF-8"
  return (Json.parse (if t.trimAscii.isEmpty then "{}" else t)).mapError (s!"the request is not JSON: " ++ ·)

/-- Compare two strings in time independent of where they differ. -/
def constantTimeEq (a b : String) : Bool :=
  let x := a.toUTF8
  let y := b.toUTF8
  x.size == y.size &&
    (List.range x.size).foldl (fun acc i => acc ||| (x[i]! ^^^ y[i]!)) (0 : UInt8) == 0

/-- The request carries the configured token, if one is configured. -/
def authorized (cfg : Config) (req : Network.WebApp.Request) : Bool :=
  match cfg.token with
  | none => true
  | some token =>
    match (req.requestHeaders.find? (·.1 == Data.CI.mk' "Authorization")).map (·.2) with
    | some h => constantTimeEq h s!"Bearer {token}"
    | none => false

/-- A query parameter's value. -/
def queryParam (req : Network.WebApp.Request) (name : String) : Option String :=
  (req.queryString.lookup name).join

/-- `{"entries": [...], "next": n, "running": b}`: the log from `after` on. -/
def entriesJson (entries : Array Entry) (after : Nat) (running : Bool) : Json :=
  let items := ((List.range entries.size).drop after).map fun i =>
    match toJson entries[i]! with
    | .obj kvs => Json.obj (kvs.insert "index" (toJson i))
    | j => j
  Json.mkObj [("entries", Json.arr items.toArray), ("next", toJson entries.size), ("running", toJson running)]

private def create (r : Registry) (req : Network.WebApp.Request) : IO Network.WebApp.Response := do
  let j ← match ← readJson req with
    | .ok j => pure j
    | .error e => return error 400 e
  match SessionSpec.parse j r.cfg.defaultModel r.cfg.allowLocal with
  | .error e => return error 400 e
  | .ok spec =>
    let s ← try r.create spec
      catch e => return error 502 s!"opening the repository failed: {e}"
    if let some m := spec.message then let _ ← s.send m
    return json 201 (← s.status)

private def message (s : Session) (req : Network.WebApp.Request) : IO Network.WebApp.Response := do
  let j ← match ← readJson req with
    | .ok j => pure j
    | .error e => return error 400 e
  let m ← match MessageRequest.parse j with
    | .ok m => pure m
    | .error e => return error 400 e
  let repo := (← s.info.get).source.repo
  match m.credentials.mapM (·.check repo) with
  | .error e => return error 400 e
  | .ok creds => if let some c := creds then s.creds.modify (·.merge c)
  if let some a := m.agent then
    unless (Prompt.agent? a).isSome do return error 400 "message.agent: 'build' or 'plan'"
    if ← s.running then return error 409 "the agent cannot change during a run"
    s.updateMeta ({ · with agent := a })
  let queued ← s.send m.text
  return json 202 (Json.mkObj [("queued", toJson queued), ("session", ← s.status)])

private def messages (s : Session) (req : Network.WebApp.Request) : IO Network.WebApp.Response := do
  let after := ((queryParam req "after").bind String.toNat?).getD 0
  let wait := min 60 (((queryParam req "wait").bind String.toNat?).getD 0)
  let deadline := (← IO.monoMsNow) + wait * 1000
  repeat
    let n := (← s.entries.get).size
    if n > after || !(← s.running) || (← IO.monoMsNow) ≥ deadline then break
    IO.sleep 250
  return json 200 (entriesJson (← s.entries.get) after (← s.running))

/-- Route one request. -/
def route (r : Registry) (req : Network.WebApp.Request) : IO Network.WebApp.Response := do
  let m := req.requestMethod
  let is (x : StdMethod) := m == .standard x
  match req.pathInfo with
  | path =>
    unless authorized r.cfg req do return error 401 "missing or wrong bearer token"
    match path with
    | ["v0", "sessions"] =>
      if is .POST then create r req
      else if is .GET then
        let mut out : Array Json := #[]
        for id in ← r.ids do
          if let some s ← r.get? id then out := out.push (← s.status)
        return json 200 (Json.mkObj [("sessions", Json.arr out)])
      else return error 404 "not found"
    | "v0" :: "sessions" :: id :: rest =>
      let some s ← r.get? id | return error 404 "no such session"
      match rest with
      | [] =>
        if is .GET then return json 200 (← s.status)
        else if is .DELETE then
          if ← r.delete s then return json 200 (Json.mkObj [("deleted", id)])
          else return error 409 "the session is running; abort it first"
        else return error 404 "not found"
      | ["messages"] =>
        if is .POST then message s req
        else if is .GET then messages s req
        else return error 404 "not found"
      | ["abort"] =>
        unless is .POST do return error 404 "not found"
        if ← s.requestAbort then return json 202 (Json.mkObj [("aborting", toJson true)])
        else return error 409 "no run is going"
      | ["credentials"] =>
        unless is .PUT do return error 404 "not found"
        let j ← match ← readJson req with
          | .ok j => pure j
          | .error e => return error 400 e
        match CredentialSet.parse j (← s.info.get).source.repo with
        | .error e => return error 400 e
        | .ok c =>
          s.creds.modify (·.merge c)
          return json 200 (← s.status)
      | ["diff"] =>
        unless is .GET do return error 404 "not found"
        return text (← Workspace.diff s.wctx (checkoutDir s.cfg s.id) (← s.info.get).workspace)
      | _ => return error 404 "not found"
    | _ => return error 404 "not found"

/-- lode's `Application`. An unexpected exception is a `500`, never a dropped
    connection. -/
def application (r : Registry) : Network.WebApp.Application :=
  Network.WebApp.Extra.Middleware.healthCheck "/_health" <|
  Network.WebApp.Extra.Middleware.requestSizeLimit maxBodyBytes <|
  fun req respond =>
    Network.WebApp.AppM.respondIO respond do
      try route r req
      catch e => pure (error 500 (toString e))

end Lode
