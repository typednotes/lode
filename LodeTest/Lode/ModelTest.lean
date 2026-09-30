/-
  Tests for `Lode.Model`: the two wire formats, both ways, and configuration
  parsing (what is implied by a provider, what local mode admits).
-/
import LodeTest.Util
import Lode.Model

open Lean (Json toJson)
open Lode Lode.Model

namespace LodeTests.Model

def pj (s : String) : Json := (Json.parse s).toOption.getD Json.null

def cfg (api : Api) : Config := { api, name := "m", baseUrl := if api == .anthropic then "https://api.anthropic.com/v1" else "https://x/v1", maxTokens := 1000 }
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

-- Every declared provider can be carried by a model warrant. Classifiers are
-- deliberately excluded: they use the app's typed /systemone endpoint.
#guard providers.length == 37
#guard providers.contains "scaleway" && providers.contains "ant-ling" && providers.contains "radius"
#guard providers.contains "qwen-token-plan-individual" && providers.contains "xiaomi-token-plan-ams"
#guard !providers.contains "typesafe"
#guard apiOfProvider "gemini" == .gemini && apiOfProvider "meta" == .responses
#guard apiOfProvider "radius" == .pi && apiOfProvider "minimax-cn" == .anthropic
#guard supportsApi "opencode" .gemini && supportsApi "github-copilot" .responses
#guard !supportsApi "minimax" .openai && !supportsApi "scaleway" .anthropic

