import Lode.Cli
import Lode.Cell
import Lode.Server
import Linen.Network.WebApp.Server

namespace Lode.App

/-- Start the HTTP service with the selected operator settings. -/
def serve (extensions : Extension.Catalog) (settingsFile : Option String := none) : IO Unit := do
  let settings ← Lode.Settings.load settingsFile
  let port ← Lode.Settings.port settings
  let cfg := { (← Settings.runtime settings) with extensions }
  let registry ← Lode.Registry.new cfg
  if cfg.allowLocal then IO.eprintln "lode: LOCAL MODE — file:// repositories and the scripted model accepted"
  if cfg.token.isNone then IO.eprintln "lode: LODE_TOKEN is not set — the API is unauthenticated"
  if cfg.lun.isNone then IO.eprintln "lode: LODE_LUN_URL is not set — lun_build and lun_call are unavailable"
  IO.println s!"lode listening on :{port}"
  Network.WebApp.Server.run port (Lode.application registry)

/-- Dispatch native stdio runs or the HTTP service, keeping diagnostics off stdout. -/
def main (catalog : Except String Extension.Catalog) (args : List String) : IO UInt32 := do
  try
    let extensions ← IO.ofExcept (catalog.mapError IO.userError)
    match args with
    | [] | ["serve"] => serve extensions none; return 0
    | ["serve", "--settings", path] | ["--settings", path] => serve extensions (some path); return 0
    | ["serve", "--settings"] | ["--settings"] =>
      IO.eprintln "lode: --settings requires a TOML or JSON filename"
      return 2
    | ["--help"] | ["-h"] | ["serve", "--help"] | ["serve", "-h"] | ["run", "--help"] | ["run", "-h"]
    | ["secrets", "--help"] | ["secrets", "store-model-key", "--help"] =>
      IO.print Lode.Cli.usage
      return 0
    | ["cell", "--help"] | ["output", "--help"] | ["oauth", "--help"] | ["cell", "package", "--help"] =>
      IO.print Lode.Cli.usage
      return 0
    | ["cell", "package", build, worker, dest, "--key", fingerprint] =>
      let (path, pin) ← Output.inNewDirectory ⟨dest⟩ fun stage =>
        CellPackage.pack ⟨build⟩ stage fingerprint (pure ⟨worker⟩)
      IO.println (Lean.Json.mkObj [("path", .str path.toString),
        ("pin", .str pin)]).compress
      return 0
    | "output" :: id :: rest =>
      match Lode.Cli.OutputOptions.parse id rest with
      | .error e => IO.eprintln s!"lode: {e}"; return 2
      | .ok opts => Lode.Cli.output opts; return 0
    | ["oauth", base, id] => Lode.Cli.modelOAuth base id false; return 0
    | ["oauth", base, id, "--open"] => Lode.Cli.modelOAuth base id true; return 0
    | ["cell", "manifest", identity, artifact] =>
      IO.println (Lean.toJson (← Cell.make ⟨identity⟩ ⟨artifact⟩)).pretty
      return 0
    | ["cell", "verify", manifest, artifact] =>
      Cell.verify ⟨manifest⟩ ⟨artifact⟩
      IO.println "Cell artifact digest verified."
      return 0
    | ["cell", "verify", manifest, artifact, "--signature", signature, "--keyring", keyring] =>
      Cell.verify ⟨manifest⟩ ⟨artifact⟩ (some (⟨signature⟩, ⟨keyring⟩))
      IO.println "Cell artifact digest and OpenPGP signature verified."
      return 0
    | ["cell", "sign", manifest, artifact, "--key", fingerprint] =>
      IO.print (← Cell.sign ⟨manifest⟩ ⟨artifact⟩ fingerprint)
      return 0
    | "secrets" :: "store-model-key" :: rest => Lode.Cli.storeModelKey rest
    | "run" :: rest =>
      let opts ← match Lode.Cli.Options.parse rest with
        | .ok opts => pure opts
        | .error error => IO.eprintln s!"lode: {error}\n{Lode.Cli.usage}"; return 2
      let settings ← Lode.Settings.load opts.settingsFile
      Lode.Cli.run { (← Settings.runtime settings true) with extensions } opts
    | _ => IO.eprintln s!"lode: unknown command\n{Lode.Cli.usage}"; return 2
  catch e =>
    IO.eprintln s!"lode: {e}"
    return 1

end Lode.App
