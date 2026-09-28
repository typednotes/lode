/-
  Lode.Validate — the syntax of everything a request (or the model) names

  Every string that reaches a git command line, a file path, a URL sent to
  liaison or an id is checked here against a deliberately narrow grammar, so
  that downstream code can treat it as data of that shape and nothing else.
  The repository-URL and branch grammars are linen's (`System.Git.Remote`,
  `Repository.parse` and `isBranchName`), which lun uses too: lode writes the
  repositories lun reads, so both must agree on what a repository URL and a
  branch are. All checks are pure and total.
-/
import Linen.System.GitFn.Descriptor
import Linen.System.Git.Remote

namespace Lode.Validate

-- ── Ids ─────────────────────────────────────────────────────────────────────

/-- `[0-9a-f]`. -/
def isLowerHex (c : Char) : Bool := c.isDigit || ('a' ≤ c && c ≤ 'f')

/-- A session id: 32 lowercase hex digits (16 random bytes). -/
def sessionId (s : String) : Bool := s.length == 32 && s.all isLowerHex

/-- A lun build id: 64 lowercase hex digits. -/
def buildId (s : String) : Bool := s.length == 64 && s.all isLowerHex

/-- A commit id: a full SHA-1 (40) or SHA-256 (64) object name in lowercase
    hex (linen's `CommitSha`). -/
def commit (s : String) : Bool := System.GitFn.CommitSha.isValid s

-- ── Names ───────────────────────────────────────────────────────────────────

/-- One identifier component: `[A-Za-z_][A-Za-z0-9_]*`. -/
def identComponent (s : String) : Bool :=
  match s.toList with
  | c :: cs => (c.isAlpha || c == '_') && cs.all fun c => c.isAlphanum || c == '_'
  | [] => false

/-- A lun function or graph name: dotted identifiers, e.g. `math.double`
    (lun's `Validate.functionName`). -/
def functionName (s : String) : Bool := s.length ≤ 128 && (s.splitOn ".").all identComponent

-- ── Paths ───────────────────────────────────────────────────────────────────

/-- A project directory inside the repository: empty (the root) or relative
    components separated by `/`, each a plain segment (`[A-Za-z0-9._-]+`, not
    `.` or `..`: `System.Git.Repository.isSegment`). -/
def projectPath (s : String) : Bool :=
  s.isEmpty || (s.length ≤ 512 && (s.splitOn "/").all System.Git.Repository.isSegment)

/-- Resolve a path the model gives a file tool into components relative to
    the checkout.

    `base` is the project directory's components (where relative paths
    start); `root` is the checkout's absolute path, so an absolute path under
    it is accepted too. `.` is dropped, `..` pops, and a path that would leave
    the checkout is refused. No NUL, no control characters. -/
def resolve (root : String) (base : List String) (p : String) : Except String (List String) := do
  if p.isEmpty then throw "the path is empty"
  if p.length > 4096 then throw "the path is too long"
  if p.any (fun (c : Char) => c.toNat < 0x20) then throw "the path contains control characters"
  let (start, rest) :=
    if p == root then ([], "")
    else if p.startsWith (root ++ "/") then ([], (p.drop (root.length + 1)).toString)
    else (base, p)
  if rest.startsWith "/" then
    throw s!"'{p}' is outside the workspace (use a path relative to the project directory)"
  let step (acc : List String) (c : String) : Except String (List String) :=
    if c.isEmpty || c == "." then pure acc
    else if c == ".." then
      match acc with
      | [] => throw s!"'{p}' leaves the workspace"
      | _ => pure acc.dropLast
    else pure (acc ++ [c])
  (rest.splitOn "/").foldlM step start

/-- A resolved path the model may write to: nothing under `.git` (the local
    repository lode diffs against) or `.lake` (build outputs and packages). -/
def writable (comps : List String) : Bool :=
  !comps.isEmpty && !comps.contains ".git" && !comps.contains ".lake"

-- ── Model endpoints ─────────────────────────────────────────────────────────

/-- A model API base URL: `https://…` (or `http://` in local mode), no
    userinfo, query or fragment, no trailing `/`. -/
def baseUrl (s : String) (allowLocal : Bool := false) : Bool :=
  let rest? :=
    if s.startsWith "https://" then some (s.drop 8).toString
    else if allowLocal && s.startsWith "http://" then some (s.drop 7).toString
    else none
  match rest? with
  | none => false
  | some rest =>
    s.length ≤ 1024 && !rest.isEmpty && !s.endsWith "/" &&
      !rest.any (fun (c : Char) => c == '@' || c == '?' || c == '#' || c == ' ' || c.toNat < 0x21) &&
      !(rest.splitOn "/").any (fun seg => seg == "." || seg == "..")

end Lode.Validate
