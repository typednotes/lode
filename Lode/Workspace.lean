/-
  Lode.Workspace — the checkout the agent works in, and publishing it

  A session works on one branch of one repository, shared with the user (and
  with lun, which builds from it). The checkout is always a local git
  repository, so what changed is always `git diff` against `localBase`, the
  local commit whose tree is the remote's `remoteHead`.

  Three ways in and out, chosen by the repository's host and whether the
  session has credentials:

  | | open | publish |
  |---|---|---|
  | `git` (no credentials: public, or `file://` in local mode) | `git clone` of the branch | `git commit` + `git push` (works only where the remote accepts it: local mode) |
  | `github` (through liaison) | `GET /repos/{o}/{r}/branches/{b}`, then the tarball as lun fetches it | blobs → tree (on the remote head's tree) → commit (parent: the remote head) → fast-forward the branch ref (`force: false`) |
  | `gitlab` (through liaison) | `GET /projects/{p}/repository/branches/{b}`, then the archive | `POST /projects/{p}/repository/commits` with one action per changed file, after checking the branch has not moved |

  liaison relays only calls under the connection's API `base_url`, so the
  hosts' REST APIs stand in for `git`: file contents travel base64-encoded
  (liaison bodies are UTF-8 text). Either way the branch only ever
  fast-forwards: if someone else pushed in between, publishing fails rather
  than overwrite their work.
-/
import Lean.Data.Json
import Linen.Data.Base64
import Linen.Network.HTTP.Types.URI
import Lake.Load.Manifest
import Lode.Liaison
import Lode.Http
import Lode.Process
import Lode.Validate

namespace Lode.Workspace

open Lean (Json toJson)
open System (FilePath)

-- ── Configuration ───────────────────────────────────────────────────────────

/-- Where the session's code lives. -/
structure Source where
  repo : Validate.Repo
  branch : String
  /-- The project directory within the repository (`""` for its root). -/
  path : String
  deriving DecidableEq, Repr

/-- A source as `session.json` keeps it: the canonical clone URL, re-parsed
    when read back. -/
private structure SourceJson where
  url : String
  branch : String
  path : String
  deriving Lean.ToJson, Lean.FromJson

instance : Lean.ToJson Source :=
  ⟨fun s => Lean.toJson ({ url := s.repo.cloneUrl, branch := s.branch, path := s.path } : SourceJson)⟩

instance : Lean.FromJson Source where
  fromJson? j := do
    let s : SourceJson ← Lean.fromJson? j
    return { repo := ← Validate.repo s.url (allowLocal := true), branch := s.branch, path := s.path }

/-- The checkout's link to the remote. Persisted with the session. -/
structure State where
  /-- The remote branch's commit the checkout was last in sync with. -/
  remoteHead : String
  /-- The local commit whose tree is `remoteHead`'s. -/
  localBase : String
  deriving DecidableEq, Repr, Inhabited, Lean.ToJson, Lean.FromJson

/-- What the workspace needs from the server's configuration. -/
structure Context where
  liaisonUrl : Option String
  timeoutMs : Nat

/-- How the checkout is fetched and published. -/
inductive Backend where
  | git | github | gitlab
  deriving DecidableEq, Repr

/-- The backend for a repository, given whether the session has repository
    credentials. -/
def backend (repo : Validate.Repo) (hasCredentials : Bool) : Backend :=
  match repo.host, hasCredentials with
  | .github, true => .github
  | .gitlab, true => .gitlab
  | _, _ => .git

-- ── URLs ────────────────────────────────────────────────────────────────────

/-- Percent-encode everything but RFC 3986's unreserved characters (linen's
    `urlEncode`, which encodes UTF-8 bytes). -/
def percentEncode (s : String) : String := Network.HTTP.Types.urlEncode s

/-- A branch in a URL path: each component encoded, `/` kept. -/
def branchPath (branch : String) : String := "/".intercalate ((branch.splitOn "/").map percentEncode)

/-- `https://api.github.com/repos/{owner}/{repo}`. -/
def githubBase (repo : Validate.Repo) : Except String String :=
  match repo.segments with
  | [o, r] => pure s!"https://api.github.com/repos/{percentEncode o}/{percentEncode r}"
  | _ => throw "a GitHub repository is OWNER/REPO"

/-- `https://gitlab.com/api/v4/projects/{url-encoded path}`. -/
def gitlabBase (repo : Validate.Repo) : String :=
  s!"https://gitlab.com/api/v4/projects/{percentEncode ("/".intercalate repo.segments)}"

