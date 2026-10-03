/- Tests for the stdio boundary: flags, shared validation, streams and status. -/
import Lode.Cli

open Lean (Json)
open Lode

namespace LodeTests.Cli

#guard (Cli.Options.parse ["--repo", "."]).toOption == some { repo := some "." }
#guard (Cli.Options.parse []).toOption.isNone
#guard (Cli.Options.parse ["--repo"]).toOption.isNone
#guard (Cli.Options.parse ["--repo", "--branch"]).toOption.isNone
#guard (Cli.Options.parse ["--repo", ".", "--repo", "/tmp/r"]).toOption.isNone
#guard (Cli.Options.parse ["--config", "s.json", "--repo", "."]).toOption.isNone
#guard (Cli.Options.parse ["--resume", "0123456789abcdef0123456789abcdef", "--path", "lean"]).toOption.isNone
#guard (Cli.Options.parse ["--resume", "bad"]).toOption.isNone
#guard (Cli.Options.parse ["--repo", ".", "--branch", "a..b"]).toOption.isNone
#guard (Cli.Options.parse ["--repo", ".", "--path", "../lean"]).toOption.isNone
#guard (Cli.Options.parse ["--repo", ".", "--agent", "unknown"]).toOption.isNone
#guard (Cli.Options.parse ["--repo", ".", "--unknown", "value"]).toOption.isNone

def config : Config := { workdir := "/tmp/lode", allowLocal := true }
def request : Json := (Cli.Options.request { repo := some "/tmp/r" } "file:///tmp/r").mergeObj
  (Json.mkObj [("model", Json.mkObj [("api", "scripted")])])
#guard (Cli.parseSpec request config).isOk
#guard (Cli.parseSpec request { config with allowLocal := false }).toOption.isNone
#guard (Cli.parseSpec (request.setObjVal! "message" "hidden task") config).toOption.isNone

#guard Cli.renderEntry (.assistant { text := "answer", calls := #[] } "scripted" 0) == ("answer\n", "")
#guard Cli.renderEntry (.assistant { text := "answer\n", calls := #[] } "scripted" 0) == ("answer\n", "")
#guard Cli.renderEntry (.assistant { text := "thinking", calls := #[{ id := "c", name := "write", arguments := "{}" }] }
  "scripted" 0) == ("", "thinking\n[tool] write\n")
#guard (Cli.renderEntry (.toolResults #[{ id := "c", name := "read", content := "missing", isError := true }] 0)).1 == ""
#guard Cli.renderEntry (.user "task" 0) == ("", "")
#guard Cli.exitCode #[.event "run_finished" "1 step(s)" 0] == 0
#guard Cli.exitCode #[.event "error" "no credentials" 0] == 1
#guard Cli.exitCode #[.event "out_of_fuel" "1 step" 0] == 1
#guard Cli.exitCode #[.event "aborted" "stopped" 0] == 1
#guard Cli.exitCode #[] == 1

end LodeTests.Cli
