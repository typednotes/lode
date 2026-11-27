/- Export an idle session's immutable Git revision. -/
import Lode.Session
import Lode.CellPackage

namespace Lode.Output

open Lean (Json ToJson toJson)
open System (FilePath)

/-- The four supported deliverables. Cell is the default. -/
inductive Format where
  | cell | executable | git | sourcePackage
  deriving DecidableEq, Repr

/-- The public spelling of an output format. -/
def Format.name : Format → String
  | .cell => "cell"
  | .executable => "executable"
  | .git => "git"
  | .sourcePackage => "source-package"

/-- Parse a format selected by the caller. -/
def Format.parse : String → Except String Format
  | "cell" => .ok .cell
  | "executable" => .ok .executable
  | "git" => .ok .git
  | "source-package" => .ok .sourcePackage
  | _ => .error "format must be cell, executable, git or source-package"

/-- Independent compiler or admission inputs for a Linen cell package. -/
inductive CellInput where
  | admitted (package admission : FilePath)
  | compile (target : String) (buildRecord : FilePath) (fingerprint : String)

/-- The selected deliverable and its format-specific inputs. -/
inductive Request where
  | cell (input : CellInput)
  | executable (target : String)
  | git
  | sourcePackage

/-- The immutable revision and local artifact, if the format writes one. -/
structure Result where
  format : String
  repository : String
  branch : String
  commit : String
  project : String
  path : Option String := none
  manifestPin : Option String := none
  deriving ToJson

private def command (name : String) (args : Array String) (cwd : FilePath) (timeout : Nat)
    (env := Process.toolEnv) : IO String := do
  let result ← System.Process.run name args timeout (cwd := cwd) (env := env)
  unless result.ok do throw (IO.userError (result.describe name))
  return result.stdout

private def archive (s : Session) (m : Meta) (path : FilePath) : IO Unit := do
  let tree := if m.source.path.isEmpty then m.workspace.localBase
    else m.workspace.localBase ++ ":" ++ m.source.path
  discard <| command "git" #["archive", "--format=tar.gz", "--output", path.toString, tree]
    (checkoutDir s.cfg s.id) s.cfg.gitTimeoutMs

private def executable (s : Session) (m : Meta) (target : String) (dest : FilePath) : IO Unit :=
  IO.FS.withTempDir fun temp => do
    unless target.length ≤ 128 && System.Git.Repository.isSegment target &&
        !target.startsWith "-" do throw (IO.userError "invalid Lake executable target")
    let source := temp / "source"
    IO.FS.createDir source
    let tarball := temp / "source.tar.gz"
    archive s m tarball
    discard <| command "tar" #["-xzf", tarball.toString, "-C", source.toString]
      temp s.cfg.gitTimeoutMs
    Workspace.seedCache s.cfg.packageCache source s.cfg.gitTimeoutMs
    let query ← command "lake" #["-J", "query", "--wfail", target ++ ":exe"] source s.cfg.checkTimeoutMs
    let file : String ← IO.ofExcept ((Lean.Json.parse query >>= Lean.fromJson?).mapError IO.userError)
    let reported : FilePath := ⟨file⟩
    let actual ← IO.FS.realPath (if reported.isAbsolute then reported else source / reported)
    let root ← IO.FS.realPath source
    unless actual.toString.startsWith (root.toString ++ "/") && (← actual.metadata).type == .file do
      throw (IO.userError "Lake executable target must produce a regular file inside the build snapshot")
    discard <| command "cp" #["-p", actual.toString, (dest / target).toString] temp 30000

private def cell (s : Session) (m : Meta) (input : CellInput) (dest : FilePath) : IO String := do
  let pin : CellPackage.SourcePin := ⟨m.source.repo.cloneUrl, m.workspace.remoteHead, m.source.path⟩
  match input with
  | .admitted package admission =>
    CellPackage.stageVerified (← IO.FS.realPath package) (← IO.FS.realPath admission) dest pin
  | .compile target record fingerprint =>
    IO.FS.withTempDir fun temp => do
      CellPackage.pack record dest fingerprint (do
        executable s m target temp
        pure (temp / target)) (some pin)

/-- Stage a complete export next to its destination and publish it by rename. -/
def inNewDirectory (requested : FilePath) (write : FilePath → IO α) : IO (FilePath × α) := do
  let some name := requested.fileName | throw (IO.userError "output must name a new directory")
  unless name != "." && name != ".." do throw (IO.userError "output must name a new directory")
  let parent := requested.parent.getD ⟨"."⟩
  IO.FS.createDirAll parent
  let parent ← IO.FS.realPath parent
  let dest := parent / name
  if ← dest.symlinkMetadata.toBaseIO |>.map (·.isOk) then
    throw (IO.userError "output directory already exists")
  let staging := parent / s!".lode-output-{← newId}"
  IO.FS.createDir staging
  try
    let result ← write staging
    -- One same-filesystem rename publishes the complete directory.
    if ← dest.symlinkMetadata.toBaseIO |>.map (·.isOk) then
      throw (IO.userError "output directory already exists")
    IO.FS.rename staging dest
    return (dest, result)
  finally
    if ← staging.pathExists then IO.FS.removeDirAll staging

/-- Export only the published project tree. Holding the control lock prevents
a concurrent run from changing the checkout or publication during export. -/
def write (s : Session) (request : Request) (destination : FilePath) : IO Result :=
  s.control.atomically (m := IO) do
    let control ← get
    let m ← s.info.get
    unless !control.running && (CheckoutReady.check? m).isSome do
      throw (IO.userError "output requires an idle session with a ready checkout")
    unless Validate.commit m.workspace.localBase && Validate.commit m.workspace.remoteHead &&
        Validate.projectPath m.source.path do throw (IO.userError "invalid published source")
    let diff ← Workspace.diff s.wctx (checkoutDir s.cfg s.id) m.workspace
    unless diff.isEmpty do throw (IO.userError "publish pending changes before exporting this revision")
    let (format, path, pin) ← match request with
      | .git => pure (Format.git, none, none)
      | .sourcePackage => do
        let (path, ()) ← inNewDirectory destination fun stage => archive s m (stage / "source.tar.gz")
        pure (.sourcePackage, some (path / "source.tar.gz"), none)
      | .executable target => do
        let (path, ()) ← inNewDirectory destination (executable s m target)
        pure (.executable, some (path / target), none)
      | .cell input => do
        let (path, pin) ← inNewDirectory destination (cell s m input)
        pure (.cell, some path, some pin)
    return {
      format := format.name
      repository := m.source.repo.cloneUrl
      branch := m.source.branch
      commit := m.workspace.remoteHead
      project := m.source.path
      path := path.map (·.toString)
      manifestPin := pin }

end Lode.Output
