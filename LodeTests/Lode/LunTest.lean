/-
  Tests for `Lode.Lun`: `lun.json` is read for its shape, the build request
  carries the published commit and the repository warrant, and lun's
  statuses read well for the model.
-/
import LodeTests.Util
import Lode.Lun

open Lean (Json fromJson?)
open Lode.Lun

namespace LodeTests.Lun

def manifest : String :=
  "{\"open\": [\"P\"], \"cells\": [{\"name\": \"double\", \"module\": \"P.M\", \"function\": \"P.double\", \"signature\": \"Nat → Eff [] Nat\"}], \"dags\": []}"

#guard (parseManifest manifest).toOption.isSome
#guard (parseManifest "{\"cells\": []}").toOption.isNone
#guard (parseManifest "[1]").toOption.isNone
#guard (parseManifest "{\"cells\": [{}], \"dags\": 3}").toOption.isNone

def src : Lode.Workspace.Source :=
  { repo := { host := .github, segments := ["o", "r"], cloneUrl := "https://github.com/o/r.git" }
    branch := "main", path := "lean" }

def req := buildRequest src ("".pushn 'a' 40) none ((parseManifest manifest).toOption.getD { cells := #[] })

#guard (req.getObjVal? "source" >>= (·.getObjValAs? String "commit")) == .ok ("".pushn 'a' 40)
#guard (req.getObjVal? "source" >>= (·.getObjValAs? String "path")) == .ok "lean"
#guard (req.getObjVal? "source" >>= (·.getObjValAs? Json "credentials")) == .ok Json.null
#guard (req.getObjValAs? (Array Json) "cells").toOption.map (·.size) == some 1
#guard (req.getObjValAs? (Array String) "open") == .ok #["P"]
-- Absent fields are `null`, which lun reads as absent.
#guard ((buildRequest { src with path := "" } "c" none { cells := #[] }).getObjVal? "source" >>=
  (·.getObjValAs? Json "path")) == .ok Json.null
#guard ((buildRequest src "c" none { cells := #[] }).getObjValAs? Json "dags") == .ok Json.null

-- lun's answers, read through derived shapes.
def diag (j : Json) : Diagnostic := (fromJson? j).toOption.getD {}
def status (j : Json) : Status := (fromJson? j).toOption.getD { id := "?", state := "?" }

#guard renderDiagnostic (diag (Json.mkObj [("scope", "cell"), ("name", "double"), ("file", "P/M.lean"),
  ("line", (3 : Nat)), ("column", (4 : Nat)), ("severity", "error"), ("message", "type mismatch")])) ==
  "[cell double] P/M.lean:3:4: error: type mismatch"
#guard renderDiagnostic (diag (Json.mkObj [("scope", "dag"), ("name", "main"), ("line", (2 : Nat)),
  ("column", (1 : Nat)), ("message", "unknown"), ("hint", "h")])) == "[dag main] line 2:1: error: unknown\n  hint: h"
#guard (renderStatus (status (Json.mkObj [("id", "b"), ("state", "ready"), ("diagnostics", Json.arr #[]),
  ("cells", Json.arr #[Json.mkObj [("name", "double")]]), ("dags", Json.arr #[])]))).startsWith
  "lun build b: ready\n\ncells: double\ndags: "
#guard (renderStatus (status (Json.mkObj [("id", "b"), ("state", "failed"), ("error", "the build failed"),
  ("diagnostics", Json.arr #[Json.mkObj [("scope", "cell"), ("name", "d"), ("message", "m")]])]))) ==
  "lun build b: failed\nerror: the build failed\n\n1 diagnostic(s):\n[cell d] error: m"
-- A status without an id or state is not a status.
#guard (fromJson? (Json.mkObj [("state", "ready")]) : Except String Status).toOption.isNone
#guard finished "ready" && finished "failed" && !finished "building"

end LodeTests.Lun