/-- A download URL GitHub may redirect a tarball to. -/
def isCodeloadUrl (url : String) : Bool := url.startsWith "https://codeload.github.com/"

-- ── Changes ─────────────────────────────────────────────────────────────────

/-- One changed path, from `git diff --raw`. -/
structure Change where
  /-- `A`dded, `M`odified, `D`eleted, `T`ype changed. -/
  status : Char
  /-- The new mode (`100644`, `100755`, `120000`; `000000` when deleted). -/
  mode : String
  /-- The new blob (in the local repository). -/
  blob : String
  path : String
  deriving DecidableEq, Repr, Inhabited

/-- Parse `git diff --raw -z --no-renames`: `:oldmode newmode old new S` NUL
    `path` NUL, repeated. -/
def parseRaw (out : String) : Array Change :=
  let entry (info path : String) : Option Change :=
    if info.startsWith ":" then
      match (info.drop 1).toString.splitOn " " with
      | [_, newMode, _, newBlob, st] =>
        st.toList.head?.map fun c => { status := c, mode := newMode, blob := newBlob, path }
      | _ => none
    else none
  let rec go : List String → List Change
    | info :: path :: more => (entry info path).toList ++ go more
    | _ => []
  (go (out.splitOn "\x00")).toArray

/-- A one-line summary of changes, for the model. -/
def summarize (cs : Array Change) : String :=
  let n (c : Char) := (cs.filter (·.status == c)).size
  s!"{cs.size} file(s): {n 'A'} added, {n 'M' + n 'T'} modified, {n 'D'} deleted"

-- ── Local git ───────────────────────────────────────────────────────────────

private def git (ctx : Context) (dir : FilePath) (args : Array String) : IO Process.Result :=
  Process.run "git" args ctx.timeoutMs (cwd := dir) (env := Process.hermeticGit)

private def git! (ctx : Context) (dir : FilePath) (args : Array String) (what : String) : IO String := do
  let r ← git ctx dir args
  unless r.ok do throw (IO.userError (r.describe what))
  return r.stdout.trimAscii.toString

/-- Keep build outputs out of every diff, whatever the project's
    `.gitignore` says. -/
private def excludeBuildOutputs (dir : FilePath) : IO Unit := do
  let file := dir / ".git" / "info" / "exclude"
  IO.FS.createDirAll (dir / ".git" / "info")
  let old ← if ← file.pathExists then IO.FS.readFile file else pure ""
  IO.FS.writeFile file (old ++ "\n# lode\n.lake/\n")

/-- Stage everything and list what changed since `localBase`. -/
def changes (ctx : Context) (dir : FilePath) (st : State) : IO (Array Change) := do
  let _ ← git! ctx dir #["add", "-A"] "git add"
  let out ← git ctx dir #["diff", "--cached", "--raw", "-z", "--no-renames", st.localBase]
  unless out.ok do throw (IO.userError (out.describe "git diff"))
  return parseRaw out.stdout

/-- Every change since `localBase` (untracked files included), as text.
    Uses a throwaway index, so it never contends with a running `publish`
    for the checkout's own. -/
def diff (ctx : Context) (dir : FilePath) (st : State) : IO String := do
  let index := dir / ".git" / s!"lode-diff-{← IO.monoNanosNow}.index"
  let env := Process.hermeticGit.push ("GIT_INDEX_FILE", some index.toString)
  let run (args : Array String) (what : String) : IO String := do
    let r ← Process.run "git" args ctx.timeoutMs (cwd := dir) (env := env)
    unless r.ok do throw (IO.userError (r.describe what))
    return r.stdout
  try
    let _ ← run #["read-tree", st.localBase] "git read-tree"
    let _ ← run #["add", "-A"] "git add"
    run #["diff", "--cached", "--no-color", st.localBase] "git diff"
  finally
    if ← index.pathExists then IO.FS.removeFile index

/-- Record the staged changes as a local commit; returns it. -/
private def commitLocally (ctx : Context) (dir : FilePath) (message : String) : IO String := do
  let _ ← git! ctx dir #["commit", "-q", "--no-verify", "--allow-empty", "-m", message] "git commit"
  git! ctx dir #["rev-parse", "HEAD"] "git rev-parse"

-- ── liaison helpers ─────────────────────────────────────────────────────────

