import Lode.Settings
import Lode.Mcp
import Lode.Extensions.Lean

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
