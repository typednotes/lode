import Lode.Settings
import Lode.Mcp
import Lode.Extensions.Lean
import Lode.Cell

open Lean Lode

private def settings (doc : String) : Except String Settings.File := Json.parse doc >>= Settings.parse

-- S1: operator settings have a common schema with no credential fields.
#guard (settings "{\"port\":8181,\"model\":{\"provider\":\"scaleway\"}}").toOption.bind (·.port) == some 8181
#guard (settings "{\"secrets\":{\"token\":\"fixture\"}}").isOk == false
#guard (settings "{\"model\":{\"apiKey\":\"fixture\"}}").isOk == false
#guard (settings "{\"maxSteps\":-1}").isOk == false
#guard (settings "{\"allowLocal\":\"true\"}").isOk == false

-- S2: presets use each provider's supported endpoint.
#guard Model.defaultBase? "scaleway" == some "https://api.scaleway.ai/v1"
#guard Model.defaultBase? "baseten" == some "https://inference.baseten.co/v1"

-- S3: plaintext Secrets is local, and the returned key is endpoint-bound.
private def modelBase := "https://api.example/v1"
#guard (Secrets.ModelKey.configure "http://127.0.0.1:9001" "lode/model" modelBase "fixture" true).isOk
#guard (Secrets.ModelKey.configure "http://127.0.0.1:9001" "lode/model" modelBase "fixture" false).isOk == false
#guard (Secrets.ModelKey.configure "http://localhost.example" "lode/model" modelBase "fixture" true).isOk == false
#guard (Secrets.ModelKey.configure "https://vault.example" "../model" modelBase "fixture" false).isOk == false
#guard (Secrets.decodeModelKey "{\"data\":{\"modelBaseUrl\":\"https://api.example/v1\",\"apiKey\":\"fixture\"}}" modelBase).toOption == some "fixture"
#guard (Secrets.decodeModelKey "{\"data\":{\"modelBaseUrl\":\"https://other.example/v1\",\"apiKey\":\"fixture\"}}" modelBase).isOk == false
#guard Secrets.validKey "one\ntwo" == false

-- S5/S6: catalog entries are unique, and MCP replies correlate with the request.
#guard (Extension.Catalog.check [Extensions.leanVersion, Extensions.leanVersion]).isOk == false
#guard (Mcp.response 1 "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}").isOk == false
#guard (Mcp.response 1 "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"error\":{}}").isOk == false

-- S7: redirect route and issuer transport are fixed by the operator configuration.
#guard (OAuth.Config.check "https://issuer.example/authorize" "https://issuer.example/token"
  "https://lode.example/v0/model-oauth/callback" "client" none none false).isOk
#guard (OAuth.Config.check "https://issuer.example/authorize" "http://issuer.example/token"
  "https://lode.example/v0/model-oauth/callback" "client" none none true).isOk == false
#guard (OAuth.Config.check "https://issuer.example/authorize" "https://issuer.example/token"
  "https://lode.example/other" "client" none none false).isOk == false

-- S8: an SSE result needs a complete frame. A reverse request is refused.
#guard (Mcp.sseResponse 2 "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":true}\n\n").toOption == some (.bool true)
#guard (Mcp.sseResponse 2 "data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":true}").isOk == false
#guard (Mcp.sseResponse 2 "data: {\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"sampling/createMessage\"}\n\n").isOk == false

-- S9: manifests use canonical lower-case digests.
#guard (Cell.Digest.check (String.ofList (List.replicate 64 'a'))).isOk
#guard (Cell.Digest.check (String.ofList (List.replicate 64 'A'))).isOk == false
#guard (Cell.Manifest.parse "{}").isOk == false