private def via (ctx : Context) (creds : Liaison.Credentials) (method url : String)
    (body : Option Json := none) (accept : String := "application/json") :
    IO _root_.Liaison.Wire.Response := do
  let some base := ctx.liaisonUrl
    | throw (IO.userError "this repository needs liaison, but LODE_LIAISON_URL is not set")
  let headers := [("accept", accept)] ++ (if body.isSome then [("content-type", "application/json")] else [])
  Liaison.call base creds
    { method, url, account := creds.account, headers, body := body.map (·.compress) } ctx.timeoutMs

private def jsonOf (u : _root_.Liaison.Wire.Response) (what : String) : IO Json :=
  match Json.parse (Liaison.text u) with
  | .ok j => pure j
  | .error _ => throw (IO.userError s!"{what}: the host's answer is not JSON")

private def expect (u : _root_.Liaison.Wire.Response) (codes : List Nat) (what : String) : IO Unit :=
  unless codes.contains u.status.toNat do
    let t := Liaison.text u
    let snippet := if t.length > 300 then (t.take 300).toString ++ "…" else t
    throw (IO.userError s!"{what}: the host answered {u.status} {snippet}")

private def path (j : Json) (keys : List String) : Option Json :=
  keys.foldlM (fun j k => (j.getObjVal? k).toOption) j

private def strAt (j : Json) (keys : List String) (what : String) : IO String :=
  match path j keys with
  | some (.str s) => pure s
  | _ => throw (IO.userError s!"{what}: no {".".intercalate keys} in the host's answer")

private def ghAccept : String := "application/vnd.github+json"

/-- Unpack a `.tar.gz` whose members sit under one top-level directory into
    `dest`. -/
private def unpack (ctx : Context) (archive : ByteArray) (dest : FilePath) : IO Unit := do
  let file := dest.withExtension "tar.gz"
  IO.FS.writeBinFile file archive
  IO.FS.createDirAll dest
  let r ← Process.run "tar" #["-xzf", file.toString, "-C", dest.toString, "--strip-components=1"]
    ctx.timeoutMs
  IO.FS.removeFile file
  unless r.ok do throw (IO.userError (r.describe "tar"))

/-- Make an unpacked archive of `head` a local repository whose first commit
    is exactly that tree. -/
private def initFromArchive (ctx : Context) (dir : FilePath) (head : String) : IO State := do
  let _ ← git! ctx dir #["init", "-q", "-b", "lode"] "git init"
  excludeBuildOutputs dir
  -- `-f`: the archive is the remote's tree, ignored files committed there included.
  let _ ← git! ctx dir #["add", "-A", "-f"] "git add"
  let base ← commitLocally ctx dir s!"remote {head}"
  return { remoteHead := head, localBase := base }

-- ── Opening ─────────────────────────────────────────────────────────────────

