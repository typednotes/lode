/-
  Lode.Message — the conversation, provider-independent

  One message model for every model API (as in pi's `pi-ai`): a user's text,
  an assistant's text and tool calls, and the results of those calls.
  `Lode.Model` translates it to and from Anthropic's Messages API and OpenAI's
  Chat Completions (which Mistral, Scaleway, Baseten and most
  OpenAI-compatible endpoints speak).

  A session's history is an append-only log of `Entry`s (`log.jsonl`, one per
  line, as pi and OpenCode keep theirs): the messages, plus **compaction**
  markers (a summary replacing everything before a given entry, when the
  context fills up) and **events** (runs starting and ending, errors), which
  the model never sees. `context` is the only place the log becomes what the
  model is sent.
-/
import Lean.Data.Json

namespace Lode

open Lean (Json ToJson FromJson toJson fromJson?)

-- ── Messages ────────────────────────────────────────────────────────────────

/-- A tool call the model made. `arguments` is the JSON text it wrote,
    verbatim: parsing it is the tool's job (and a parse error goes back to the
    model as the tool's result). -/
structure ToolCall where
  id : String
  name : String
  arguments : String
  deriving DecidableEq, Repr, Inhabited, ToJson, FromJson

/-- What a tool answered. -/
structure ToolResult where
  id : String
  name : String
  content : String
  isError : Bool := false
  deriving DecidableEq, Repr, Inhabited, ToJson, FromJson

/-- Token counts, as the provider reports them. -/
structure Usage where
  input : Nat := 0
  output : Nat := 0
  cacheRead : Nat := 0
  cacheWrite : Nat := 0
  deriving DecidableEq, Repr, Inhabited, ToJson, FromJson

instance : Add Usage where
  add a b := { input := a.input + b.input, output := a.output + b.output
               cacheRead := a.cacheRead + b.cacheRead, cacheWrite := a.cacheWrite + b.cacheWrite }

/-- One message of the conversation. -/
inductive Message where
  | user (text : String)
  | assistant (text : String) (calls : Array ToolCall)
  | toolResults (results : Array ToolResult)
  deriving DecidableEq, Repr, Inhabited

/-- What a model call returns. -/
structure Reply where
  text : String
  calls : Array ToolCall
  usage : Usage := {}
  /-- The provider's stop reason (`end_turn`, `tool_use`, `stop`, `length`, …). -/
  stop : String := ""
  deriving DecidableEq, Repr, Inhabited, ToJson, FromJson

-- ── The log ─────────────────────────────────────────────────────────────────

/-- One entry of a session's log. `time` is Unix milliseconds. -/
inductive Entry where
  | user (text : String) (time : Nat)
  | assistant (reply : Reply) (model : String) (time : Nat)
  | toolResults (results : Array ToolResult) (time : Nat)
  /-- Everything before entry `firstKept` is replaced, in the context, by
      `summary`. -/
  | compaction (summary : String) (firstKept : Nat) (tokensBefore : Nat) (time : Nat)
  /-- Not part of the conversation: `run_started`, `run_finished`,
      `aborted`, `error`, … -/
  | event (kind : String) (detail : String) (time : Nat)
  deriving Repr, Inhabited

/-- An entry's JSON: its payload's fields, a `type` tag and its `time`. -/
private def tagged {α : Type} [ToJson α] (type : String) (payload : α) (time : Nat) : Json :=
  (toJson payload).mergeObj (Json.mkObj [("type", type), ("time", toJson time)])

/-- The payload of a `user` entry. -/
private structure UserText where
  text : String
  deriving ToJson, FromJson

/-- The payload of a `tool_results` entry. -/
private structure Results where
  results : Array ToolResult
  deriving ToJson, FromJson

/-- The payload of a `compaction` entry. -/
private structure Compacted where
  summary : String
  firstKept : Nat
  tokensBefore : Nat
  deriving ToJson, FromJson

/-- The payload of an `event` entry. -/
private structure Event where
  kind : String
  detail : String
  deriving ToJson, FromJson

