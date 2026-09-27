/-
  Tests for `Lode.Model`: the two wire formats, both ways, and configuration
  parsing (what is implied by a provider, what local mode admits).
-/
import LodeTests.Util
import Lode.Model

open Lean (Json toJson)
open Lode Lode.Model

namespace LodeTests.Model

def pj (s : String) : Json := (Json.parse s).toOption.getD Json.null

def cfg (api : Api) : Config := { api, name := "m", baseUrl := "https://x/v1", maxTokens := 1000 }
def tools : Array ToolSpec := #[{ name := "read", description := "Read", schema := Json.mkObj [("type", "object")] }]
def convo : Array Message :=
  #[.user "hi", .assistant "let me look" #[{ id := "c1", name := "read", arguments := "{\"path\":\"a\"}" }],
    .toolResults #[{ id := "c1", name := "read", content := "" }]]

-- ── Anthropic ───────────────────────────────────────────────────────────────

def areq := anthropicRequest (cfg .anthropic) "SYS" tools convo
def amsgs := (areq.getObjValAs? (Array Json) "messages").toOption.getD #[]

#guard areq.getObjValAs? Nat "max_tokens" == .ok 1000
#guard (areq.getObjValAs? (Array Json) "system" |>.toOption.bind (·[0]?) |>.map (·.getObjValAs? String "text")) == some (.ok "SYS")
#guard ((areq.getObjValAs? (Array Json) "tools").toOption.bind (·[0]?)).map (·.getObjValAs? String "name") == some (.ok "read")
#guard amsgs.size == 3
-- The assistant's tool call is a `tool_use` block whose input is an object.
#guard ((amsgs[1]!.getObjValAs? (Array Json) "content").toOption.bind (·[1]?)).map
  (fun b => (b.getObjValAs? String "type", (b.getObjVal? "input" >>= (·.getObjValAs? String "path")))) ==
  some (.ok "tool_use", .ok "a")
-- Results travel in a user message; an empty output is not sent empty.
#guard amsgs[2]!.getObjValAs? String "role" == .ok "user"
#guard ((amsgs[2]!.getObjValAs? (Array Json) "content").toOption.bind (·[0]?)).map
  (fun b => (b.getObjValAs? String "tool_use_id", b.getObjValAs? String "content")) == some (.ok "c1", .ok "(no output)")
-- The last block is a cache breakpoint.
#guard ((amsgs[2]!.getObjValAs? (Array Json) "content").toOption.bind (·[0]?)).map
  (fun b => (b.getObjVal? "cache_control").toOption.isSome) == some true
-- A malformed tool input is sent as `{}`.
#guard ((((anthropicRequest (cfg .anthropic) "" #[] #[.assistant "" #[{ id := "x", name := "n", arguments := "{oops" }]]).getObjValAs?
  (Array Json) "messages").toOption.bind (·[0]?)).bind fun m => (m.getObjValAs? (Array Json) "content").toOption.bind (·[0]?)).map
  (fun b => (b.getObjVal? "input").toOption.map (·.compress)) == some (some "{}")

#guard (anthropicReply (pj "{\"content\": [{\"type\": \"text\", \"text\": \"a\"}, {\"type\": \"tool_use\", \"id\": \"t1\", \"name\": \"read\", \"input\": {\"path\": \"x\"}}], \"stop_reason\": \"tool_use\", \"usage\": {\"input_tokens\": 10, \"output_tokens\": 5, \"cache_read_input_tokens\": 7}}")) ==
  .ok ({ text := "a", calls := #[{ id := "t1", name := "read", arguments := "{\"path\":\"x\"}" }], stop := "tool_use",
         usage := { input := 10, output := 5, cacheRead := 7 } } : Reply)
#guard (anthropicReply (pj "{\"type\": \"error\", \"error\": {\"message\": \"overloaded\"}}")) matches .error _

-- ── OpenAI ──────────────────────────────────────────────────────────────────

def oreq := openaiRequest (cfg .openai) "SYS" tools convo
def omsgs := (oreq.getObjValAs? (Array Json) "messages").toOption.getD #[]

-- The system prompt is the first message; each result is its own `tool` message.
#guard omsgs.map (·.getObjValAs? String "role" |>.toOption.getD "") == #["system", "user", "assistant", "tool"]
#guard ((omsgs[2]!.getObjValAs? (Array Json) "tool_calls").toOption.bind (·[0]?)).map
  (fun c => (c.getObjVal? "function" >>= (·.getObjValAs? String "arguments"))) == some (.ok "{\"path\":\"a\"}")
#guard omsgs[3]!.getObjValAs? String "tool_call_id" == .ok "c1"
#guard ((oreq.getObjValAs? (Array Json) "tools").toOption.bind (·[0]?)).map
  (fun t => t.getObjVal? "function" >>= (·.getObjValAs? String "name")) == some (.ok "read")

#guard (openaiReply (pj "{\"choices\": [{\"message\": {\"content\": null, \"tool_calls\": [{\"id\": \"k\", \"type\": \"function\", \"function\": {\"name\": \"bash\", \"arguments\": \"{\\\"command\\\":\\\"ls\\\"}\"}}]}, \"finish_reason\": \"tool_calls\"}], \"usage\": {\"prompt_tokens\": 3, \"completion_tokens\": 2}}")) ==
  .ok ({ text := "", calls := #[{ id := "k", name := "bash", arguments := "{\"command\":\"ls\"}" }], stop := "tool_calls",
         usage := { input := 3, output := 2 } } : Reply)
#guard (openaiReply (pj "{\"choices\": []}")) matches .error _

-- ── Configuration ───────────────────────────────────────────────────────────

-- A provider implies the API and the base.
#guard ((Config.parse (Json.mkObj [("name", "claude")]) (some "anthropic") none false).toOption.map
  fun c => (c.api, c.baseUrl, c.contextWindow)) == some (.anthropic, "https://api.anthropic.com/v1", 200000)
#guard ((Config.parse (Json.mkObj [("name", "mistral-large-latest")]) (some "mistral") none false).toOption.map
  (·.baseUrl)) == some "https://api.mistral.ai/v1"
-- `openai-compatible` has no default base.
#guard (Config.parse (Json.mkObj [("name", "m")]) (some "openai-compatible") none false).toOption.isNone
-- The server's default fills what the request leaves out.
#guard ((Config.parse (Json.mkObj []) none (some (cfg .openai)) false).toOption.map (·.name)) == some "m"
#guard (Config.parse (Json.mkObj []) none none false).toOption.isNone
-- `scripted` only in local mode.
#guard (Config.parse (Json.mkObj [("api", "scripted")]) none none false).toOption.isNone
#guard ((Config.parse (Json.mkObj [("api", "scripted"), ("script", Json.arr #[Json.mkObj [("text", "x")]])]) none none true).toOption.map
  (·.script.size)) == some 1
#guard (Config.parse (Json.mkObj [("name", "m"), ("baseUrl", "https://x/v1/")]) (some "openai") none false).toOption.isNone
-- A configuration round-trips through its persisted form.
#guard ((Config.parse (Json.mkObj [("name", "claude")]) (some "anthropic") none false).toOption.bind
  fun c => (Config.ofJson (toJson c)).toOption.map fun c' => (c'.api, c'.name, c'.baseUrl, c'.maxTokens)) ==
  some (.anthropic, "claude", "https://api.anthropic.com/v1", 8192)

#guard retryable 429 && retryable 529 && retryable 500 && !retryable 400 && !retryable 401

end LodeTests.Model