def rreq := responsesRequest (cfg .responses) "SYS" tools convo
#guard rreq.getObjValAs? Nat "max_output_tokens" == .ok 1000
#guard rreq.getObjValAs? Bool "store" == .ok false
#guard ((rreq.getObjValAs? (Array Json) "input").toOption.bind (·[3]?)).map (·.getObjValAs? String "type") == some (.ok "function_call_output")
#guard (responsesReply (pj "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"read\",\"arguments\":\"{}\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"input_tokens_details\":{\"cached_tokens\":4}}}")) ==
  .ok ({ text := "", calls := #[{id:="c",name:="read",arguments:="{}"}], stop := "completed", usage := {input:=6,output:=2,cacheRead:=4} } : Reply)

def greq := geminiRequest (cfg .gemini) "SYS" tools convo
#guard ((greq.getObjVal? "generationConfig" >>= (·.getObjValAs? Nat "maxOutputTokens"))) == .ok 1000
#guard (geminiReply (pj "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"read\",\"args\":{}},\"thoughtSignature\":\"sig\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"cachedContentTokenCount\":4,\"candidatesTokenCount\":2}}")) ==
  .ok ({
    text := "", calls := #[{id:="call_0",name:="read",arguments:="{}",signature:=some "sig"}]
    stop := "STOP", usage := {input:=6,output:=2,cacheRead:=4}
    replay := some { api := "gemini", items := #["{\"functionCall\":{\"args\":{},\"name\":\"read\"},\"thoughtSignature\":\"sig\"}"] } } : Reply)
#guard ((geminiRequest (cfg .gemini) "" #[] #[.assistant "" #[{id:="c",name:="read",arguments:="{}",signature:=some "sig"}]]).getObjValAs? (Array Json) "contents" |>.toOption.bind (·[0]?) |>.bind fun m => (m.getObjValAs? (Array Json) "parts").toOption.bind (·[0]?) |>.map (·.getObjValAs? String "thoughtSignature")) == some (.ok "sig")

#guard (piRequest (cfg .pi) "SYS" tools convo).getObjValAs? String "model" == .ok "m"
#guard piReply "data: {\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"hi\"}\n\ndata: {\"type\":\"text_end\",\"contentIndex\":0,\"content\":\"hi\"}\n\ndata: {\"type\":\"done\",\"reason\":\"stop\",\"usage\":{\"input\":2,\"output\":1}}\n\n" ==
  .ok ({text:="hi",calls:=#[],stop:="end_turn",usage:={input:=2,output:=1}} : Reply)
#guard (piReply "data: {\"type\":\"text_delta\",\"delta\":\"incomplete\"}\n\n").toOption.isNone
#guard (piReply "data: {\"type\":\"error\",\"errorMessage\":\"denied\"}\n\n").toOption.isNone

-- Catalog routing parity, including gateway exceptions and future GPT majors.
#guard apiForModel "opencode-go" "minimax-m3" == .anthropic
#guard apiForModel "opencode" "qwen3.8-max" == .openai
#guard apiForModel "opencode-go" "qwen3.8-max" == .anthropic
#guard apiForModel "opencode-go" "muse-spark-1.3-contributor" == .responses
#guard apiForModel "github-copilot" "gpt-4.1" == .openai
#guard apiForModel "github-copilot" "gpt-4o" == .openai
#guard apiForModel "github-copilot" "gpt-5-mini" == .openai
#guard apiForModel "github-copilot" "gpt-6" == .responses
#guard apiForModel "openai" "gpt-12.1" == .responses
#guard !supportsApi "unknown-provider" .openai
#guard supportsApi "radius" .pi
#guard (Config.parse (pj "{\"api\":\"openai\",\"name\":\"gpt-6\"}") (some "openai") none false).toOption.isNone
#guard (Config.parse (pj "{\"name\":\"gpt-6\"}") (some "openai") none false).toOption.map (·.api) == some .responses
#guard (openaiRequest { (cfg .openai) with name := "gpt-5-mini" } "" #[] #[]).getObjValAs? Nat "max_completion_tokens" == .ok 1000

-- A truncated or structurally malformed response must never execute tools.
#guard (anthropicReply (pj "{\"content\":[{\"type\":\"tool_use\",\"name\":\"read\",\"input\":{}}],\"stop_reason\":\"tool_use\"}")).toOption.isNone
#guard (anthropicReply (pj "{\"content\":[],\"stop_reason\":null}")).toOption.isNone
#guard (openaiReply (pj "{\"choices\":[{\"message\":{\"tool_calls\":[{\"function\":{\"name\":\"read\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}")).toOption.isNone
#guard (openaiReply (pj "{\"choices\":[{\"message\":{\"content\":\"x\"}}]}")).toOption.isNone
#guard (responsesReply (pj "{\"status\":\"in_progress\",\"output\":[]}")).toOption.isNone
#guard (responsesReply (pj "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[]}")).toOption.map (·.stop) == some "max_tokens"
#guard (responsesReply (pj "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"content_filter\"},\"output\":[]}")).toOption.isNone
#guard (responsesReply (pj "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"name\":\"read\",\"arguments\":\"{}\"}]}")).toOption.isNone
#guard (geminiReply (pj "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\",\"content\":{\"parts\":[{\"text\":\"partial\"}]}}]}")).toOption.map (·.stop) == some "max_tokens"
#guard (geminiReply (pj "{\"candidates\":[{\"finishReason\":\"SAFETY\"}]}")).toOption.isNone
#guard (piReply "data: {\"type\":\"toolcall_start\",\"contentIndex\":0,\"id\":\"c\",\"toolName\":\"read\"}\n\ndata: {\"type\":\"done\",\"reason\":\"toolUse\",\"usage\":{\"input\":1,\"output\":1}}\n\n").toOption.isNone
#guard (piReply "data: {\"type\":\"done\",\"reason\":\"error\",\"usage\":{\"input\":1,\"output\":1}}\n\n").toOption.isNone

def reasoningReply := responsesReply (pj "{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"id\":\"r\",\"summary\":[],\"encrypted_content\":\"opaque\"},{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"read\",\"arguments\":\"{}\"}]}")
def replayConvo := Lode.context #[.user "hi" 0, .assistant (reasoningReply.toOption.getD default) "m" 1,
  .toolResults #[{id := "c", name := "read", content := "ok"}] 2]
def replayRequest := responsesRequest (cfg .responses) "" tools replayConvo
#guard ((replayRequest.getObjValAs? (Array Json) "input").toOption.getD #[]).map (fun j => (j.getObjValAs? String "type").toOption.getD "user") ==
  #["user", "reasoning", "function_call", "function_call_output"]
#guard (reasoningReply.toOption.bind (·.replay)).map (·.items.size) == some 2
#guard (responsesReply (pj "{\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"summary\":[]}]}")).toOption.isNone
#guard replayRequest.getObjValAs? (Array String) "include" == .ok #["reasoning.encrypted_content"]
#guard boundedHistory tools replayConvo == replayConvo
#guard (boundedHistory #[] replayConvo).size == 1
#guard match (boundedHistory #[] replayConvo)[0]! with
  | .user text => text.endsWith "Last user task: hi" && !(text.splitOn "local metadata result").length > 1
  | _ => false
#guard ((piRequest (cfg .pi) "SYS" tools convo "stable").getObjVal? "options" >>= (·.getObjValAs? String "sessionId")) == .ok "stable"
#guard (((piRequest (cfg .pi) "SYS" tools convo).getObjVal? "context" >>= (·.getObjValAs? (Array Json) "messages")).toOption.bind (·[0]?) |>.map (fun j => (j.getObjValAs? (Array Json) "toolsAdded").toOption.isSome)) == some true

#guard (geminiReply (pj "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"functionCall\":{\"id\":\"native-id\",\"name\":\"read\",\"args\":{}}}]}}]}")).toOption.map (fun r => (r.calls[0]!.id, r.calls[0]!.nativeId)) == some ("native-id", some "native-id")
def geminiResultId :=
  ((geminiRequest (cfg .gemini) "" #[] #[.toolResults #[{id := "native-id", name := "read", content := "ok", nativeId := some "native-id"}]]).getObjValAs? (Array Json) "contents").toOption.bind (·[0]?) |>.bind (fun j => (j.getObjValAs? (Array Json) "parts").toOption.bind (·[0]?)) |>.bind (fun j => (j.getObjVal? "functionResponse" >>= (·.getObjValAs? String "id")).toOption)
#guard geminiResultId == some "native-id"
#guard (openaiReply (pj "{\"choices\":[{\"message\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"prompt_tokens_details\":{\"cached_tokens\":3}}}")).toOption.isNone

end LodeTests.Model
