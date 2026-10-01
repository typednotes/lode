import Lake
open System Lake DSL

-- `lode` links linen's native code (TLS for its HTTP client, OpenSSL's
-- SHA-256) but none of its pkg-config libraries (no Postgres), so, like
-- `lun`, it needs no extra link arguments.

require linen from git "https://github.com/typednotes/linen" @ "v1.10.0"

-- For `Liaison.Wire` only: liaison's wire format (`POST /v0/egress`), the
-- module liaison's own server parses with. It is pure and imports none of
-- liaison's HMAC, Postgres or egress code, so it adds no link arguments (as
-- in lun).
require liaison from git "https://github.com/typednotes/liaison" @ "v0.6.0"

-- Reuse Lun's execution projection/refresh witnesses, not a second policy model.
require lun from git "https://github.com/typednotes/lun" @ "291ae06d8f947140654091442ed28a7acfb0d037"

package lode where
  version := v!"0.4.1"
  testDriver := "LodeTest"

@[default_target]
lean_lib Lode where

-- Named `LodeTest` (module tree `LodeTest.*`), the `{Package}Test` convention
-- of mathlib, batteries and aesop, and the package's `testDriver` (`lake test`).
lean_lib LodeTest where
  precompileModules := true

@[default_target]
lean_exe lode where
  root := `Main

-- Optional real-broker transport fixture, linked with the same native Linen
-- HTTP/TLS implementation as the writer. Never part of a release default target.
lean_exe «lode-native-smoke» where
  root := `test.NativeBrokerSmoke
