import Lake
open System Lake DSL

-- `lode` links linen's native code (TLS for its HTTP client, OpenSSL's
-- SHA-256) but none of its pkg-config libraries (no Postgres), so, like
-- `lun`, it needs no extra link arguments.

require linen from git "https://github.com/typednotes/linen" @ "v1.6.1"

-- For `Liaison.Wire` only: liaison's wire format (`POST /v0/egress`), the
-- module liaison's own server parses with. It is pure and imports none of
-- liaison's HMAC, Postgres or egress code, so it adds no link arguments (as
-- in lun).
require liaison from git "https://github.com/typednotes/liaison" @ "v0.5.3"

package lode where
  version := v!"0.1.0"

@[default_target]
lean_lib Lode where

-- Named `LodeTests` (module tree `LodeTests.*`), not `Tests`: `linen` has its
-- own `Tests.*` tree, and two packages declaring the same top-level module
-- prefix confuse Lake's module lookup.
lean_lib LodeTests where
  precompileModules := true

@[default_target]
lean_exe lode where
  root := `Main