/-- The model of an `assistant` entry (next to its `Reply`'s fields). -/
private structure ModelName where
  model : String
  deriving ToJson, FromJson

instance : ToJson Entry where
  toJson
    | .user text t => tagged "user" ({ text } : UserText) t
    | .assistant r model t => tagged "assistant" r t |>.mergeObj (toJson ({ model } : ModelName))
    | .toolResults rs t => tagged "tool_results" ({ results := rs } : Results) t
    | .compaction s k n t => tagged "compaction" ({ summary := s, firstKept := k, tokensBefore := n } : Compacted) t
    | .event k d t => tagged "event" ({ kind := k, detail := d } : Event) t

/-- Read an entry back from its JSON line. -/
def Entry.ofJson (j : Json) : Except String Entry := do
  let t ← j.getObjValAs? Nat "time"
  match ← j.getObjValAs? String "type" with
  | "user" => return .user (← fromJson? j : UserText).text t
  | "assistant" => return .assistant (← fromJson? j) (← fromJson? j : ModelName).model t
  | "tool_results" => return .toolResults (← fromJson? j : Results).results t
  | "compaction" =>
    let c : Compacted ← fromJson? j
    return .compaction c.summary c.firstKept c.tokensBefore t
  | "event" =>
    let e : Event ← fromJson? j
    return .event e.kind e.detail t
  | other => throw s!"unknown log entry type '{other}'"

/-- The message an entry carries, if it is part of the conversation. -/
def Entry.message? : Entry → Option Message
  | .user text _ => some (.user text)
  | .assistant r _ _ => some (.assistant r.text r.calls)
  | .toolResults rs _ => some (.toolResults rs)
  | _ => none

/-- An entry is an assistant message (compaction may cut before one). -/
def Entry.isAssistant : Entry → Bool
  | .assistant .. => true
  | _ => false

-- ── The context ─────────────────────────────────────────────────────────────

/-- The text the model reads in place of the compacted history. -/
def summaryMessage (summary : String) : String :=
  "The conversation so far was compacted to save context. Summary of what happened:\n\n" ++
    summary ++ "\n\nContinue from here."

/-- Make every tool call answered, in order: a call left without a result (a
    run interrupted by a crash or a restart) gets an error result, since every
    provider refuses a tool call that is not followed by its result. -/
def answerDangling (msgs : List Message) : List Message :=
  let interrupted (c : ToolCall) : ToolResult :=
    { id := c.id, name := c.name, content := "(interrupted: this tool call did not complete)", isError := true }
  let rec go : List Message → List Message
    | [] => []
    | .assistant text calls :: .toolResults rs :: rest =>
      if calls.isEmpty then .assistant text calls :: go rest  -- stray results dropped
      else
        let missing := calls.filter fun c => !rs.any (·.id == c.id)
        let known := rs.filter fun r => calls.any (·.id == r.id)
        .assistant text calls :: .toolResults (known ++ missing.map interrupted) :: go rest
    | .assistant text calls :: rest =>
      if calls.isEmpty then .assistant text calls :: go rest
      else .assistant text calls :: .toolResults (calls.map interrupted) :: go rest
    | .toolResults _ :: rest => go rest  -- results with no call before them
    | m :: rest => m :: go rest
  go msgs

/-- Where the context starts: after the last compaction, its summary, then
    the entries from its `firstKept` on. -/
def lastCompaction? (entries : Array Entry) : Option (String × Nat) :=
  entries.foldl (init := none) fun acc e => match e with
    | .compaction s k _ _ => some (s, k)
    | _ => acc

/-- What the model is sent: the conversation since the last compaction. -/
def context (entries : Array Entry) : Array Message :=
  let (pre, start) := match lastCompaction? entries with
    | some (summary, k) => ([Message.user (summaryMessage summary)], k)
    | none => ([], 0)
  let msgs := (entries.toList.drop start).filterMap Entry.message?
  (answerDangling (pre ++ msgs)).toArray

/-- A rough size of a message, in characters (for compaction decisions). -/
def Message.chars : Message → Nat
  | .user t => t.length
  | .assistant t cs => t.length + cs.foldl (fun n c => n + c.name.length + c.arguments.length) 0
  | .toolResults rs => rs.foldl (fun n r => n + r.content.length + 32) 0

end Lode
