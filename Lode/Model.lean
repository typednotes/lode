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

namespace Lode.Model

open Lean (Json ToJson FromJson toJson fromJson?)

-- ── Configuration ───────────────────────────────────────────────────────────

/-- The wire format a model speaks. -/
inductive Api where
  | anthropic | openai | scripted
  deriving DecidableEq, Repr, Inhabited

def Api.toString : Api → String
  | .anthropic => "anthropic" | .openai => "openai" | .scripted => "scripted"

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
  | _ => none

/-- The API a liaison provider speaks. -/
def apiOfProvider : String → Api
  | "anthropic" => .anthropic
  | _ => .openai

/-- The providers a model warrant may be for. -/
def providers : List String := ["anthropic", "mistral", "openai", "openai-compatible"]

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
    | some "scripted" =>
      unless allowLocal do throw "model.api: 'scripted' is only accepted in local mode"
      pure (some Api.scripted)
    | some other => throw s!"model.api: unknown API '{other}' (anthropic, openai)"
    | none => pure none
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
  return { api, name, baseUrl, maxTokens, contextWindow, script }

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

private def anthropicMessage : Message → Json
  | .user text => Json.mkObj [("role", "user"), ("content", Json.arr #[textBlock (nonEmpty text "(empty)")])]
  | .assistant text calls =>
    let textBlocks := if text.trimAscii.isEmpty then #[] else #[textBlock text]
    let useBlocks := calls.map fun c => Json.mkObj
      [("type", "tool_use"), ("id", c.id), ("name", c.name), ("input", inputObject c.arguments)]
    let blocks := textBlocks ++ useBlocks
    Json.mkObj [("role", "assistant"),
      ("content", Json.arr (if blocks.isEmpty then #[textBlock "(empty)"] else blocks))]
  | .toolResults rs => Json.mkObj [("role", "user"), ("content", Json.arr (rs.map fun r => Json.mkObj
      [ ("type", "tool_result"), ("tool_use_id", r.id), ("content", nonEmpty r.content "(no output)")
      , ("is_error", toJson r.isError) ]))]

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
    , ("system", Json.arr #[(textBlock system).setObjVal! "cache_control" ephemeral]) ] ++
    Json.opt "tools" (if tools.isEmpty then none else some (tools.map fun t =>
      ({ name := t.name, description := t.description, input_schema := t.schema } : AnthropicTool))) ++
    [("messages", Json.arr (cacheLast (msgs.map anthropicMessage)))]

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
  content : Array AnthropicBlock
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
  let texts := a.content.filterMap fun b => if b.type == "text" then b.text else none
  let calls := (a.content.filter (·.type == "tool_use")).zipIdx.map fun (b, i) =>
    { id := b.id.getD s!"toolu_{i}", name := b.name.getD ""
      arguments := (b.input.getD (Json.mkObj [])).compress : ToolCall }
  let u := a.usage.getD {}
  return { text := "\n".intercalate texts.toList, calls, stop := a.stop_reason.getD ""
           usage := { input := u.input_tokens.getD 0, output := u.output_tokens.getD 0
                      cacheRead := u.cache_read_input_tokens.getD 0
                      cacheWrite := u.cache_creation_input_tokens.getD 0 } }

-- ── OpenAI Chat Completions ─────────────────────────────────────────────────

private def openaiMessages : Message → Array Json
  | .user text => #[Json.mkObj [("role", "user"), ("content", nonEmpty text "(empty)")]]
  | .assistant text calls =>
    #[Json.mkObj <|
      [ ("role", Json.str "assistant")
      , ("content", if text.isEmpty && !calls.isEmpty then Json.null else Json.str text) ] ++
      Json.opt "tool_calls" (if calls.isEmpty then none else some (calls.map fun c => Json.mkObj
          [ ("id", c.id), ("type", "function")
          , ("function", Json.mkObj [("name", c.name), ("arguments", c.arguments)]) ]))]
  | .toolResults rs => rs.map fun r => Json.mkObj
      [("role", "tool"), ("tool_call_id", r.id), ("content", nonEmpty r.content "(no output)")]

/-- The body of `POST {base}/chat/completions`. -/
def openaiRequest (cfg : Config) (system : String) (tools : Array ToolSpec)
    (msgs : Array Message) : Json :=
  Json.mkObj <|
    [ ("model", Json.str cfg.name), ("max_tokens", toJson cfg.maxTokens)
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
  let calls := (choice.message.tool_calls.getD #[]).zipIdx.map fun (c, i) =>
    { id := c.id.getD s!"call_{i}", name := c.function.name.getD ""
      arguments := match c.function.arguments with
        | some (.str s) => s
        | some v => v.compress
        | none => "{}" : ToolCall }
  let u := a.usage.getD {}
  return { text := choice.message.content.getD "", calls, stop := choice.finish_reason.getD ""
           usage := { input := u.prompt_tokens.getD 0, output := u.completion_tokens.getD 0
                      cacheRead := (u.prompt_tokens_details.bind (·.cached_tokens)).getD 0 } }

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
private def attempt (cfg : Config) (t : Transport) (body : Json) (timeoutMs : Nat) :
    IO (Except Failure Reply) := do
  let path := if cfg.api == .anthropic then "/messages" else "/chat/completions"
  let url := cfg.baseUrl ++ path
  let answer : Except Failure (Nat × String × Option Nat) ← try
      match t with
      | .liaison base creds =>
        let u ← Liaison.call base creds
          { method := "POST", url, account := creds.account
            headers := [("content-type", "application/json")], body := some body.compress } timeoutMs
        -- The provider's answer, relayed by liaison with its headers.
        pure (.ok (u.status.toNat, Liaison.text u,
          (u.header? "retry-after").bind Network.HTTP.Client.parseRetryAfterMillis))
      | .direct key =>
        let auth := if cfg.api == .anthropic then [("x-api-key", key), ("anthropic-version", "2023-06-01")]
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
    match Json.parse text with
    | .error e => return .error { message := s!"the model's answer is not JSON: {e}", retry := true }
    | .ok j =>
      let r := if cfg.api == .anthropic then anthropicReply j else openaiReply j
      return r.mapError fun m => { message := m, retry := false }

/-- Sleep `ms` milliseconds in short slices, returning early (with `true`)
    once `abort` is set. -/
private def sleepUnlessAborted (ms : Nat) (abort : IO.Ref Bool) : IO Bool := do
  for _ in [0:(ms + 199) / 200] do
    if ← abort.get then return true
    IO.sleep 200
  abort.get

/-- Ask the model for its next message. `step` counts the assistant messages
    of the session so far (the `scripted` API plays `script[step]`). Retries
    a transient failure per `retryPolicy` — the server's `Retry-After` when it
    gives one, else jittered backoff (linen's `delayFor`) — and stops waiting
    as soon as `abort` is set. -/
def complete (cfg : Config) (t : Transport) (system : String) (tools : Array ToolSpec)
    (msgs : Array Message) (step : Nat) (timeoutMs : Nat) (abort : IO.Ref Bool) : IO Reply := do
  if cfg.api == .scripted then
    return (cfg.script[step]?).getD { text := "(the script is exhausted)", calls := #[], stop := "end_turn" }
  let body := if cfg.api == .anthropic then anthropicRequest cfg system tools msgs
    else openaiRequest cfg system tools msgs
  let mut last := ""
  for n in [1:retryPolicy.maxAttempts + 1] do
    match ← attempt cfg t body timeoutMs with
    | .ok r => return r
    | .error f =>
      last := f.message
      unless f.retry && n < retryPolicy.maxAttempts do break
      let delay ← Network.HTTP.Client.delayFor retryPolicy n f.retryAfterMs
      if ← sleepUnlessAborted delay abort then throw (IO.userError "aborted")
  throw (IO.userError last)

end Lode.Model
