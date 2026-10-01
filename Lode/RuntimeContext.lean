/-
  Caller-owned bounded Eff execution for writer trials. No model argument can
  construct this context. The authenticated app supplies it; Lun owns private
  runtime configuration, and its interpreters/broker consume operation witnesses.
-/
import Lun.Session
import Lode.Liaison
import Lode.Validate
import Linen.Crypto.ConstantTime

namespace Lode.Runtime

open Lean (Json toJson)
open Control.Monad.Effect.Connector

-- ── Authenticated ingress ───────────────────────────────────────────────────

/-- A configured service bearer, checked against the actual HTTP header. The
    private constructor prevents parsed execution data from forging ingress. -/
structure Caller (configured : Option String) where
  private mk ::
  header : String
  accepted : (configured.map (fun token => !token.isEmpty && Crypto.ConstantTime.eqString header s!"Bearer {token}")).getD false = true

def Caller.check? (configured : Option String) (header : String) : Option (Caller configured) :=
  if h : (configured.map (fun token => !token.isEmpty && Crypto.ConstantTime.eqString header s!"Bearer {token}")).getD false = true then
    some ⟨header, h⟩ else none

theorem Caller.configured_some {configured : Option String} (caller : Caller configured) : configured.isSome = true := by
  cases configured with
  | none => have h := caller.accepted; simp at h
  | some _ => rfl

/-- Memory-only ingress evidence. Neither this nor the context has a JSON/Repr
    instance. It is re-bound to the session's actual configuration at dispatch. -/
structure AuthenticatedCaller where
  private mk ::
  configured : Option String
  witness : Caller configured

def AuthenticatedCaller.check? (configured : Option String) (header : String) : Option AuthenticatedCaller := do
  return ⟨configured, ← Caller.check? configured header⟩

def AuthenticatedCaller.bind? (caller : AuthenticatedCaller) (configured : Option String) : Option (Caller configured) :=
  if h : caller.configured = configured then some (h ▸ caller.witness) else none

-- ── Public ceilings and private grants ──────────────────────────────────────

/-- The only persisted execution metadata. Warrants and service configuration
    are absent from Lun's public projection. Names bind grants to caller cells. -/
structure Bounds where
  execution : Json
  functions : List String
  graphs : List String
  deriving Lean.ToJson, Lean.FromJson, BEq

/-- Validated caller context. Constructors are private; no JSON encoder exposes
    operation tokens to metadata/status/model prompts. -/
structure Context where
  private mk ::
  execution : Json
  bounds : Bounds
  projected : bounds.execution = _root_.Lun.publicExecution execution
  authentication : Option AuthenticatedCaller := none

/-- Only authenticated HTTP ingress attaches this evidence; model tool parsing
    creates input values, never an AuthenticatedCaller. -/
def Context.authenticate (context : Context) (caller : AuthenticatedCaller) : Context :=
  { context with authentication := some caller }

private def onlyKeys (j : Json) (allowed : List String) : Except String Unit := do
  let fields ← j.getObj?
  unless fields.toList.all (fun (key, _) => allowed.contains key) do
    throw "execution: unknown/protected field"

private def plain (s : String) : Bool :=
  !s.isEmpty && s.length ≤ 128 && s.all (fun c => c.isAlphanum || c == '-' || c == '_')

private def names (j : Json) (field : String) : Except String (List String) := do
  let values ← j.getObjValAs? (List String) field
  unless values.length ≤ 256 && values.all Validate.functionName && values.eraseDups.length == values.length do
    throw s!"execution.{field}: invalid or duplicate service name"
  return values

/-- Decode the app envelope, retaining only recognized fields. Runtime secrets,
    transport URLs, inputs and model-selected policy are never accepted here. -/
