# Lode v0.5.0 — background checkout and bounded questions

This locally verified release has a local commit and annotated tag. Publication
and deployment remain pending; existing releases retain their original refs.

- Optional `background:true` returns a persisted session before repository I/O.
  Status reports opening/ready/failed checkout and acknowledges `backgroundCheckout`.
  Queued intent stays active during the checkout→execution transition.
- `requestKey` binds retries to the same immutable source/model/credential/
  tool/execution/build contract. `messageKey` suppresses recent duplicate intents;
  neither key authorizes wider execution or replays failed effects.
- `ask_user` carries private bounded question/answer witnesses. It persists the
  question and pauses subsequent tools. `/answer` consumes the current question ID
  and resumes under the same ceilings; cancellation invalidates that question.
- Automatic mode explicitly asks for autonomous work within tool/project/effect
  bounds and bounded questions for genuine missing decisions. Answers contain no
  execution envelope and cannot install tools, credentials or capabilities.
- Linen's dependency lock, image cache and new-project default use **1.12.0**,
  including the non-deprecated TLS verification implementation. The prompt follows
  **Lun 0.4.1** stateless state/deadline semantics and producer emission contracts;
  the app owns durable scheduling. The historical Lun dependency supplies pure
  projection/attenuation proof helpers, not use of the removed runtime session API.

Local checks: unit suite, normal executable build without warnings, actual Git
checkout exceeding the app's 30-second deadline, immutable retry refusal,
question pause/answer/cancellation, duplicate-intent suppression, and the full
app → writer → broker → local Git → compiled stateless Lun producer pipeline.
Linux/container and live paid-provider behavior remain CI/operator verification.
