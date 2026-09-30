/-
  Lode.Model — calling a model, whichever API it speaks

  Two wire formats cover the providers typednotes connects (`connections.md`
  §3.1): **Anthropic's Messages API** (`anthropic`) and **OpenAI's Chat
  Completions** (`openai`, `mistral`, `openai-compatible` — and Scaleway's
  and Baseten's inference). Each is a pure pair — `…Request` builds the body
  from the provider-independent `Lode.Message`s, `…Reply` reads the answer
  back into a `Reply` (through derived `FromJson` shapes of the provider's
  answer) — so both are unit-tested without a network.

  A third API, `scripted`, replays a fixed list of replies. It exists for the
  end-to-end test (a real agent loop, a real repository, no model), and is
  accepted only in local mode.

  **Transport.** In production the model is a connection like any other, so
  the call goes through liaison with the connection's warrant (liaison adds
  the API key and any static header such as `anthropic-version`, and meters
  the call's `cost`). For development an operator may configure a direct
  endpoint and key (`LODE_MODEL_API_KEY`); that key never comes from a
  request.
-/
import Lean.Data.Json
import Lode.Message
import Lode.Liaison
import Lode.Http
import Lode.Validate
import Linen.Network.HTTP.Client.Retry
import Linen.Network.HTTP.Types.URI

namespace Lode.Model

open Lean (Json ToJson FromJson toJson fromJson?)

-- ── Configuration ───────────────────────────────────────────────────────────

/-- The wire format a model speaks. -/
inductive Api where
  | anthropic | openai | responses | gemini | pi | scripted
  deriving DecidableEq, Repr, Inhabited

def Api.toString : Api → String
  | .anthropic => "anthropic" | .openai => "openai" | .scripted => "scripted"
  | .responses => "responses" | .gemini => "gemini" | .pi => "pi"

/-- A tool, as the model is told about it. -/
structure ToolSpec where
  name : String
  description : String
  /-- A JSON Schema of the arguments object. -/
  schema : Json

/-- Which model, and how to talk to it. Persisted with the session (it holds
    no secret). -/
structure Config where
  api : Api
  /-- The provider's model id, e.g. `claude-sonnet-4-5`, `mistral-large-latest`. -/
  name : String
  /-- The API base, e.g. `https://api.anthropic.com/v1`; must lie under the
      connection's `base_url` when the call goes through liaison. -/
  baseUrl : String
  /-- The most tokens a reply may use. -/
  maxTokens : Nat := 8192
  /-- The context window, in tokens (compaction starts before it is full). -/
  contextWindow : Nat := 200000
  /-- The replies a `scripted` model plays, in order. -/
  script : Array Reply := #[]
  deriving Inhabited

/-- The default API base of a liaison provider. -/
def defaultBase? : String → Option String
  | "anthropic" => some "https://api.anthropic.com/v1"
  | "mistral" => some "https://api.mistral.ai/v1"
  | "openai" => some "https://api.openai.com/v1"
  | "gemini" => some "https://generativelanguage.googleapis.com/v1beta"
  | "radius" => some "https://radius.pi.dev/v1"
  | "meta" => some "https://api.meta.ai/v1"
  | "xai" => some "https://api.x.ai/v1"
  | "scaleway" => some "https://api.scaleway.ai/v1"
  | "minimax" => some "https://api.minimax.io/anthropic/v1"
  | "minimax-cn" => some "https://api.minimaxi.com/anthropic/v1"
  | "kimi-coding" => some "https://api.kimi.com/coding/v1"
  | _ => none

/-- The API a liaison provider speaks. -/
def apiOfProvider : String → Api
  | "anthropic" => .anthropic
  | "minimax" | "minimax-cn" | "kimi-coding" => .anthropic
  | "gemini" => .gemini
  | "radius" => .pi
  | "meta" | "xai" => .responses
  | _ => .openai

/-- The providers a model warrant may be for. -/
def providers : List String :=
  ["anthropic", "mistral", "openai", "openai-compatible", "ant-ling", "baseten",
   "cerebras", "deepseek", "fireworks", "github-copilot", "gemini", "groq",
   "huggingface", "kimi-coding", "meta", "minimax", "minimax-cn", "moonshotai",
   "moonshotai-cn", "nvidia", "opencode-go", "opencode", "openrouter",
   "qwen-token-plan", "qwen-token-plan-cn", "qwen-token-plan-individual", "radius",
   "scaleway", "together", "vercel-ai-gateway", "xiaomi", "xiaomi-token-plan-ams",
   "xiaomi-token-plan-cn", "xiaomi-token-plan-sgp", "zai-coding-cn", "zai", "xai"]

/-- Gateways route different model families to different native APIs. -/
def supportsApi (provider : String) (api : Api) : Bool :=
  if ["github-copilot", "opencode", "opencode-go"].contains provider then
    [.anthropic, .openai, .responses].contains api || (provider == "opencode" && api == .gemini)
  else if provider == "openai" then [.openai, .responses].contains api
   else providers.contains provider && api == apiOfProvider provider

private def usesResponses (model : String) : Bool :=
  ((model.drop 4).toString.splitOn "." |>.headD "" |>.splitOn "-" |>.headD "" |>.toNat?).any (· ≥ 5) && model.startsWith "gpt-" ||
    ["o1", "o3", "o4"].any (fun p => model.startsWith p)

/-- Mirrors the app catalog and broker routing. Gateways cannot silently select
    Chat Completions when the app selected another native protocol. -/
def apiForModel (provider model : String) : Api :=
  if ["opencode", "opencode-go"].contains provider then
    if provider == "opencode" && model == "qwen3.8-max" then .openai
    else if model.startsWith "claude-" || model.startsWith "qwen" ||
        (provider == "opencode-go" && model.startsWith "minimax-") then .anthropic
    else if provider == "opencode" && model.startsWith "gemini-" then .gemini
    else if usesResponses model || model.startsWith "grok-" || model.startsWith "muse-spark-" then .responses
    else .openai
  else if provider == "github-copilot" then
    if model.startsWith "claude-" then .anthropic
    else if model.startsWith "gpt-" && usesResponses model && !model.startsWith "gpt-5-mini" then .responses
    else .openai
  else if provider == "openai" && usesResponses model then .responses
  else apiOfProvider provider

def checkProtocol (provider : String) (cfg : Config) : Except String Unit := do
  unless providers.contains provider do throw s!"model: unknown provider '{provider}'"
  if provider == "opencode" && cfg.name.startsWith "jev-" then
    throw "model: classifiers cannot drive the code writer"
  unless cfg.api == apiForModel provider cfg.name do
    throw s!"model.api: '{provider}/{cfg.name}' requires {(apiForModel provider cfg.name).toString}"

/-- A tool call in a script: a name and arguments (an object, or its text). -/
structure ScriptCall where
  name : String
  arguments : Option Json := none
  deriving ToJson, FromJson

/-- One reply in a script. -/
structure ScriptReply where
  text : Option String := none
  calls : Option (Array ScriptCall) := none
  deriving ToJson, FromJson

/-- A model configuration as requests (and `session.json`) carry it; every
    field optional, completed by the provider and the server's default. -/
structure ConfigJson where
  api : Option String := none
  name : Option String := none
  baseUrl : Option String := none
  maxTokens : Option Nat := none
  contextWindow : Option Nat := none
  script : Option (Array ScriptReply) := none
  deriving ToJson, FromJson

/-- A script reply as the loop plays it. -/
def ScriptReply.toReply (r : ScriptReply) (i : Nat) : Reply :=
  let calls := (r.calls.getD #[]).zipIdx.map fun (c, k) =>
    { id := s!"call_{i}_{k}", name := c.name
      arguments := match c.arguments with
        | some (.str s) => s
        | some v => v.compress
        | none => "{}" : ToolCall }
  { text := r.text.getD "", calls, stop := if calls.isEmpty then "end_turn" else "tool_use" }

/-- The persisted form of a configuration. -/
def Config.toConfigJson (c : Config) : ConfigJson :=
  { api := some c.api.toString, name := some c.name, baseUrl := some c.baseUrl
    maxTokens := some c.maxTokens, contextWindow := some c.contextWindow
    script := if c.script.isEmpty then none else some (c.script.map fun r =>
      { text := some r.text, calls := some (r.calls.map fun c =>
          { name := c.name, arguments := some (.str c.arguments) }) }) }

instance : ToJson Config := ⟨fun c => toJson c.toConfigJson⟩

/-- Complete a configuration. `provider` is the model warrant's provider,
    when the call goes through liaison (it fixes the API and default base);
    `default` is the operator's configuration, whose fields a request may
    override. -/
def Config.ofConfigJson (j : ConfigJson) (provider : Option String) (default : Option Config)
    (allowLocal : Bool) : Except String Config := do
  let api ← match j.api with
    | some "anthropic" => pure (some Api.anthropic)
    | some "openai" => pure (some Api.openai)
    | some "responses" => pure (some Api.responses)
    | some "gemini" => pure (some Api.gemini)
    | some "pi" => pure (some Api.pi)
    | some "scripted" =>
      unless allowLocal do throw "model.api: 'scripted' is only accepted in local mode"
      pure (some Api.scripted)
    | some other => throw s!"model.api: unknown API '{other}' (anthropic, openai, responses, gemini, pi)"
    | none => pure none
  let requestedApi := api
  let api ← match api, provider, default with
    | some a, _, _ => pure a
    | none, some p, _ => pure (apiOfProvider p)
    | none, none, some d => pure d.api
    | none, none, none => throw "model.api: required (no model is configured on this server)"
  let name ← match j.name, default with
    | some n, _ => pure n
    | none, some d => pure d.name
    | none, none => if api == .scripted then pure "scripted" else throw "model.name: required"
  unless !name.isEmpty && name.length ≤ 256 && name.all (fun (c : Char) => c.toNat > 0x20 && c.toNat < 0x7f) do
    throw "model.name: must be a plain model id"
  let api := if requestedApi.isNone then (provider.map (apiForModel · name)).getD api else api
  let baseUrl ← match j.baseUrl, provider.bind defaultBase?, default with
    | some b, _, _ => pure b
    | none, some b, _ => pure b
    | none, none, some d => pure d.baseUrl
    | none, none, none =>
      if api == .scripted then pure "http://scripted" else throw "model.baseUrl: required for this provider"
  unless api == .scripted || Validate.baseUrl baseUrl allowLocal do
    throw "model.baseUrl: must be an https URL without query, fragment or trailing /"
  let maxTokens := j.maxTokens.getD ((default.map (·.maxTokens)).getD 8192)
  let contextWindow := j.contextWindow.getD
    ((default.map (·.contextWindow)).getD (if api == .anthropic then 200000 else 128000))
  unless maxTokens ≥ 256 && maxTokens ≤ 128000 do throw "model.maxTokens: between 256 and 128000"
  unless contextWindow ≥ 8000 do throw "model.contextWindow: at least 8000"
  let script := (j.script.getD #[]).zipIdx.map fun (r, i) => r.toReply i
  let cfg := { api, name, baseUrl, maxTokens, contextWindow, script : Config }
  if let some p := provider then checkProtocol p cfg
  return cfg

/-- Read a model configuration from a request's JSON. -/
def Config.parse (j : Json) (provider : Option String) (default : Option Config)
    (allowLocal : Bool) : Except String Config := do
  Config.ofConfigJson (← (fromJson? j).mapError ("model: " ++ ·)) provider default allowLocal

/-- Read back a persisted configuration (already validated when created). -/
def Config.ofJson (j : Json) : Except String Config :=
  Config.parse j none none true

instance : FromJson Config := ⟨Config.ofJson⟩

-- ── Anthropic Messages ──────────────────────────────────────────────────────

private def ephemeral : Json := Json.mkObj [("type", "ephemeral")]

/-- A tool call's input object (a malformed one is sent as `{}`: the tool's
    result already told the model its arguments did not parse). -/
private def inputObject (arguments : String) : Json :=
  match Json.parse arguments with
  | .ok (.obj kvs) => .obj kvs
  | _ => Json.mkObj []

private def nonEmpty (s : String) (dflt : String) : String := if s.trimAscii.isEmpty then dflt else s

private def textBlock (text : String) : Json := Json.mkObj [("type", "text"), ("text", text)]

private def replayItems (replay : NativeReplay) : Array Json :=
  replay.items.filterMap (fun item => (Json.parse item).toOption)

private def anthropicPlain : Message → Json
  | .user text => Json.mkObj [("role", "user"), ("content", Json.arr #[textBlock (nonEmpty text "(empty)")])]
  | .assistant text calls | .assistantReplay text calls _ =>
    let textBlocks := if text.trimAscii.isEmpty then #[] else #[textBlock text]
    let useBlocks := calls.map fun c => Json.mkObj
      [("type", "tool_use"), ("id", c.id), ("name", c.name), ("input", inputObject c.arguments)]
    let blocks := textBlocks ++ useBlocks
    Json.mkObj [("role", "assistant"),
      ("content", Json.arr (if blocks.isEmpty then #[textBlock "(empty)"] else blocks))]
  | .toolResults rs => Json.mkObj [("role", "user"), ("content", Json.arr (rs.map fun r => Json.mkObj
      [ ("type", "tool_result"), ("tool_use_id", r.id), ("content", nonEmpty r.content "(no output)")
       , ("is_error", toJson r.isError) ]))]

private def anthropicMessage (m : Message) : Json :=
  match m with
  | .assistantReplay _ _ replay =>
    if replay.api == "anthropic" then Json.mkObj [("role", "assistant"), ("content", Json.arr (replayItems replay))]
    else anthropicPlain m
  | _ => anthropicPlain m

/-- Mark the last block of the last message as a cache breakpoint, so each
    step of a run re-reads the conversation so far from the prompt cache. -/
private def cacheLast (msgs : Array Json) : Array Json :=
  match msgs.back? with
  | none => msgs
  | some m =>
    match m.getObjValAs? (Array Json) "content" with
    | .ok blocks =>
      match blocks.back? with
      | some b => msgs.pop.push (m.setObjVal! "content"
          (Json.arr (blocks.pop.push (b.setObjVal! "cache_control" ephemeral))))
      | none => msgs
    | .error _ => msgs

/-- A tool as Anthropic describes it. -/
private structure AnthropicTool where
  name : String
  description : String
  input_schema : Json
  deriving ToJson

/-- The body of `POST {base}/messages`. -/
def anthropicRequest (cfg : Config) (system : String) (tools : Array ToolSpec)
    (msgs : Array Message) : Json :=
  Json.mkObj <|
    [ ("model", Json.str cfg.name), ("max_tokens", toJson cfg.maxTokens)
     , ("system", if cfg.baseUrl == "https://api.anthropic.com/v1" then
         Json.arr #[(textBlock system).setObjVal! "cache_control" ephemeral] else Json.str system) ] ++
    Json.opt "tools" (if tools.isEmpty then none else some (tools.map fun t =>
      ({ name := t.name, description := t.description, input_schema := t.schema } : AnthropicTool))) ++
    [("messages", Json.arr (if cfg.baseUrl == "https://api.anthropic.com/v1" then
      cacheLast (msgs.map anthropicMessage) else msgs.map anthropicMessage))]

/-- A content block of a Messages answer. -/
private structure AnthropicBlock where
  type : String
  text : Option String := none
  id : Option String := none
  name : Option String := none
  input : Option Json := none
  deriving FromJson

/-- The usage of a Messages answer. -/
private structure AnthropicUsage where
  input_tokens : Option Nat := none
  output_tokens : Option Nat := none
  cache_read_input_tokens : Option Nat := none
  cache_creation_input_tokens : Option Nat := none
  deriving FromJson

/-- A Messages answer. -/
private structure AnthropicAnswer where
  content : Array Json
  stop_reason : Option String := none
  usage : Option AnthropicUsage := none
  deriving FromJson

/-- An error answer, from either API: `{"error": {"message": …}}`. -/
private structure ApiErrorBody where
  message : Option String := none
  deriving FromJson

/-- Refuse an error answer. -/
private def checkError (j : Json) : Except String Unit :=
  match j.getObjVal? "error" with
  | .ok e =>
    let msg := match (fromJson? e : Except String ApiErrorBody) with
      | .ok { message := some m } => m
      | _ => e.compress
    throw s!"the model API answered with an error: {msg}"
  | .error _ => pure ()

/-- Read a Messages API answer. -/
def anthropicReply (j : Json) : Except String Reply := do
  checkError j
  let a : AnthropicAnswer ← (fromJson? j).mapError ("the model's answer: " ++ ·)
  let mut texts : Array String := #[]
  let mut calls : Array ToolCall := #[]
  for raw in a.content do
    let b : AnthropicBlock ← fromJson? raw
    match b.type with
    | "text" => texts := texts.push (← raw.getObjValAs? String "text")
    | "tool_use" =>
      let id ← raw.getObjValAs? String "id"
      let name ← raw.getObjValAs? String "name"
      let input ← raw.getObjVal? "input"
      unless !id.isEmpty && !name.isEmpty && input.getObj?.isOk do throw "malformed Anthropic tool call"
      calls := calls.push { id, name, arguments := input.compress }
    | "thinking" =>
      let _ ← raw.getObjValAs? String "thinking"
      let _ ← raw.getObjValAs? String "signature"
    | "redacted_thinking" => let _ ← raw.getObjValAs? String "data"
    | _ => throw s!"unsupported Anthropic output block '{b.type}'"
  let stop := a.stop_reason.getD ""
  unless ["end_turn", "tool_use", "max_tokens", "stop_sequence", "pause_turn", "refusal"].contains stop do
    throw "Anthropic returned no recognized terminal stop reason"
  unless (stop == "tool_use") == !calls.isEmpty || stop == "max_tokens" do throw "Anthropic tool/stop mismatch"
  if stop == "max_tokens" && !calls.isEmpty then throw "Anthropic truncated a tool call; refusing partial execution"
  if stop == "refusal" || stop == "pause_turn" then throw s!"Anthropic stopped with '{stop}'"
  unless !texts.isEmpty || !calls.isEmpty || stop == "max_tokens" do throw "Anthropic returned an empty answer"
  unless (calls.map (·.id)).toList.eraseDups.length == calls.size do throw "duplicate Anthropic tool ids"
  let u := a.usage.getD {}
  return { text := "\n".intercalate texts.toList, calls, stop
           replay := if a.content.any (fun b => (b.getObjValAs? String "type").toOption == some "thinking" ||
             (b.getObjValAs? String "type").toOption == some "redacted_thinking") then
             some { api := "anthropic", items := a.content.map Json.compress } else none
           usage := { input := u.input_tokens.getD 0, output := u.output_tokens.getD 0
                      cacheRead := u.cache_read_input_tokens.getD 0
                      cacheWrite := u.cache_creation_input_tokens.getD 0 } }

-- ── OpenAI Chat Completions ─────────────────────────────────────────────────

private def openaiPlain : Message → Array Json
  | .user text => #[Json.mkObj [("role", "user"), ("content", nonEmpty text "(empty)")]]
  | .assistant text calls | .assistantReplay text calls _ =>
    #[Json.mkObj <|
      [ ("role", Json.str "assistant")
      , ("content", if text.isEmpty && !calls.isEmpty then Json.null else Json.str text) ] ++
      Json.opt "reasoning_content" (calls.findSome? (·.signature)) ++
      Json.opt "tool_calls" (if calls.isEmpty then none else some (calls.map fun c => Json.mkObj
          [ ("id", c.id), ("type", "function")
          , ("function", Json.mkObj [("name", c.name), ("arguments", c.arguments)]) ]))]
  | .toolResults rs => rs.map fun r => Json.mkObj
      [("role", "tool"), ("tool_call_id", r.id), ("content", nonEmpty r.content "(no output)")]

private def openaiMessages (m : Message) : Array Json :=
  match m with
  | .assistantReplay _ _ replay => if replay.api == "openai" then replayItems replay else openaiPlain m
  | _ => openaiPlain m

/-- The body of `POST {base}/chat/completions`. -/
def openaiRequest (cfg : Config) (system : String) (tools : Array ToolSpec)
    (msgs : Array Message) : Json :=
  Json.mkObj <|
    [ ("model", Json.str cfg.name), (if usesResponses cfg.name then "max_completion_tokens" else "max_tokens", toJson cfg.maxTokens)
    , ("messages", Json.arr (#[Json.mkObj [("role", "system"), ("content", system)]] ++
        msgs.flatMap openaiMessages)) ] ++
    Json.opt "tools" (if tools.isEmpty then none else some (tools.map fun t => Json.mkObj
        [ ("type", "function")
        , ("function", Json.mkObj [("name", t.name), ("description", t.description),
                                   ("parameters", t.schema)]) ]))

/-- The function of a Chat Completions tool call; `arguments` is JSON text
    (some compatible servers send an object). -/
private structure OpenAIFunction where
  name : Option String := none
  arguments : Option Json := none
  deriving FromJson

private structure OpenAIToolCall where
  id : Option String := none
  function : OpenAIFunction
  deriving FromJson

private structure OpenAIMessage where
  content : Option String := none
  tool_calls : Option (Array OpenAIToolCall) := none
  reasoning_content : Option String := none
  deriving FromJson

private structure OpenAIChoice where
  message : OpenAIMessage
  finish_reason : Option String := none
  deriving FromJson

private structure OpenAIPromptDetails where
  cached_tokens : Option Nat := none
  deriving FromJson

private structure OpenAIUsage where
  prompt_tokens : Option Nat := none
  completion_tokens : Option Nat := none
  prompt_tokens_details : Option OpenAIPromptDetails := none
  deriving FromJson

private structure OpenAIAnswer where
  choices : Array OpenAIChoice
  usage : Option OpenAIUsage := none
  deriving FromJson

/-- Read a Chat Completions answer. -/
def openaiReply (j : Json) : Except String Reply := do
  checkError j
  let a : OpenAIAnswer ← (fromJson? j).mapError ("the model's answer: " ++ ·)
  let some choice := a.choices[0]? | throw "the model's answer has no choices"
  let calls := (choice.message.tool_calls.getD #[]).map fun c =>
    { id := c.id.getD "", name := c.function.name.getD ""
      arguments := match c.function.arguments with
         | some (.str s) => s
         | some v => v.compress
         | none => ""
      signature := choice.message.reasoning_content : ToolCall }
  unless calls.all (fun c => !c.id.isEmpty && !c.name.isEmpty && !c.arguments.isEmpty) do
    throw "malformed OpenAI tool call"
  unless (calls.map (·.id)).toList.eraseDups.length == calls.size do throw "duplicate OpenAI tool ids"
  let stop := choice.finish_reason.getD ""
  unless ["stop", "length", "tool_calls", "content_filter"].contains stop do
    throw "OpenAI returned no recognized terminal finish reason"
  if stop == "content_filter" then throw "OpenAI filtered the answer"
  unless (stop == "tool_calls") == !calls.isEmpty || stop == "length" do throw "OpenAI tool/stop mismatch"
  if stop == "length" && !calls.isEmpty then throw "OpenAI truncated a tool call; refusing partial execution"
  unless !(choice.message.content.getD "").isEmpty || !calls.isEmpty || stop == "length" do
    throw "OpenAI returned an empty answer"
  let u := a.usage.getD {}
  unless (u.prompt_tokens_details.bind (·.cached_tokens)).getD 0 ≤ u.prompt_tokens.getD 0 do
    throw "OpenAI reported more cached tokens than input tokens"
  let replay := if choice.message.reasoning_content.isSome then
    some { api := "openai", items := ((openaiPlain (.assistant (choice.message.content.getD "") calls)).map
      (fun m => (m.setObjVal! "reasoning_content" (toJson choice.message.reasoning_content)).compress)) : NativeReplay } else none
  return {
    text := choice.message.content.getD "", calls, stop, replay
    usage := {
      input := u.prompt_tokens.getD 0 - (u.prompt_tokens_details.bind (·.cached_tokens)).getD 0
      output := u.completion_tokens.getD 0
      cacheRead := (u.prompt_tokens_details.bind (·.cached_tokens)).getD 0 } }

-- ── Native Responses, Gemini and Pi gateway protocols ────────────────────────

private def object (j : Json) (key : String) : Json := (j.getObjVal? key).toOption.getD Json.null
private def text (j : Json) (key : String) : String := (j.getObjValAs? String key).toOption.getD ""
private def number (j : Json) (key : String) : Nat := (j.getObjValAs? Nat key).toOption.getD 0
private def array (j : Json) (key : String) : Array Json := (j.getObjValAs? (Array Json) key).toOption.getD #[]
private def arguments (c : ToolCall) : Json := (Json.parse c.arguments).toOption.getD (Json.mkObj [])

private structure ResponsesUsage where
  input_tokens : Nat := 0
  output_tokens : Nat := 0
  input_tokens_details : Option OpenAIPromptDetails := none
  deriving FromJson

private structure ResponsesCounters where
  usage : Option ResponsesUsage := none
  deriving FromJson

private structure GeminiUsage where
  promptTokenCount : Option Nat := none
  candidatesTokenCount : Option Nat := none
  thoughtsTokenCount : Option Nat := none
  cachedContentTokenCount : Option Nat := none
  deriving FromJson

private structure GeminiCounters where
  usageMetadata : Option GeminiUsage := none
  deriving FromJson

private structure PiUsage where
  input : Nat
  output : Nat
  cacheRead : Option Nat := none
  cacheWrite : Option Nat := none
  deriving FromJson

private def responsesPlain : Message → Array Json
  | .user s => #[Json.mkObj [("role", "user"), ("content", s)]]
  | .assistant s cs | .assistantReplay s cs _ =>
    (if s.isEmpty then #[] else #[Json.mkObj [("role", "assistant"), ("content", s)]]) ++
    cs.map (fun c => Json.mkObj [("type", "function_call"), ("call_id", c.id),
      ("name", c.name), ("arguments", c.arguments)])
  | .toolResults rs => rs.map fun r => Json.mkObj [("type", "function_call_output"),
      ("call_id", r.id), ("output", r.content)]

private def responsesInput (m : Message) : Array Json :=
  match m with
  | .assistantReplay _ _ replay => if replay.api == "responses" then replayItems replay else responsesPlain m
  | _ => responsesPlain m

/-- Stateless Responses requests carry the full conversation and tool results. -/
def responsesRequest (cfg : Config) (system : String) (tools : Array ToolSpec) (msgs : Array Message) : Json :=
  Json.mkObj <| [("model", Json.str cfg.name), ("instructions", Json.str system), ("max_output_tokens", toJson cfg.maxTokens),
    ("store", toJson false), ("include", toJson #["reasoning.encrypted_content"]),
    ("input", Json.arr (msgs.flatMap responsesInput))] ++
    Json.opt "tools" (if tools.isEmpty then none else some (tools.map fun t => Json.mkObj
      [("type", "function"), ("name", t.name), ("description", t.description), ("parameters", t.schema),
       ("strict", toJson false)]))

def responsesReply (j : Json) : Except String Reply := do
  checkError j
  let status ← j.getObjValAs? String "status"
  let stop ← match status with
    | "completed" => pure "completed"
    | "incomplete" =>
      unless text (object j "incomplete_details") "reason" == "max_output_tokens" do
        throw "Responses returned an incomplete or filtered answer"
      pure "max_tokens"
    | _ => throw s!"Responses returned nonterminal/failed status '{status}'"
  let output ← j.getObjValAs? (Array Json) "output"
  let mut texts : Array String := #[]
  let mut calls : Array ToolCall := #[]
  for item in output do
    match ← item.getObjValAs? String "type" with
    | "message" =>
      for part in ← item.getObjValAs? (Array Json) "content" do
        match ← part.getObjValAs? String "type" with
        | "output_text" => texts := texts.push (← part.getObjValAs? String "text")
        | "refusal" => throw s!"Responses refused: {text part "refusal"}"
        | _ => throw "Responses returned unsupported message content"
    | "function_call" =>
      if text item "status" == "incomplete" || stop == "max_tokens" then
        throw "Responses truncated a function call; refusing partial execution"
      let id ← item.getObjValAs? String "call_id"
      let name ← item.getObjValAs? String "name"
      let args ← item.getObjValAs? String "arguments"
      unless !id.isEmpty && !name.isEmpty && !args.isEmpty do throw "malformed Responses tool call"
      calls := calls.push { id, name, arguments := args }
    | "reasoning" =>
      let _ ← item.getObjValAs? (Array Json) "summary"
      unless !(text item "encrypted_content").isEmpty do
        throw "Responses omitted encrypted reasoning needed for stateless replay"
    | other => throw s!"unsupported Responses output item '{other}'"
  unless (calls.map (·.id)).toList.eraseDups.length == calls.size do throw "duplicate Responses tool ids"
  unless !texts.isEmpty || !calls.isEmpty || stop == "max_tokens" do throw "Responses returned an empty answer"
  let usage := (← fromJson? j : ResponsesCounters).usage.getD {}
  let cached := (usage.input_tokens_details.bind (·.cached_tokens)).getD 0
  unless cached ≤ usage.input_tokens do throw "Responses reported inconsistent cached usage"
  return {
    text := "\n".intercalate texts.toList
    calls := calls
    stop := stop
    replay := if output.any (fun item => text item "type" == "reasoning") then
      some { api := "responses", items := output.map Json.compress } else none
    usage := { input := usage.input_tokens - cached, output := usage.output_tokens, cacheRead := cached }
  }

private def geminiResult (r : ToolResult) : Json :=
  let response := Json.mkObj <| [("name", Json.str r.name),
    ("response", Json.mkObj [("content", r.content), ("isError", toJson r.isError)])] ++ Json.opt "id" r.nativeId
  Json.mkObj [("functionResponse", response)]

private def geminiPlain : Message → Json
  | .user s => Json.mkObj [("role", "user"), ("parts", Json.arr #[Json.mkObj [("text", s)]])]
  | .assistant s cs | .assistantReplay s cs _ => Json.mkObj [("role", "model"), ("parts", Json.arr
      ((if s.isEmpty then #[] else #[Json.mkObj [("text", s)]]) ++ cs.map (fun c => Json.mkObj <|
        [("functionCall", Json.mkObj [("name", c.name), ("args", arguments c)])] ++ Json.opt "thoughtSignature" c.signature)))]
  | .toolResults rs => Json.mkObj [("role", "user"), ("parts", Json.arr (rs.map geminiResult))]

private def geminiContent (m : Message) : Json :=
  match m with
  | .assistantReplay _ _ replay =>
    if replay.api == "gemini" then Json.mkObj [("role", "model"), ("parts", Json.arr (replayItems replay))]
    else geminiPlain m
  | _ => geminiPlain m

def geminiRequest (cfg : Config) (system : String) (tools : Array ToolSpec) (msgs : Array Message) : Json :=
  Json.mkObj <| [("systemInstruction", Json.mkObj [("parts", Json.arr #[Json.mkObj [("text", system)]])]),
    ("contents", Json.arr (msgs.map geminiContent)),
    ("generationConfig", Json.mkObj [("maxOutputTokens", toJson cfg.maxTokens)])] ++
    Json.opt "tools" (if tools.isEmpty then none else some #[Json.mkObj [("functionDeclarations", Json.arr (tools.map fun t => Json.mkObj
      [("name", t.name), ("description", t.description), ("parameters", t.schema)]))]])

def geminiReply (j : Json) : Except String Reply := do
  checkError j
  let some candidate := (array j "candidates")[0]? | throw "Gemini returned no candidate"
  let reason ← candidate.getObjValAs? String "finishReason"
  unless reason == "STOP" || reason == "MAX_TOKENS" do throw s!"Gemini returned blocked/unsupported finish reason '{reason}'"
  let parts ← (← candidate.getObjVal? "content").getObjValAs? (Array Json) "parts"
  let mut texts : Array String := #[]
  let mut calls : Array ToolCall := #[]
  for part in parts do
    if (part.getObjVal? "thoughtSignature").isOk then let _ ← part.getObjValAs? String "thoughtSignature"
    if (part.getObjVal? "thought").isOk then let _ ← part.getObjValAs? Bool "thought"
    if (part.getObjVal? "text").isOk then
      let content ← part.getObjValAs? String "text"
      if (part.getObjValAs? Bool "thought").toOption != some true then texts := texts.push content
    if let .ok call := part.getObjVal? "functionCall" then
      if reason == "MAX_TOKENS" then throw "Gemini truncated a function call; refusing partial execution"
      let name ← call.getObjValAs? String "name"
      let args ← call.getObjVal? "args"
      unless !name.isEmpty && args.getObj?.isOk do throw "malformed Gemini function call"
      calls := calls.push {
        id := (call.getObjValAs? String "id").toOption.getD s!"call_{calls.size}"
        name := name
        arguments := args.compress
        signature := (part.getObjValAs? String "thoughtSignature").toOption
        nativeId := (call.getObjValAs? String "id").toOption
      }
    unless (part.getObjVal? "text").isOk || (part.getObjVal? "functionCall").isOk do
      throw "Gemini returned unsupported/malformed content"
  unless calls.all (fun c => !c.id.isEmpty) && (calls.map (·.id)).toList.eraseDups.length == calls.size do
    throw "malformed or duplicate Gemini function ids"
  unless !texts.isEmpty || !calls.isEmpty || reason == "MAX_TOKENS" do throw "Gemini returned an empty answer"
  let usage := (← fromJson? j : GeminiCounters).usageMetadata.getD {}
  let cached := usage.cachedContentTokenCount.getD 0
  unless cached ≤ usage.promptTokenCount.getD 0 do throw "Gemini reported inconsistent cached usage"
  return {
    text := "\n".intercalate texts.toList
    calls := calls
    stop := if reason == "MAX_TOKENS" then "max_tokens" else "STOP"
    replay := if parts.any (fun part => (part.getObjVal? "thoughtSignature").isOk) then
      some { api := "gemini", items := parts.map Json.compress } else none
    usage := {
      input := usage.promptTokenCount.getD 0 - cached
      output := usage.candidatesTokenCount.getD 0 + usage.thoughtsTokenCount.getD 0
      cacheRead := cached
    }
  }

private def piPlain (cfg : Config) : Message → Array Json
  | .user s => #[Json.mkObj [("role", "user"), ("content", s), ("timestamp", toJson (0 : Nat))]]
  | .assistant s cs | .assistantReplay s cs _ => #[Json.mkObj [("role", "assistant"), ("api", "pi-messages"), ("provider", "radius"),
      ("model", cfg.name), ("timestamp", toJson (0 : Nat)), ("stopReason", if cs.isEmpty then "stop" else "toolUse"),
      ("usage", Json.mkObj [("input", toJson (0 : Nat)), ("output", toJson (0 : Nat)), ("cacheRead", toJson (0 : Nat)),
        ("cacheWrite", toJson (0 : Nat)), ("totalTokens", toJson (0 : Nat)),
        ("cost", Json.mkObj [("input", toJson (0 : Nat)), ("output", toJson (0 : Nat)),
          ("cacheRead", toJson (0 : Nat)), ("cacheWrite", toJson (0 : Nat)), ("total", toJson (0 : Nat))])]),
      ("content", Json.arr ((if s.isEmpty then #[] else #[Json.mkObj [("type", "text"), ("text", s)]]) ++
        cs.map (fun c => Json.mkObj [("type", "toolCall"), ("id", c.id), ("name", c.name), ("arguments", arguments c)])))]]
  | .toolResults rs => rs.map fun r => Json.mkObj [("role", "toolResult"), ("toolCallId", r.id),
      ("toolName", r.name), ("isError", toJson r.isError), ("timestamp", toJson (0 : Nat)),
      ("content", Json.arr #[Json.mkObj [("type", "text"), ("text", r.content)]])]

private def piContent (cfg : Config) (m : Message) : Array Json :=
  match m with
  | .assistantReplay _ _ replay => if replay.api == "pi" then replayItems replay else piPlain cfg m
  | _ => piPlain cfg m

def piRequest (cfg : Config) (system : String) (tools : Array ToolSpec) (msgs : Array Message)
    (sessionId : String := "direct-development") : Json :=
  Json.mkObj [("model", cfg.name), ("options", Json.mkObj [("maxTokens", toJson cfg.maxTokens), ("sessionId", sessionId)]),
    ("context", Json.mkObj [("messages", Json.arr (#[Json.mkObj [("role", "system"), ("content", system),
      ("timestamp", toJson (0 : Nat)),
      ("toolsAdded", Json.arr (tools.map fun t => Json.mkObj [("name", t.name), ("description", t.description), ("parameters", t.schema)]))]] ++
      msgs.flatMap (piContent cfg)))])]

/-- Radius uses SSE, buffered by the broker. A terminal event is mandatory;
    incomplete streams and explicit error events are never successful replies. -/
def piReply (body : String) (cfg : Option Config := none) : Except String Reply := do
  let mut texts : Std.TreeMap Nat String := {}
  let mut blocks : Std.TreeMap Nat Json := {}
  let mut pending : List Nat := []
  let mut calls : Array ToolCall := #[]
  let mut usage : Usage := {}
  let mut reason : Option String := none
  for line in (body.replace "\r\n" "\n").splitOn "\n" do
    if line.startsWith "data:" then
      let value := (line.drop 5).toString.trimAscii.copy
      if value.isEmpty || value == "[DONE]" then continue
      let j ← Json.parse value
      if reason.isSome then throw "Radius sent data after its terminal event"
      let kind ← j.getObjValAs? String "type"
      let index ← if ["start", "done", "error"].contains kind then pure 0 else j.getObjValAs? Nat "contentIndex"
      unless index < 4096 do throw "Radius content index is out of bounds"
      match text j "type" with
      | "start" => pure ()
      | "text_start" | "thinking_start" | "toolcall_start" => pending := index :: pending
      | "text_delta" =>
        texts := texts.insert index (texts.getD index "" ++ (← j.getObjValAs? String "delta"))
        pending := index :: pending
      | "text_end" =>
        let content ← j.getObjValAs? String "content"
        texts := texts.insert index content
        blocks := blocks.insert index (Json.mkObj <| [("type", Json.str "text"), ("text", Json.str content)] ++
          Json.opt "textSignature" (j.getObjValAs? String "contentSignature").toOption)
        pending := pending.filter (· != index)
      | "thinking_delta" | "toolcall_delta" =>
        let _ ← j.getObjValAs? String "delta"
        pending := index :: pending
      | "thinking_end" =>
        let content ← j.getObjValAs? String "content"
        blocks := blocks.insert index (Json.mkObj <| [("type", Json.str "thinking"), ("thinking", Json.str content)] ++
          Json.opt "thinkingSignature" (j.getObjValAs? String "contentSignature").toOption ++
          Json.opt "redacted" (j.getObjValAs? Bool "redacted").toOption)
        pending := pending.filter (· != index)
      | "toolcall_end" =>
        let call ← j.getObjVal? "toolCall"
        let id ← call.getObjValAs? String "id"
        let name ← call.getObjValAs? String "name"
        let args ← call.getObjVal? "arguments"
        unless !id.isEmpty && !name.isEmpty && args.getObj?.isOk do throw "malformed Radius tool call"
        calls := calls.push { id, name, arguments := args.compress }
        blocks := blocks.insert index call
        pending := pending.filter (· != index)
      | "error" => throw s!"Radius: {text j "errorMessage"}"
      | "done" =>
        unless pending.isEmpty do throw "Radius terminated with incomplete content/tool blocks"
        let stop ← j.getObjValAs? String "reason"
        unless ["stop", "length", "toolUse"].contains stop do throw "Radius returned an unknown terminal reason"
        reason := some stop
        let u : PiUsage ← fromJson? (← j.getObjVal? "usage")
        usage := {
          input := u.input
          output := u.output
          cacheRead := u.cacheRead.getD 0
          cacheWrite := u.cacheWrite.getD 0
        }
      | other => throw s!"unsupported Radius event '{other}'"
  let some stop := reason | throw "Radius stream ended without a terminal event"
  unless (stop == "toolUse") == !calls.isEmpty do throw "Radius tool/stop mismatch"
  unless (calls.map (·.id)).toList.eraseDups.length == calls.size do throw "duplicate Radius tool ids"
  unless !texts.isEmpty || !calls.isEmpty || stop == "length" do throw "Radius returned an empty answer"
  let replay := cfg.map fun config =>
    let message := (piPlain config (.assistant "" #[]))[0]!
    { api := "pi", items := #[(message.setObjVal! "content" (Json.arr (blocks.toList.map (·.2)).toArray)
      |>.setObjVal! "stopReason" (Json.str stop)).compress] : NativeReplay }
  return {
    text := "\n".intercalate (texts.toList.map (·.2))
    calls := calls
    usage := usage
    replay := replay
    stop := if stop == "toolUse" then "tool_use" else if stop == "length" then "max_tokens" else "end_turn"
  }

-- ── Calling ─────────────────────────────────────────────────────────────────

/-- How a call reaches the model. -/
inductive Transport where
  /-- Through liaison, with the model connection's warrant. -/
  | liaison (url : String) (creds : Liaison.Credentials)
  /-- Directly, with an operator-configured key (development). -/
  | direct (apiKey : String)
  /-- No network (the `scripted` API). -/
  | none

/-- How model calls are retried: linen's policy, with delays for a model
    API — four attempts, backoff from 2 s (jittered), a server's
    `Retry-After` followed up to a minute. -/
def retryPolicy : Network.HTTP.Client.RetryPolicy :=
  { maxAttempts := 4, baseDelayMillis := 2000, maxDelayMillis := 60000 }

/-- An HTTP status worth retrying (linen's default: `408`, `429`, `5xx` —
    Anthropic's `529 overloaded` included). -/
def retryable (status : Nat) : Bool := retryPolicy.retryStatus status

/-- A failed call, whether trying again may help, and after how long the
    server asked to be retried (`Retry-After`, in milliseconds). -/
structure Failure where
  message : String
  retry : Bool
  retryAfterMs : Option Nat := none

/-- One attempt: the request body is sent, the answer read. -/
private def attempt (cfg : Config) (t : Transport) (body : Json) (context : Liaison.NativeContext) (timeoutMs : Nat) :
    IO (Except Failure Reply) := do
  let path := match cfg.api with
    | .anthropic | .pi => "/messages"
    | .responses => "/responses"
    | .gemini =>
      let name := if cfg.name.startsWith "models/" then (cfg.name.drop 7).toString else cfg.name
      "/models/" ++ Network.HTTP.Types.urlEncode name ++ ":generateContent"
    | _ => "/chat/completions"
  let url := cfg.baseUrl ++ path
  let answer : Except Failure (Nat × String × Option Nat) ← try
      match t with
      | .liaison base creds =>
        let _ ← IO.ofExcept ((checkProtocol creds.provider cfg).mapError IO.userError)
        let fields ← IO.ofExcept ((body.getObj?).mapError IO.userError)
        -- The selector fixes the model. The broker derives auth/URL and decides
        -- which inline local function tools the operation supports.
        let payload := Json.mkObj (fields.toList.filter (fun pair => pair.1 != "model"))
        let model := if cfg.api == .gemini && cfg.name.startsWith "models/" then (cfg.name.drop 7).toString else cfg.name
        let u ← Liaison.inference base creds model payload context timeoutMs
        -- The provider's answer, relayed by liaison with its headers.
        pure (.ok (u.status.toNat, Liaison.text u,
          (u.header? "retry-after").bind Network.HTTP.Client.parseRetryAfterMillis))
      | .direct key =>
        let auth := if cfg.api == .anthropic then [("x-api-key", key), ("anthropic-version", "2023-06-01")]
          else if cfg.api == .gemini then [("x-goog-api-key", key)]
          else [("authorization", s!"Bearer {key}")]
        let a ← Http.request .POST url ([("content-type", "application/json")] ++ auth)
          (some body.compress) timeoutMs
        pure (.ok (Http.status a, Http.text a, Network.HTTP.Client.retryAfterMillis a))
      | .none => pure (.error { message := "no transport for this model", retry := false })
    catch e => pure (.error { message := toString e, retry := !(toString e).startsWith "liaison refused" })
  match answer with
  | .error f => return .error f
  | .ok (status, text, retryAfterMs) =>
    if status != 200 then
      let snippet := if text.length > 1000 then (text.take 1000).toString ++ "…" else text
      return .error { message := s!"the model API answered {status}: {snippet}", retry := retryable status,
                      retryAfterMs }
    if cfg.api == .pi then
      return (piReply text (some cfg)).mapError fun m => { message := m, retry := false }
    match Json.parse text with
    | .error e => return .error { message := s!"the model's answer is not JSON: {e}", retry := true }
    | .ok j =>
      let r := match cfg.api with
        | .anthropic => anthropicReply j
        | .responses => responsesReply j
        | .gemini => geminiReply j
        | _ => openaiReply j
      return r.mapError fun m => { message := m, retry := false }

/-- Sleep `ms` milliseconds in short slices, returning early (with `true`)
    once `abort` is set. -/
private def sleepUnlessAborted (ms : Nat) (abort : IO.Ref Bool) : IO Bool := do
  for _ in [0:(ms + 199) / 200] do
    if ← abort.get then return true
    IO.sleep 200
  abort.get

/-- Retired or never-authorized tool exchanges cannot be replayed under a new
    broker allowlist. Recover after the last such complete exchange, retaining
    the user's task but never reintroducing the function definition/result IDs.
    Fully permitted signed/reasoning replay remains byte-for-byte intact. -/
def boundedHistory (tools : Array ToolSpec) (msgs : Array Message) : Array Message := Id.run do
  let allowed := tools.map (·.name)
  let mut cut := 0
  for i in [0:msgs.size] do
    let calls := match msgs[i]! with
      | .assistant _ calls | .assistantReplay _ calls _ => calls
      | _ => #[]
    if calls.any (fun call => !allowed.contains call.name) then cut := i + 1
  if cut == 0 then return msgs
  while cut < msgs.size do
    match msgs[cut]! with
    | .toolResults _ => cut := cut + 1
    | _ => break
  let task := ((msgs.extract 0 cut).toList.reverse.findSome? fun message => match message with
    | .user text => some text | _ => none).getD "Continue the current notebook task."
  return #[.user ("Earlier local tool exchanges were denied or retired by the current permission bounds and have been removed from replay. Continue within the current tools. Last user task: " ++ task)] ++ msgs.extract cut msgs.size

/-- Ask the model for its next message, using only currently authorized tool
    replay. Retry transient failures with the existing bounded retry policy. -/
def complete (cfg : Config) (t : Transport) (system : String) (tools : Array ToolSpec)
    (msgs : Array Message) (step : Nat) (timeoutMs : Nat) (abort : IO.Ref Bool)
    (sessionId : String := "direct-development") (initiator : Option String := none) : IO Reply := do
  if cfg.api == .scripted then
    return (cfg.script[step]?).getD { text := "(the script is exhausted)", calls := #[], stop := "end_turn" }
  let actualInitiator := initiator.getD (match msgs[msgs.size - 1]? with | some (.user _) => "user" | _ => "agent")
  let msgs := boundedHistory tools msgs
  let body := match cfg.api with
    | .anthropic => anthropicRequest cfg system tools msgs
    | .responses => responsesRequest cfg system tools msgs
    | .gemini => geminiRequest cfg system tools msgs
    | .pi => piRequest cfg system tools msgs sessionId
    | _ => openaiRequest cfg system tools msgs
  let mut last := ""
  let context : Liaison.NativeContext :=
    { sessionId := sessionId
      initiator := actualInitiator }
  for n in [1:retryPolicy.maxAttempts + 1] do
    match ← attempt cfg t body context timeoutMs with
    | .ok r => return r
    | .error f =>
      last := f.message
      unless f.retry && n < retryPolicy.maxAttempts do break
      let delay ← Network.HTTP.Client.delayFor retryPolicy n f.retryAfterMs
      if ← sleepUnlessAborted delay abort then throw (IO.userError "aborted")
  throw (IO.userError last)

end Lode.Model
