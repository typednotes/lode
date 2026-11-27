/- Offline native cell manifests and optional detached OpenPGP signatures. -/
import Lean.Data.Json
import Lode.Validate
import Linen.Crypto.SHA256
import Linen.Data.Hex
import Linen.System.GitFn.Descriptor
import Linen.System.Process

namespace Lode.Cell

open Lean (FromJson Json ToJson fromJson? toJson)

/-- A SHA-256 digest carried as 64 lowercase hexadecimal digits. -/
structure Digest where
  private mk ::
  hex : String
  deriving BEq

/-- Check the canonical textual form of a SHA-256 digest. -/
def Digest.check (value : String) : Except String Digest := do
  unless value.length == 64 && value == value.toLower && (Data.Hex.decode value).isSome do
    throw "expected a lowercase SHA-256 digest"
  return ⟨value⟩

instance : ToJson Digest := ⟨fun digest => .str digest.hex⟩
instance : FromJson Digest := ⟨fun json => json.getStr? >>= Digest.check⟩

/-- The immutable Git implementation coordinates declared by the producer. -/
structure Source where
  repository : String
  commit : String
  project : Option String := none
  module : String
  declaration : String
  deriving ToJson, FromJson

/-- Three authoring digests and the pinned source, with one native build target. -/
structure Identity where
  intentSha256 : Digest
  constraintsSha256 : Digest
  contractSha256 : Digest
  source : Source
  leanToolchain : String
  target : String
  runtimeAbi : String
  deriving ToJson, FromJson

private def label (value : String) : Bool :=
  !value.isEmpty && value.length ≤ 128 && value.all (fun c => c.toNat > 32 && c.toNat < 127)

private def Identity.check (identity : Identity) : Except String Unit := do
  let _ ← System.Git.Repository.parse identity.source.repository true
  unless (System.GitFn.CommitSha.ofString? identity.source.commit).isSome do throw "cell source requires a Git commit SHA"
  unless Validate.projectPath (identity.source.project.getD "") && Validate.functionName identity.source.module &&
      Validate.functionName identity.source.declaration do throw "invalid cell source coordinates"
  unless [identity.leanToolchain, identity.target, identity.runtimeAbi].all label do
    throw "cell toolchain, target and runtime ABI must be nonempty, bounded identifiers"

/-- Manifest for one compiled file. Signatures cover its exact UTF-8 bytes. -/
structure Manifest where
  version : Nat
  identity : Identity
  artifactSha256 : Digest
  artifactBytes : Nat
  deriving ToJson, FromJson

private def maxArtifactBytes := 128 * 1024 * 1024

/-- Check an untrusted manifest's format and structural invariants. -/
def Manifest.parse (text : String) : Except String Manifest := do
  let manifest : Manifest ← Json.parse text >>= fromJson?
  unless manifest.version == 1 do throw "unsupported cell manifest version"
  unless manifest.artifactBytes > 0 && manifest.artifactBytes ≤ maxArtifactBytes do
    throw "unsupported cell artifact size"
  manifest.identity.check
  return manifest

private def readBytes (file : System.FilePath) (limit : Nat) : IO ByteArray := do
  let info ← file.metadata
  unless info.type == .file do throw (IO.userError "cell input must be a regular file")
  let size := info.byteSize.toNat
  unless size ≤ limit do throw (IO.userError "cell file exceeds size limit")
  let handle ← IO.FS.Handle.mk file .read
  let bytes ← handle.read (USize.ofNat (size + 1))
  unless bytes.size == size do throw (IO.userError "cell file changed while being read")
  return bytes

private def readText (file : System.FilePath) : IO String := do
  let some text := String.fromUTF8? (← readBytes file 65536) | throw (IO.userError "cell metadata must be UTF-8")
  return text

private def digest (bytes : ByteArray) : IO Digest :=
  return ⟨Data.Hex.encode (← Crypto.SHA256.digest bytes)⟩

/-- Make a manifest from declared provenance and an existing artifact. -/
def make (identityFile artifact : System.FilePath) : IO Manifest := do
  let identity : Identity ← IO.ofExcept ((Json.parse (← readText identityFile) >>= fromJson?).mapError IO.userError)
  IO.ofExcept (identity.check.mapError IO.userError)
  let bytes ← readBytes artifact maxArtifactBytes
  unless !bytes.isEmpty do throw (IO.userError "cell artifact is empty")
  return { version := 1, identity, artifactSha256 := ← digest bytes, artifactBytes := bytes.size }

private def verifiedText (manifestFile artifact : System.FilePath) : IO String := do
  let text ← readText manifestFile
  let manifest ← IO.ofExcept ((Manifest.parse text).mapError IO.userError)
  let bytes ← readBytes artifact manifest.artifactBytes
  unless bytes.size == manifest.artifactBytes && (← digest bytes) == manifest.artifactSha256 do
    throw (IO.userError "cell artifact does not match the manifest")
  return text

/-- Verify a local artifact against its manifest, optionally requiring a
    detached OpenPGP signature from an explicit trusted keyring. -/
def verify (manifestFile artifact : System.FilePath)
    (openPgp : Option (System.FilePath × System.FilePath) := none) : IO Unit := do
  let text ← verifiedText manifestFile artifact
  if let some (signature, keyring) := openPgp then
    let keyring ← IO.FS.realPath keyring
    let signature ← IO.FS.realPath signature
    let result ← System.Process.run "gpgv" #["--keyring", keyring.toString, "--", signature.toString, "-"]
      30000 (input := some text)
    unless result.ok do throw (IO.userError "cell manifest signature verification failed")

/-- Sign the manifest's exact bytes after checking that the local artifact
    matches it. Select a signing key by its complete fingerprint. -/
def sign (manifestFile artifact : System.FilePath) (fingerprint : String) : IO String := do
  unless [40, 64].contains fingerprint.length && (Data.Hex.decode fingerprint).isSome do
    throw (IO.userError "provide the complete OpenPGP signing-key fingerprint")
  let text ← verifiedText manifestFile artifact
  let result ← System.Process.run "gpg" #["--no-options", "--batch", "--no-tty", "--pinentry-mode", "cancel",
    "--armor", "--detach-sign", "--local-user", fingerprint ++ "!", "--output", "-"] 30000 (input := some text)
  unless result.ok && result.stdout.startsWith "-----BEGIN PGP SIGNATURE-----" do
    throw (IO.userError "OpenPGP signing failed for the selected key")
  return result.stdout

end Lode.Cell
