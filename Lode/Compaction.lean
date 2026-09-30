/-
  Lode.Compaction — keeping a long session within the context window

  As in pi and OpenCode: when the conversation approaches the model's
  context window, older messages are summarized by the model itself and the
  summary stands in for them. Nothing is deleted — the log keeps every entry
  and gains a `compaction` entry naming the first entry kept verbatim; only
  what `Lode.context` sends the model changes.

  The cut is always just before an **assistant** message: the summary (sent
  as a user message) is then followed by an assistant turn, which every API
  accepts, and no tool call is separated from its result.
-/
import Lode.Message

namespace Lode.Compaction

/-- Tokens kept free for the reply and the system prompt, besides the
    reply's own `maxTokens` (pi's reserve). -/
def reserveTokens : Nat := 16384

/-- Roughly how many recent tokens to keep verbatim after a compaction. -/
def keepTokens : Nat := 20000

/-- About four characters per token: rough, and only used to decide when to
    compact and where to cut. -/
def charsPerToken : Nat := 4

/-- Where the current context starts in the log. -/
def contextStart (entries : Array Entry) : Nat :=
  ((lastCompaction? entries).map (·.2)).getD 0

private def entryChars (e : Entry) : Nat := (e.message?.map Message.chars).getD 0

/-- The context's size in tokens: what the provider reported for the last
    reply (its input, cached or not, plus its output), plus an estimate for
    what came after it; an estimate of everything when no reply reported
    usage. -/
def estimateTokens (entries : Array Entry) : Nat :=
  let start := contextStart entries
  let idx := (List.range entries.size).drop start
  let lastUsage := idx.foldl (init := none) fun acc i => match entries[i]! with
    | .assistant r _ _ =>
      let u := r.usage
      let t := u.input + u.cacheRead + u.cacheWrite + u.output
      if t > 0 then some (i, t) else acc
    | _ => acc
  let after (from_ : Nat) := (idx.filter (· > from_)).foldl (fun n i => n + entryChars entries[i]!) 0
  match lastUsage with
  | some (i, t) => t + after i / charsPerToken
  | none =>
    let summary := ((lastCompaction? entries).map (·.1.length)).getD 0
    (summary + idx.foldl (fun n i => n + entryChars entries[i]!) 0) / charsPerToken

/-- Compact when the context would not leave room for a reply. -/
def needed (entries : Array Entry) (window maxTokens : Nat) : Bool :=
  estimateTokens entries + maxTokens + reserveTokens > window

/-- Where to cut: the earliest assistant entry after the context's start
    from which at most `keepChars` characters remain; failing that, the
    last assistant entry. `none` when nothing can be summarized. -/
def cutPoint (entries : Array Entry) (keepChars : Nat := keepTokens * charsPerToken) : Option Nat :=
  let start := contextStart entries
  let candidates := ((List.range entries.size).drop (start + 1)).filter (entries[·]!.isAssistant)
  let suffix (i : Nat) := ((List.range entries.size).drop i).foldl (fun n j => n + entryChars entries[j]!) 0
  match candidates.find? (suffix · ≤ keepChars) with
  | some i => some i
  | none => candidates.getLast?

/-- Clip one message's text for the summarizer: a long tool output matters
    less than the fact it was produced. -/
private def clip (s : String) (max : Nat) : String :=
  if s.length > max then (s.take max).toString ++ s!" …({s.length - max} characters omitted)" else s

/-- The conversation between the context's start and `cut`, as text for the
    summarizer (previous summary first, if any). -/
def transcript (entries : Array Entry) (cut : Nat) (maxChars : Nat) : String :=
  let start := contextStart entries
  let prior := match lastCompaction? entries with
    | some (s, _) => s!"[Summary of the conversation before this point]\n{s}\n\n"
    | none => ""
  let render : Message → String
    | .user t => s!"[User]\n{t}"
    | .assistant t cs | .assistantReplay t cs _ =>
      let calls := cs.toList.map fun c => s!"[Tool call] {c.name} {clip c.arguments 1500}"
      "\n".intercalate ((if t.isEmpty then [] else [s!"[Assistant]\n{t}"]) ++ calls)
    | .toolResults rs => "\n".intercalate (rs.toList.map fun r =>
        s!"[Tool result{if r.isError then " (error)" else ""}] {r.name}\n{clip r.content 2000}")
  let parts := (((List.range cut).drop start).filterMap fun i => entries[i]!.message?).map render
  let text := prior ++ "\n\n".intercalate parts
  -- Keep the end if even that is too long: what happened last matters most.
  if text.length > maxChars then "…(earliest part omitted)\n" ++ (text.drop (text.length - maxChars)).toString
  else text

/-- The summarizer's instructions. -/
def instructions : String :=
"You summarize a coding session so that it can continue from your summary alone: the messages you summarize will no longer be visible. Write in this structure, concisely, keeping exact file paths, names, signatures, commit ids, build ids and error messages:

## Goal
## Constraints and preferences
## Progress
(done, in progress)
## Key decisions
## Files
(created or changed, and what they contain)
## Published state
(commits, lun builds and their outcome)
## Next steps"

end Lode.Compaction
