import Lode.Cli
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
