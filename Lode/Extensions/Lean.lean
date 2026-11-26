/- Sample tool compiled into the standard Lode executable. -/
import Lode.Extension
import Lode.Process

namespace Lode.Extensions

open Lean (Json)

/-- Report which Lean compiler the project's Lake environment actually uses. -/
def leanVersion : Extension.Tool :=
  Extension.Tool.define "lean_version" "Return the Lean version selected by the workspace's Lake environment."
    (Json.mkObj [("type", "object"), ("additionalProperties", .bool false)])
    (fun json => do
      let fields ← json.getObj?
      unless fields.isEmpty do throw "lean_version expects an empty object")
    (fun ctx () => do
      let result ← System.Process.run "lake" #["env", "lean", "--version"] (min 10000 ctx.timeoutMs)
        (cwd := ctx.project) (env := Process.toolEnv) (abort := some ctx.abort)
      return (if result.ok then result.stdout.trimAscii.toString else result.describe "lake env lean --version", !result.ok))

end Lode.Extensions