def Context.parse (j : Json) : Except String Context := do
  onlyKeys j ["policy", "binding", "connectors", "functions", "graphs"]
  let policy ← j.getObjVal? "policy"
  onlyKeys policy ["effects", "domains"]
  let effects ← policy.getObjValAs? (List String) "effects"
  unless effects.all (["Trace", "Error", "HTTP", "FileSystem", "Connector", "PostgreSQL", "SecretStore", "ObjectStore"].contains) &&
      effects.eraseDups.length == effects.length do throw "execution: unknown/duplicate effect"
  let _ ← policy.getObjValAs? (List String) "domains"
  let binding ← j.getObjVal? "binding"
  onlyKeys binding ["org_id", "user_id", "graph_id", "schema"]
  let org ← binding.getObjValAs? String "org_id"
  let user ← binding.getObjValAs? String "user_id"
  let graph ← binding.getObjValAs? String "graph_id"
  unless plain org && plain user && plain graph do throw "execution: invalid actor/graph binding"
  let functions ← names j "functions"
  let graphs ← names j "graphs"
  let connectors ← j.getObjVal? "connectors"
  for (_, values) in (← connectors.getObj?).toList do
    for grant in ← values.getArr? do
      onlyKeys grant ["provider", "connection", "account", "bucket", "organization", "connectionPermissions", "cell", "warrantPermissions", "warrants"]
      if let .ok bucket := grant.getObjVal? "bucket" then
        unless bucket == Json.null do
          let bucket ← bucket.getStr?
          unless Resource.valid [bucket] do throw "execution: invalid logical bucket"
      for token in ← grant.getObjValAs? (Array Json) "warrants" do
        onlyKeys token ["operation", "warrant", "cost"]
        let operation ← token.getObjValAs? String "operation"
        unless validOperation operation do throw "execution: invalid operation warrant name"
        let _ ← token.getObjValAs? Nat "cost"
        let _ ← Liaison.decodeWarrantJson (← token.getObjVal? "warrant")
  let execution := Json.mkObj [("policy", policy), ("binding", binding), ("connectors", connectors)]
  let grants ← _root_.Lun.sessionGrants execution
  for (name, grant) in grants do
    unless functions.contains name do throw "execution: grant is not bound to a caller function"
    for cap in [grant.organization, grant.connectionPermissions, grant.cell, grant.warrantPermissions] do
      unless cap.provider == grant.provider && cap.connection == grant.connection do
        throw "execution: ceiling identity mismatch"
    unless _root_.Liaison.Wire.accountMatchesResource grant.account grant.connection do
      throw "execution: invalid credential-owner account"
    if grant.provider == "postgres" || grant.provider == "vault" then
      unless grant.account == s!"{user}/{grant.connection}" do throw "execution: local service must belong to the actor"
      if grant.provider == "vault" then
        unless grant.connection == graph do throw "execution: vault belongs to another graph"
  let bounds := { execution := _root_.Lun.publicExecution execution, functions, graphs }
  return ⟨execution, bounds, rfl, none⟩

/-- A validated transition bounded by both the immutable launch and the current
    public ceilings. Direct launch checking does not assume JSON transitivity. -/
structure Bounded (launch : Bounds) where
  private mk ::
  context : Context
  launchRefresh : _root_.Lun.ExecutionRefresh launch.execution
  sameExecution : launchRefresh.execution = context.bounds.execution
  functionsBound : context.bounds.functions.all launch.functions.contains = true
  graphsBound : context.bounds.graphs.all launch.graphs.contains = true
  bindingBound : ((context.bounds.execution.getObjVal? "binding").toOption ==
    (launch.execution.getObjVal? "binding").toOption) = true
  previous : Bounds
  previousRefresh : _root_.Lun.ExecutionRefresh previous.execution
  previousExecution : previousRefresh.execution = context.bounds.execution
  previousFunctions : context.bounds.functions.all previous.functions.contains = true
  previousGraphs : context.bounds.graphs.all previous.graphs.contains = true

def Bounded.check (launch : Bounds) (context : Context) : Except String (Bounded launch) := do
  if attenuated : _root_.Lun.executionNarrows context.bounds.execution launch.execution = true then
    if fs : context.bounds.functions.all launch.functions.contains = true then
      if gs : context.bounds.graphs.all launch.graphs.contains = true then
        if binding : ((context.bounds.execution.getObjVal? "binding").toOption == (launch.execution.getObjVal? "binding").toOption) = true then
          return ⟨context, ⟨context.bounds.execution, attenuated⟩, rfl, fs, gs, binding,
            launch, ⟨context.bounds.execution, attenuated⟩, rfl, fs, gs⟩
        else throw "execution refresh changes actor/graph binding"
      else throw "execution refresh adds graphs"
    else throw "execution refresh adds functions"
  else throw "execution refresh widens policy or connector ceilings"

/-- The theorem concerns the exact envelope sent to Lun, not a parallel policy. -/
theorem Bounded.attenuated {launch : Bounds} (b : Bounded launch) :
    _root_.Lun.executionNarrows b.context.bounds.execution launch.execution = true := by
  rw [← b.sameExecution]
  exact b.launchRefresh.attenuated

theorem Bounded.binding_immutable {launch : Bounds} (b : Bounded launch) :
    ((b.context.bounds.execution.getObjVal? "binding").toOption == (launch.execution.getObjVal? "binding").toOption) = true :=
  b.bindingBound

theorem Bounded.current_attenuated {launch : Bounds} (b : Bounded launch) :
    _root_.Lun.executionNarrows b.context.bounds.execution b.previous.execution = true := by
  rw [← b.previousExecution]
  exact b.previousRefresh.attenuated

/-- Credentials-only refresh must preserve all public ceilings exactly. Policy
    narrowing belongs on messages; both paths validate before mutation. -/
