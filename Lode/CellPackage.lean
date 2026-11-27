/- Compiler packaging and verified transfer for Linen's versioned cell format. -/
import Linen.System.Cell

namespace Lode.CellPackage

open Lean (Json FromJson fromJson?)
open System (FilePath)
open System.Cell

private structure BuildRecord where
  revision : Revision
  inputs : BuildInputs
  runtime : Runtime
  deriving FromJson

private structure AdmissionRecord where
  pin : Ref .manifest
  runtime : Runtime
  keyring : String
  deriving FromJson

private def io (result : Except String α) : IO α :=
  IO.ofExcept (result.mapError IO.userError)

private def bytes (path : FilePath) (limit : Nat) : IO ByteArray := do
  let metadata ← path.metadata
  unless metadata.type == .file && metadata.byteSize.toNat ≤ limit do
    throw (IO.userError "expected a regular cell file within its size limit")
  System.Process.readBounded (← IO.FS.Handle.mk path .read) limit

private def readRecord [FromJson α] (path : FilePath) : IO α := do
  let some text := String.fromUTF8? (← bytes path 65536) | throw (IO.userError "expected a UTF-8 cell record")
  io (Json.parse text >>= fromJson?)

/-- Immutable Git coordinates shared by a session and its cell package. -/
structure SourcePin where
  repository : String
  commit : String
  project : String

private def SourcePin.check (pin : SourcePin) (source : GitSource) : IO Unit := do
  let expected ← io (GitSource.check pin.repository pin.commit pin.project
    source.moduleName.toString source.declaration.toString)
  unless source == expected do throw (IO.userError "cell package does not match the session's published source")

/-- Sign a checked compiler worker and return the pin for the exact manifest bytes.
The caller provides a private staging directory and the compiler's build record. -/
def pack (record out : FilePath) (fingerprint : String) (worker : IO FilePath)
    (pin : Option SourcePin := none) : IO String := do
  let build : BuildRecord ← readRecord record
  if let some pin := pin then pin.check build.revision.source
  let artifact ← bytes (← worker) maxArtifactBytes
  let manifest ← Manifest.make build.revision build.inputs build.runtime artifact
  let signature ← manifest.sign fingerprint
  IO.FS.writeBinFile (out / "worker") artifact
  IO.FS.writeFile (out / "manifest.asc") signature
  IO.FS.writeFile (out / "manifest.json") manifest.render
  return (← manifestPin manifest.render).digest.hex

/-- Stage the exact files, verify them through Linen, and bind the signed
repository, commit and project to the session's published source. -/
def stageVerified (location record out : FilePath) (pin : SourcePin) : IO String := do
  let admission : AdmissionRecord ← readRecord record
  let keyring : FilePath := ⟨admission.keyring⟩
  let keyring := if keyring.isAbsolute then keyring else record.parent.getD ⟨"."⟩ / keyring
  for (name, limit) in [("manifest.json", 65536), ("manifest.asc", 65536), ("worker", maxArtifactBytes)] do
    IO.FS.writeBinFile (out / name) (← bytes (location / name) limit)
  let admitted ← openPackage { pin := admission.pin, runtime := admission.runtime, keyring } (.local out)
  pin.check admitted.manifest.revision.source
  return admitted.pin.digest.hex

end Lode.CellPackage
