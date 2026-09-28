/-
  Lode.Validate — the syntax of everything a request (or the model) names

  Every string that reaches a git command line, a file path, a URL sent to
  liaison or an id is checked here against a deliberately narrow grammar, so
  that downstream code can treat it as data of that shape and nothing else.
  The repository and branch grammars are lun's (`lun/Lun/Validate.lean`):
  lode writes the repositories lun reads, so both must agree on what a
  repository URL and a branch are. All checks are pure and total.
-/
import Linen.System.GitFn.Descriptor

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

-- ── Git ─────────────────────────────────────────────────────────────────────

/-- A branch name, per `git check-ref-format --branch` (as lun checks it). -/
def branch (s : String) : Bool :=
  let forbidden (c : Char) := c.toNat < 0x20 || c.toNat == 0x7f || " ~^:?*[\\".contains c
  !s.isEmpty && s.length ≤ 255 && s != "@" && !s.any forbidden &&
    (s.splitOn "..").length == 1 &&
    (s.splitOn "@{").length == 1 && (s.splitOn "//").length == 1 &&
    !s.startsWith "-" && !s.startsWith "/" && !s.endsWith "/" && !s.endsWith "." &&
    (s.splitOn "/").all fun comp => !comp.isEmpty && !comp.startsWith "." && !comp.endsWith ".lock"

-- ── Paths ───────────────────────────────────────────────────────────────────

/-- One path component of a repository location: `[A-Za-z0-9._-]+`, not `.`
    or `..`. -/
def pathComponent (s : String) : Bool :=
  !s.isEmpty && s != "." && s != ".." &&
    s.all fun c => c.isAlphanum || c == '.' || c == '_' || c == '-'

/-- A project directory inside the repository: empty (the root) or relative
    components separated by `/`. -/
def projectPath (s : String) : Bool :=
  s.isEmpty || (s.length ≤ 512 && (s.splitOn "/").all pathComponent)

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

-- ── Repository URLs ─────────────────────────────────────────────────────────

/-- Where a repository is hosted, which decides how it is fetched and
    published. -/
inductive Host where
  /-- `github.com`: through liaison's `github` connection. -/
  | github
  /-- `gitlab.com`: through liaison's `gitlab` connection. -/
  | gitlab
  /-- Any other `https` host: `git`, public repositories only. -/
  | other (host : String)
  /-- A local repository (`file://`), accepted only in local mode (tests). -/
  | local
  deriving DecidableEq, Repr

/-- A parsed repository URL. -/
structure Repo where
  host : Host
  /-- The path segments on the host (`owner/repo`, `group/…/project`), or the
      absolute path of a local repository. -/
  segments : List String
  /-- The canonical URL to clone (and to hand to lun). -/
  cloneUrl : String
  deriving DecidableEq, Repr

/-- The provider name liaison knows the host's connections by. -/
def Host.provider? : Host → Option String
  | .github => some "github"
  | .gitlab => some "gitlab"
  | _ => none

/-- Parse a repository URL, the way it is written for `git clone`
    (lun's grammar): `https://github.com/owner/repo(.git)`,
    `https://gitlab.com/group/…/project(.git)`, another `https` host, or
    `file:///abs/path` when `allowLocal`. -/
def repo (url : String) (allowLocal : Bool := false) : Except String Repo := do
  if url.length > 1024 then throw "the repository URL is too long"
  let strip (s : String) : String :=
    let s := if s.endsWith "/" then (s.dropEnd 1).toString else s
    if s.endsWith ".git" then (s.dropEnd 4).toString else s
  if url.startsWith "file://" then
    unless allowLocal do throw "file:// repositories are only accepted in local mode"
    let path := (url.drop 7).toString
    let segs := (path.splitOn "/").drop 1
    unless path.startsWith "/" && segs.all pathComponent do
      throw "a file:// URL must name an absolute path of plain components"
    return { host := .local, segments := segs, cloneUrl := url }
  unless url.startsWith "https://" do throw "the repository URL must be https://"
  let rest := strip (url.drop 8).toString
  match rest.splitOn "/" with
  | [] | [_] => throw "the repository URL names no repository"
  | hostName :: segs =>
    unless !hostName.isEmpty && hostName.all (fun c => c.isAlphanum || c == '.' || c == '-') do
      throw "the repository host must be a plain DNS name (no userinfo or port)"
    unless segs.all pathComponent do
      throw "the repository path must be plain components (no query, fragment or dot segments)"
    let host : Host := match hostName.toLower with
      | "github.com" => .github
      | "gitlab.com" => .gitlab
      | h => .other h
    if host == .github && segs.length != 2 then
      throw "a GitHub repository URL is https://github.com/OWNER/REPO"
    let cloneUrl := s!"https://{hostName.toLower}/{"/".intercalate segs}.git"
    return { host, segments := segs, cloneUrl }

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
