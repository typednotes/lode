/- Lode.ToolPolicy — the writer's finite operation ceiling, independent of
   credentials, agent selection and model output. -/
import Lean.Data.Json

namespace Lode.Tools

/-- Unknown writer operations cannot enter a validated policy. -/
inductive Operation where
  | read | ls | grep | write | edit | bash | todo | check | publish | lunBuild | lunCall
  deriving DecidableEq, Repr

def Operation.name : Operation → String
  | .read => "read" | .ls => "ls" | .grep => "grep" | .write => "write"
  | .edit => "edit" | .bash => "bash" | .todo => "todo" | .check => "check"
  | .publish => "publish" | .lunBuild => "lun_build" | .lunCall => "lun_call"

def Operation.all : List Operation :=
  [.read, .ls, .grep, .write, .edit, .bash, .todo, .check, .publish, .lunBuild, .lunCall]

def Operation.parse (name : String) : Except String Operation :=
  match Operation.all.find? (·.name == name) with
  | some op => .ok op
  | none => .error s!"tools: unknown operation '{name}'"

/-- A launch allowlist is the immutable ceiling. Omitted means the normal
    writer preset; an explicit empty array denies every tool. -/
structure Policy where
  allowed : List Operation
  deriving DecidableEq, Repr

def Policy.all : Policy := ⟨Operation.all⟩
def Policy.names (p : Policy) : List String := p.allowed.map Operation.name
def Policy.permits (p : Policy) (op : Operation) : Prop := op ∈ p.allowed
instance (p : Policy) (op : Operation) : Decidable (p.permits op) := inferInstanceAs (Decidable (op ∈ p.allowed))

def Policy.parse (j : Lean.Json) : Except String Policy := do
  let names : List String ← Lean.fromJson? j
  unless names.length ≤ Operation.all.length do throw "tools: too many operations"
  let allowed ← names.mapM Operation.parse
  unless allowed.eraseDups.length == allowed.length do throw "tools: duplicate operations"
  return ⟨allowed⟩

instance : Lean.ToJson Policy := ⟨fun p => Lean.toJson p.names⟩
instance : Lean.FromJson Policy := ⟨Policy.parse⟩

/-- Inclusion is the only permitted session-policy transition. -/
def Policy.Narrows (child parent : Policy) : Prop :=
  ∀ op, child.permits op → parent.permits op

theorem Policy.Narrows.refl (p : Policy) : p.Narrows p := fun _ h => h
theorem Policy.Narrows.trans {a b c : Policy} (ab : a.Narrows b) (bc : b.Narrows c) :
    a.Narrows c := fun op h => bc op (ab op h)

/-- The live policy carries its proof that it stays inside the launch ceiling. -/
structure BoundedPolicy (ceiling : Policy) where
  policy : Policy
  bounded : policy.Narrows ceiling

def BoundedPolicy.initial (ceiling : Policy) : BoundedPolicy ceiling :=
  ⟨ceiling, Policy.Narrows.refl ceiling⟩

def BoundedPolicy.narrow (old : BoundedPolicy ceiling) (next : Policy) :
    Except String (BoundedPolicy ceiling) :=
  if h : ∀ op ∈ next.allowed, op ∈ old.policy.allowed then
    .ok ⟨next, Policy.Narrows.trans (fun op hp => h op hp) old.bounded⟩
  else .error "tools: a session update may only narrow its current allowlist"

theorem BoundedPolicy.authority_bounded (p : BoundedPolicy ceiling) (op : Operation)
    (h : p.policy.permits op) : ceiling.permits op := p.bounded op h

end Lode.Tools