def refresh (launch current : Bounds) (context : Context) (credentialsOnly : Bool) : Except String (Bounded launch) := do
  if credentialsOnly && context.bounds != current then throw "credentials: execution policy changes belong on messages"
  let next ← Bounded.check launch context
  if previous : _root_.Lun.executionNarrows next.context.bounds.execution current.execution = true then
    if functions : next.context.bounds.functions.all current.functions.contains = true then
      if graphs : next.context.bounds.graphs.all current.graphs.contains = true then
        return ⟨next.context, next.launchRefresh, next.sameExecution, next.functionsBound, next.graphsBound,
          next.bindingBound, current, ⟨next.context.bounds.execution, previous⟩, rfl, functions, graphs⟩
      else throw "execution refresh adds graphs"
    else throw "execution refresh adds functions"
  else throw "execution refresh widens current policy or connector ceilings"

-- ── Actual call witness ────────────────────────────────────────────────────

/-- Input keys are fixed independently of the execution envelope. This check
    also protects the callback if an internal caller bypasses Tools parsing. -/
def inputBody (kind : String) (body : Json) : Except String Json := do
  unless kind == "function" || kind == "graph" do throw "invalid Lun call kind"
  onlyKeys body (if kind == "graph" then ["inputs"] else ["input", "inputs"])
  unless !((body.getObjVal? "input").isOk && (body.getObjVal? "inputs").isOk) do throw "choose input or inputs"
  return body

/-- The HTTP client consumes this private witness, never arbitrary model JSON. -/
def callPermitted (authorization : Option (Σ launch : Bounds, Bounded launch)) (kind name : String) : Bool :=
  match authorization with
  | none => true
  | some b => (if kind == "function" then b.2.context.bounds.functions else b.2.context.bounds.graphs).contains name

/-- Caveat-validity evidence for the actual dispatch instant. Authenticity is
    independently checked by the real broker; Lode never holds its HMAC key. -/
structure FreshOperation (context : Context) (now : UInt64) where
  private mk ::
  warrant : _root_.Liaison.Warrant
  request : _root_.Liaison.Request
  current : request.now = now
  permitted : warrant.permits request
  expiryPresent : warrant.caveats.any (fun c => match c with | .expiresAt _ => true | _ => false) = true
  budgetPresent : warrant.caveats.any (fun c => match c with | .budget _ => true | _ => false) = true
  organizationBound : request.orgId.value =
    (((context.execution.getObjVal? "binding") >>= (·.getObjValAs? String "org_id")).toOption.getD "")

structure Call where
  private mk ::
  kind : String
  name : String
  body : Json
  input : Json
  authority : Json
  authorization : Option (Σ launch : Bounds, Bounded launch)
  permitted : callPermitted authorization kind name = true
  authorityBound : authority = (authorization.map fun b => b.2.context.execution).getD (Json.mkObj [])
  now : UInt64
  fresh : match authorization with | none => Unit | some b => List (FreshOperation b.2.context now)
  configured : Option String
  caller : match authorization with | none => Unit | some _ => Caller configured
  correspondence : body = authority.mergeObj input

def Call.inputOnly (kind name : String) (body : Json) : Except String Call := do
  unless Validate.functionName name do throw "invalid Lun service name"
  let input ← inputBody kind body
  let authority := Json.mkObj []
  return ⟨kind, name, authority.mergeObj input, input, authority, none, rfl, rfl, 0, (), none, (), rfl⟩

