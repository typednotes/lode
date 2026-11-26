# Lode operator and extension contracts

- **S1. Operator settings.** The HTTP and stdio entry points accept the same
  TOML or JSON settings. `--settings` selects a file ahead of `LODE_SETTINGS`.
  Environment values override fields in that file. Unset fields use built-in
  defaults. File keys and value types are checked before starting a session.
  The settings schema has no credential fields. Sessions retain their own
  persisted source and model configuration when the operator changes defaults.
- **S2. Direct model routing.** OpenAI, Anthropic, Scaleway and Baseten have
  provider presets. The operator selects the model and may select a compatible
  protocol or endpoint. The direct key is used only for the operator-configured
  model base URL. A session with a model warrant uses Liaison.
- **S3. Managed model key.** A Secrets record binds an API key to its model
  base URL. A managed direct call reads the current record at the configured
  KV path and checks that binding before inference. An explicit environment
  key takes precedence. The store command writes a new KV version only after
  operator confirmation. Secret service failures return status or validation
  errors without quoting the vault response.
- **S4. Client key handoff.** A server with configured bearer authentication
  can accept or clear a direct key in a session using the configured endpoint
  and protocol. The value is held in memory until cleared, replaced, or the
  session or process exits. It takes precedence over operator direct keys.
  Session status and persisted session records omit the key.
- **S5. Compiled extensions.** Tool names in a compiled catalog are unique.
  A typed decoder runs before its paired handler. The build agent can call
  compiled tools only when the launch allowlist explicitly includes
  `extension` and the live allowlist still permits it.
- **S6. MCP stdio.** A compiled MCP tool selects a fixed executable, argument
  vector and server tool. Lode negotiates protocol `2025-11-25`, requires
  `tools`, sends `notifications/initialized`, and correlates the `tools/call`
  response by ID. The adapter accepts servers that answer each request with
  one JSON-RPC result. The worker is reaped on completion, interruption and
  failure. Calls share a deadline of at most 30 seconds and bound the parsed
  reply to 64 KiB.

The [architecture](docs/architecture/lode.md) describes the boundaries with
Liaison, Lun and Typednotes. Pure guards live in
[`LodeTest/Lode/SettingsTest.lean`](LodeTest/Lode/SettingsTest.lean). The real
process tests are [`test/settings.py`](test/settings.py) and
[`test/McpSmoke.lean`](test/McpSmoke.lean).