/-- Clone the branch with `git`. -/
private def openGit (ctx : Context) (src : Source) (dir : FilePath) : IO State := do
  let filter := if src.repo.host == .local then #[] else #["--filter=blob:none"]
  let r ← Process.run "git" (#["clone", "--quiet", "--single-branch", "--branch", src.branch] ++ filter ++
    #["--", src.repo.cloneUrl, dir.toString]) ctx.timeoutMs (env := Process.hermeticGit)
  unless r.ok do throw (IO.userError (r.describe s!"cloning {src.repo.cloneUrl} (branch {src.branch})"))
  excludeBuildOutputs dir
  let head ← git! ctx dir #["rev-parse", "HEAD"] "git rev-parse"
  return { remoteHead := head, localBase := head }

/-- The branch head and tarball of a GitHub repository, through liaison. -/
private def openGitHub (ctx : Context) (creds : Liaison.Credentials) (src : Source) (dir : FilePath) :
    IO State := do
  let base ← IO.ofExcept (githubBase src.repo |>.mapError IO.userError)
  let b ← via ctx creds "GET" s!"{base}/branches/{branchPath src.branch}" (accept := ghAccept)
  if b.status == 404 then throw (IO.userError s!"branch {src.branch} not found (lode needs an existing branch)")
  expect b [200] "reading the branch"
  let head ← strAt (← jsonOf b "reading the branch") ["commit", "sha"] "reading the branch"
  let tar ← via ctx creds "GET" s!"{base}/tarball/{head}" (accept := ghAccept)
  let archive ← if tar.status == 200 then pure tar.body else
    match tar.status, tar.header? "location" with
    | 302, some loc =>
      unless isCodeloadUrl loc do throw (IO.userError "GitHub redirected the tarball to an unexpected host")
      let a ← Http.request .GET loc (timeoutMs := ctx.timeoutMs)
      unless Http.status a == 200 do throw (IO.userError s!"downloading the tarball: {Http.status a}")
      pure a.body
    | s, _ => throw (IO.userError s!"fetching the tarball: the host answered {s}")
  unpack ctx archive dir
  initFromArchive ctx dir head

/-- The branch head and archive of a GitLab project, through liaison. -/
private def openGitLab (ctx : Context) (creds : Liaison.Credentials) (src : Source) (dir : FilePath) :
    IO State := do
  let base := gitlabBase src.repo
  let b ← via ctx creds "GET" s!"{base}/repository/branches/{percentEncode src.branch}"
  if b.status == 404 then throw (IO.userError s!"branch {src.branch} not found (lode needs an existing branch)")
  expect b [200] "reading the branch"
  let head ← strAt (← jsonOf b "reading the branch") ["commit", "id"] "reading the branch"
  let ar ← via ctx creds "GET" s!"{base}/repository/archive.tar.gz?sha={head}" (accept := "*/*")
  expect ar [200] "fetching the archive"
  unpack ctx ar.body dir
  initFromArchive ctx dir head

/-- Fetch the branch into `dir` (which must not exist). -/
def «open» (ctx : Context) (src : Source) (creds : Option Liaison.Credentials) (dir : FilePath) :
    IO State :=
  match backend src.repo creds.isSome, creds with
  | .github, some c => openGitHub ctx c src dir
  | .gitlab, some c => openGitLab ctx c src dir
  | _, _ => openGit ctx src dir

-- ── Publishing ──────────────────────────────────────────────────────────────

private def publishGit (ctx : Context) (src : Source) (dir : FilePath) (message : String) : IO State := do
  let head ← commitLocally ctx dir message
  let r ← git ctx dir #["push", "--quiet", "origin", s!"HEAD:refs/heads/{src.branch}"]
  unless r.ok do
    let _ ← git ctx dir #["reset", "--soft", "HEAD~1"]
    throw (IO.userError (r.describe "git push (a repository without credentials is read-only)"))
  return { remoteHead := head, localBase := head }

/-- The body of GitHub's `POST /git/trees` entry for one change. -/
def githubTreeEntry (c : Change) (blobSha : Option String) : Json :=
  Json.mkObj [("path", c.path), ("mode", if c.status == 'D' then "100644" else c.mode),
              ("type", "blob"), ("sha", match blobSha with | some s => Json.str s | none => Json.null)]

private def publishGitHub (ctx : Context) (creds : Liaison.Credentials) (src : Source) (dir : FilePath)
    (st : State) (cs : Array Change) (message : String) : IO State := do
  let base ← IO.ofExcept (githubBase src.repo |>.mapError IO.userError)
  let call (method url : String) (body : Option Json) := via ctx creds method url body (accept := ghAccept)
  let c ← call "GET" s!"{base}/git/commits/{st.remoteHead}" none
  expect c [200] "reading the base commit"
  let baseTree ← strAt (← jsonOf c "reading the base commit") ["tree", "sha"] "reading the base commit"
  let mut entries : Array Json := #[]
  for ch in cs do
    if ch.status == 'D' then entries := entries.push (githubTreeEntry ch none)
    else
      let bytes ← Process.runBytes "git" #["cat-file", "blob", ch.blob] ctx.timeoutMs (cwd := dir)
        (env := Process.hermeticGit)
      let b ← call "POST" s!"{base}/git/blobs"
        (some (Json.mkObj [("content", Data.Base64.encode bytes), ("encoding", "base64")]))
      expect b [201] s!"uploading {ch.path}"
      entries := entries.push (githubTreeEntry ch (some (← strAt (← jsonOf b "blob") ["sha"] "blob")))
  let t ← call "POST" s!"{base}/git/trees"
    (some (Json.mkObj [("base_tree", baseTree), ("tree", Json.arr entries)]))
  expect t [201] "creating the tree"
  let tree ← strAt (← jsonOf t "tree") ["sha"] "tree"
  let k ← call "POST" s!"{base}/git/commits"
    (some (Json.mkObj [("message", message), ("tree", tree), ("parents", toJson #[st.remoteHead])]))
  expect k [201] "creating the commit"
  let commit ← strAt (← jsonOf k "commit") ["sha"] "commit"
  let r ← call "PATCH" s!"{base}/git/refs/heads/{branchPath src.branch}"
    (some (Json.mkObj [("sha", commit), ("force", toJson false)]))
  if r.status == 422 then
    throw (IO.userError s!"branch {src.branch} moved on GitHub since {st.remoteHead.take 12} (someone else pushed); nothing was overwritten")
  expect r [200] "updating the branch"
  return { remoteHead := commit, localBase := ← commitLocally ctx dir message }

/-- One GitLab commit action. -/
def gitlabAction (c : Change) (content : Option String) : Except String Json := do
  if c.mode == "120000" then throw s!"{c.path}: symbolic links cannot be published through GitLab's API"
  let action := match c.status with
    | 'A' => "create" | 'D' => "delete" | _ => "update"
  return Json.mkObj <|
    [("action", Json.str action), ("file_path", Json.str c.path)] ++
    Json.opt "content" content ++ Json.opt "encoding" (content.map fun _ => "base64") ++
    Json.opt "execute_filemode" (if c.status == 'D' then none else some (c.mode == "100755"))

private def publishGitLab (ctx : Context) (creds : Liaison.Credentials) (src : Source) (dir : FilePath)
    (st : State) (cs : Array Change) (message : String) : IO State := do
  let base := gitlabBase src.repo
  let b ← via ctx creds "GET" s!"{base}/repository/branches/{percentEncode src.branch}"
  expect b [200] "reading the branch"
  let head ← strAt (← jsonOf b "reading the branch") ["commit", "id"] "reading the branch"
  unless head == st.remoteHead do
    throw (IO.userError s!"branch {src.branch} moved on GitLab since {st.remoteHead.take 12} (someone else pushed); nothing was overwritten")
  let mut actions : Array Json := #[]
  for ch in cs do
    let content ← if ch.status == 'D' then pure none else
      some <$> Data.Base64.encode <$> Process.runBytes "git" #["cat-file", "blob", ch.blob] ctx.timeoutMs
        (cwd := dir) (env := Process.hermeticGit)
    actions := actions.push (← IO.ofExcept (gitlabAction ch content |>.mapError IO.userError))
  let k ← via ctx creds "POST" s!"{base}/repository/commits"
    (some (Json.mkObj [("branch", src.branch), ("commit_message", message), ("actions", Json.arr actions)]))
  expect k [200, 201] "creating the commit"
  let commit ← strAt (← jsonOf k "commit") ["id"] "commit"
  return { remoteHead := commit, localBase := ← commitLocally ctx dir message }

/-- Publish every change since `localBase` as one commit on the remote
    branch. Returns the new state and a report for the model. -/
def publish (ctx : Context) (src : Source) (creds : Option Liaison.Credentials) (dir : FilePath)
    (st : State) (message : String) : IO (State × String) := do
  let cs ← changes ctx dir st
  if cs.isEmpty then throw (IO.userError s!"nothing to publish: the workspace is the remote's {st.remoteHead}")
  let st' ← match backend src.repo creds.isSome, creds with
    | .github, some c => publishGitHub ctx c src dir st cs message
    | .gitlab, some c => publishGitLab ctx c src dir st cs message
    | _, _ => publishGit ctx src dir message
  return (st', s!"Published {st'.remoteHead} on {src.branch} ({summarize cs}).")

-- ── The package cache ───────────────────────────────────────────────────────

/-- The revision a project's `lake-manifest.json` locks linen to, read with
    Lake's own manifest parser. -/
def linenRev? (manifest : String) : Option String := do
  let m ← (Lake.Manifest.parse manifest).toOption
  let linen ← m.packages.find? (·.name == `linen)
  match linen.src with
  | .git _ rev _ _ => if Validate.commit rev then some rev else none
  | .path _ => none

/-- Seed the project's linen from the package cache (`{cache}/linen/{rev}`,
    a built linen checkout, as lun's image carries one), when the manifest
    locks a revision the cache has and the project has no linen yet: linen's
    first build is long. -/
def seedCache (cache : Option FilePath) (project : FilePath) (timeoutMs : Nat) : IO Unit := do
  let some cache := cache | return
  let manifest := project / "lake-manifest.json"
  unless ← manifest.pathExists do return
  let some rev := linenRev? (← IO.FS.readFile manifest) | return
  let cached := cache / "linen" / rev
  let dest := project / ".lake" / "packages" / "linen"
  unless (← cached.pathExists) && !(← dest.pathExists) do return
  IO.FS.createDirAll (project / ".lake" / "packages")
  let _ ← Process.run "cp" #["-R", cached.toString, dest.toString] timeoutMs

end Lode.Workspace