/-- Fresh per-operation caveats are checked at dispatch. HMAC authenticity and
    live revocation are checked by the broker (or Lun's trusted local vault). -/
private def checkWarrants (context : Context) (now : UInt64) : Except String (List (FreshOperation context now)) := do
  let functions ← (← context.execution.getObjVal? "connectors").getObj?
  let org := (((context.execution.getObjVal? "binding") >>= (·.getObjValAs? String "org_id")).toOption.getD "")
  let mut fresh := []
  for (_, values) in functions.toList do
    for grant in ← values.getArr? do
      let provider ← grant.getObjValAs? String "provider"
      let connection ← grant.getObjValAs? String "connection"
      let tokens ← grant.getObjValAs? (Array Json) "warrants"
      let mut operations : List String := []
      for token in tokens do
        let operation ← token.getObjValAs? String "operation"
        unless !operations.contains operation do throw "execution: duplicate operation warrant"
        operations := operation :: operations
        let warrant ← Liaison.decodeWarrantJson (← token.getObjVal? "warrant")
        let request ← _root_.Liaison.Wire.Request.ofWarrant warrant now (← token.getObjValAs? Nat "cost")
        unless request.orgId.value == org && request.provider.value == provider &&
            request.resource.value == connection && request.action.value == operation do
          throw "execution: operation warrant binding mismatch"
        if organization : request.orgId.value = org then
          if expiry : warrant.caveats.any (fun c => match c with | .expiresAt _ => true | _ => false) = true then
            if budget : warrant.caveats.any (fun c => match c with | .budget _ => true | _ => false) = true then
              if permitted : warrant.permits request then
                if current : request.now = now then
                  fresh := fresh ++ [⟨warrant, request, current, permitted, expiry, budget, organization⟩]
                else throw "execution: operation warrant dispatch time mismatch"
              else throw "execution: operation warrant expired or caveats refused dispatch"
            else throw "execution: operation warrant has no budget ceiling"
          else throw "execution: operation warrant has no expiry ceiling"
        else throw "execution: operation warrant organization mismatch"
  return fresh

def Bounded.call {launch : Bounds} (bounded : Bounded launch) (kind name : String) (body : Json)
    (now : UInt64) (configured : Option String := none) : Except String Call := do
  let input ← inputBody kind body
  let allowed := if kind == "function" then bounded.context.bounds.functions else bounded.context.bounds.graphs
  if permitted : allowed.contains name = true then
    let some caller := bounded.context.authentication.bind (·.bind? configured)
      | throw "execution: authenticated caller evidence is missing or belongs to another service configuration"
    let fresh ← checkWarrants bounded.context now
    let authority := bounded.context.execution
    return ⟨kind, name, authority.mergeObj input, input, authority, some ⟨launch, bounded⟩, permitted, rfl, now, fresh, configured, caller, rfl⟩
  else throw "execution: service is not declared by the caller"

/-- The envelope at HTTP dispatch is the validated context whose public ceiling
    is bounded, not a model body or a separately reconstructed grant. -/
theorem Call.authority_correspondence (call : Call) {launch : Bounds} {bounded : Bounded launch}
    (h : call.authorization = some ⟨launch, bounded⟩) : call.authority = bounded.context.execution := by
  simpa [h] using call.authorityBound

theorem Call.dispatch_attenuated (call : Call) {launch : Bounds} {bounded : Bounded launch}
    (h : call.authorization = some ⟨launch, bounded⟩) :
    _root_.Lun.executionNarrows (_root_.Lun.publicExecution call.authority) launch.execution = true := by
  rw [call.authority_correspondence h, ← bounded.context.projected]
  exact bounded.attenuated

theorem Call.dispatch_current_attenuated (call : Call) {launch : Bounds} {bounded : Bounded launch}
    (h : call.authorization = some ⟨launch, bounded⟩) :
    _root_.Lun.executionNarrows (_root_.Lun.publicExecution call.authority) bounded.previous.execution = true := by
  rw [call.authority_correspondence h, ← bounded.context.projected]
  exact bounded.current_attenuated

/-- An authority-bearing outbound call cannot originate from unconfigured
    standalone ingress: the actual client consumes its authenticated witness. -/
theorem Call.authenticated (call : Call) (h : call.authorization.isSome = true) : call.configured.isSome = true := by
  cases same : call.authorization with
  | none => simp [same] at h
  | some _ =>
    have caller : Caller call.configured := by simpa [same] using call.caller
    exact caller.configured_some

/-- Four-ceiling correspondence uses Linen's actual execution authority. It
    deliberately distinguishes the actor binding from an external owner account. -/
def grantAuthority (grant : _root_.Lun.SessionGrant) : Authority :=
  { organization := grant.organization, connection := grant.connectionPermissions,
    cell := grant.cell, warrant := grant.warrantPermissions }

theorem four_ceiling_correspondence {grant : _root_.Lun.SessionGrant} {op : String}
    (target : AuthorizedResource (grantAuthority grant) op) :
    grant.organization.permits op target.resource = true ∧
    grant.connectionPermissions.permits op target.resource = true ∧
    grant.cell.permits op target.resource = true ∧
    grant.warrantPermissions.permits op target.resource = true :=
  ⟨target.organization_permits, target.connection_permits, target.cell_permits, target.warrant_permits⟩

/-- Each independent ceiling of an accepted transition attenuates semantically,
    including resource membership and byte limits, using Lun/Linen's proofs. -/
theorem grant_attenuation {child parent : _root_.Lun.SessionGrant} (h : child.narrows parent = true) :
    child.organization.Narrows parent.organization ∧
    child.connectionPermissions.Narrows parent.connectionPermissions ∧
    child.cell.Narrows parent.cell ∧ child.warrantPermissions.Narrows parent.warrantPermissions :=
  ⟨_root_.Lun.SessionGrant.narrows_organization h, _root_.Lun.SessionGrant.narrows_connection h,
    _root_.Lun.SessionGrant.narrows_cell h, _root_.Lun.SessionGrant.narrows_warrant h⟩

end Lode.Runtime
