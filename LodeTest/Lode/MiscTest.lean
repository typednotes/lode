/-
  Tests for the remaining pure parts: dates and the log endpoint's shape.
  (lake's diagnostics and the token comparison are linen's
  `System.LakeLog` and `Crypto.ConstantTime`, tested there.)
-/
import LodeTest.Util
import Lode.Server

open Lean (Json toJson)
open Lode

namespace LodeTests.Misc

-- ── Dates ───────────────────────────────────────────────────────────────────

#guard isoDate 0 == "1970-01-01"
#guard isoDate (951782400 * 1000) == "2000-02-29"
#guard isoDate (1790380800 * 1000) == "2026-09-26"

-- ── The API's shapes ────────────────────────────────────────────────────────

#guard (entriesJson #[.user "a" 1, .user "b" 2] 1 false).compress ==
  "{\"entries\":[{\"index\":1,\"text\":\"b\",\"time\":2,\"type\":\"user\"}],\"next\":2,\"running\":false}"

end LodeTests.Misc
