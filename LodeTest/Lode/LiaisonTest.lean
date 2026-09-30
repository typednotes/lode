/-
  Tests for `Lode.Liaison`: credentials are checked as liaison would check
  them (the warrant decoded by `Liaison.Wire`, the provider one a use allows,
  the account naming the warrant's resource), a warrant forwarded to lun
  round-trips, and refusals read well. The wire format itself is
  `Liaison.Wire`'s, tested in liaison.
-/
import LodeTest.Util
import Lode.Liaison

open Lean (Json toJson)
open Lode.Liaison

namespace LodeTests.Liaison

def warrant (provider action : String) : Json :=
  Json.mkObj [("id", "w1"), ("orgId", "org"), ("tag", "00ff"), ("caveats", Json.arr #[
    Json.mkObj [("kind", "runId"), ("value", "run")],
    Json.mkObj [("kind", "budget"), ("value", "0")],
    Json.mkObj [("kind", "resource"), ("value", "conn")],
    Json.mkObj [("kind", "capability"), ("provider", Json.str provider), ("action", Json.str action)],
    Json.mkObj [("kind", "expiresAt"), ("value", "1790000000")]])]

def creds (provider : String) (account := "user/conn") (cost : Option Json := none) (w := warrant provider "read") : Json :=
  Json.mkObj ([("warrant", w), ("account", Json.str account)] ++ Json.opt "cost" cost)

-- The grant is read off the warrant.
#guard ((Credentials.parse (creds "github") "c" ["github"]).toOption.map fun c =>
  (c.provider, c.grant.action.value, c.grant.resource.value, c.grant.runId.value, c.grant.orgId.value, c.account)) ==
  some ("github", "read", "conn", "run", "org", "user/conn")
-- The warrant must be for an allowed provider…
#guard (Credentials.parse (creds "gitlab") "c" ["github"]).toOption.isNone
-- …and the account's connection must be the warrant's resource.
#guard (Credentials.parse (creds "github" "user/other") "c" ["github"]).toOption.isNone
#guard (Credentials.parse (creds "github" "a/b/conn") "c" ["github"]).toOption.isNone
-- `cost` is a number of credits.
#guard (Credentials.parse (creds "anthropic" (cost := some (12 : Nat))) "c" ["anthropic"]).toOption.map (·.cost) == some 12
#guard (Credentials.parse (creds "anthropic") "c" ["anthropic"]).toOption.map (·.cost) == some 0
-- A warrant liaison would refuse as malformed is refused here: no tag, a
-- non-hex tag, an unknown caveat, a missing kind of caveat.
#guard (Credentials.parse (creds "github" (w := (warrant "github" "read").setObjVal! "tag" "zz")) "c" ["github"]).toOption.isNone
#guard (Credentials.parse (creds "github" (w := Json.mkObj [("id", "w"), ("orgId", "o"), ("caveats", Json.arr #[])])) "c" ["github"]).toOption.isNone
#guard (Credentials.parse (creds "github" (w := (warrant "github" "read").setObjVal! "caveats"
  (Json.arr #[Json.mkObj [("kind", "surprise"), ("value", "x")]]))) "c" ["github"]).toOption.isNone
#guard (Credentials.parse (creds "github" (w := (warrant "github" "read").setObjVal! "caveats"
  (Json.arr #[Json.mkObj [("kind", "resource"), ("value", "conn")]]))) "c" ["github"]).toOption.isNone
#guard (Credentials.parse (Json.mkObj [("account", "u/conn")]) "c" ["github"]).toOption.isNone

-- A warrant forwarded to lun decodes to the same warrant.
#guard ((Credentials.parse (creds "github") "c" ["github"]).toOption.bind fun c =>
  (decodeWarrantJson (warrantJson c.warrant)).toOption.map fun w =>
    (w.id.value, w.orgId.value, w.caveats.length, w.tag.toList)) ==
  some ("w1", "org", 5, [0, 255])

-- Refusals.
#guard (refusal 403 "expired").startsWith "liaison refused the call (403 expired)"
#guard ((refusal 403 "expired").splitOn "fresh credentials").length > 1
#guard ((refusal 403 "url_denied").splitOn "fresh").length == 1

def nativeEnvelope := do
  let c ← Credentials.parse (creds "anthropic" (w := warrant "anthropic" "inference.generate")) "c" ["anthropic"]
  inferenceBody c 1 "claude-test" (Json.mkObj [("model", "claude-test"), ("messages", Json.arr #[])])
    { sessionId := "stable-session", initiator := "agent" }

#guard (nativeEnvelope.toOption.bind fun j => (j.getObjVal? "call").toOption).map (fun j =>
  ((j.getObjValAs? String "kind"), (j.getObjValAs? String "operation"),
   (j.getObjValAs? (List String) "resource"), (j.getObjVal? "url").isOk, (j.getObjVal? "headers").isOk)) ==
  some (.ok "connector", .ok "inference.generate", .ok ["claude-test"], false, false)
#guard (nativeEnvelope.toOption.bind fun j => (j.getObjVal? "call" >>= (·.getObjVal? "context") >>= (·.getObjValAs? String "sessionId")).toOption) == some "stable-session"
#guard (do
  let c ← Credentials.parse (creds "anthropic") "c" ["anthropic"]
  inferenceBody c 1 "claude-test" (Json.mkObj []) {sessionId := "stable", initiator := "user"}).toOption.isNone

def operationCredentials :=
  (creds "github" (w := warrant "github" "repositories.read")).setObjVal! "operations"
    (Json.arr #[Json.mkObj [("operation", "repositories.write"), ("warrant", warrant "github" "repositories.write")]])

#guard (do
  let c ← Credentials.parse operationCredentials "c" ["github"]
  let body ← connectorBody c 1 "repositories.write" ["owner", "repo", "file"] (Json.mkObj [("contents", "hi")])
  pure body.request.action.value) == .ok "repositories.write"
#guard (do
  let c ← Credentials.parse operationCredentials "c" ["github"]
  connectorBody c 1 "issues.write" ["owner", "repo"] (Json.mkObj [])).toOption.isNone
#guard (Credentials.parse (operationCredentials.setObjVal! "operations"
  (Json.arr #[Json.mkObj [("operation", "repositories.write"), ("warrant", warrant "gitlab" "repositories.write")]]))
    "c" ["github"]).toOption.isNone

end LodeTests.Liaison
