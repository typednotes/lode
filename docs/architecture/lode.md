# The Lean coding agent

Lode runs a model-driven session against a Git-backed workspace. The HTTP
server, the native stdio command, and compiled extensions share the Lean
session loop. File tools operate under the checkout capability, shell
commands run as bounded subprocesses, `check` builds Lake targets, and `lsp`
returns Lean diagnostics, hovers, definitions, goals, and completions. Run
one container per trust domain because project code and shell commands run
with the container's privileges. For an application that follows a server
session over HTTP, see the Python client and scripted examples.
[`Lode/Session.lean`](../../Lode/Session.lean), [`Lode/ToolPolicy.lean`](../../Lode/ToolPolicy.lean),
[`Lode/Lsp.lean`](../../Lode/Lsp.lean), [`Examples/client.py`](../../Examples/client.py),
[Pi's extension API](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md).

![Lode connects shell or HTTP clients to a Lean session, runs workspace tools and compiled extensions, and hands published source to Lun](figures/lode-runtime.svg)

## Operator settings

Both `lode serve --settings FILE` and `lode run --settings FILE` accept TOML
or JSON. A flag selects the file ahead of `LODE_SETTINGS`. Environment
variables override individual settings. Use an operator-owned file and mount
it read-only in a container. Without a selected file, Lode uses environment
variables and built-in defaults. `lode run --config FILE` still selects a
session request.

```toml
toolchain = "leanprover/lean4:v4.36.0"
linenRev = "bcfec9a81d6e738ecb273f89e2102b4712d8e160"
port = 8080

[model]
provider = "scaleway"
name = "MODEL_ID"

[secrets]
baseUrl = "https://secrets.example.org"
modelKeyPath = "lode/model-keys/scaleway"
```

JSON uses the same keys with `model` and `secrets` as nested objects. The
complete field list and environment overrides are in the README. The
toolchain and Linen settings guide new source generation. An existing
project continues to compile with its own `lean-toolchain` and package lock.
[`Lode/Settings.lean`](../../Lode/Settings.lean), [configuration](../../README.md#configuration).

## Models and credentials

| Operator preset | Default protocol | Default API base |
| --- | --- | --- |
| `openai` | Responses or Chat Completions, according to model ID | `https://api.openai.com/v1` |
| `anthropic` | Messages | `https://api.anthropic.com/v1` |
| `scaleway` | Chat Completions | `https://api.scaleway.ai/v1` |
| `baseten` | Chat Completions | `https://inference.baseten.co/v1` |

The operator can set `model.api` and `model.baseUrl` for a compatible
deployment. For direct inference, Lode selects the session override, a
startup API key, or the current record at the configured Secrets KV path.
Vault requests use `LODE_SECRETS_TOKEN` and verify the record's model base
URL before using its key. To create a version in the vault, pass
`LODE_MODEL_API_KEY` in the environment and run
`lode secrets store-model-key --settings FILE --yes`. Use `--dry-run` to
inspect the destination. Restart a vault-backed process with the startup
API key unset to let it read current vault versions. [Scaleway Chat API](https://www.scaleway.com/en/docs/generative-apis/api-cli/using-chat-api/),
[Baseten Chat Completions](https://www.baseten.co/resources/changelog/deepseek-v41-flash-available-on-baseten/),
[`Lode/Secrets.lean`](../../Lode/Secrets.lean).

An authenticated HTTP client receives `modelKeyUrl` in eligible session
status responses. Send a `PUT` with `{"apiKey":"…"}` to set or rotate the
memory-only key, or `{"apiKey":null}` to clear it. A terminal launcher can
prompt for the key and send this request through loopback or TLS. A model
warrant takes precedence. The app can replace short-lived warrants through
`PUT /v0/sessions/{id}/credentials`. Liaison can refresh supported upstream
OAuth credentials while servicing an operation. [`Lode/Server.lean`](../../Lode/Server.lean),
[Liaison credential formats](https://github.com/typednotes/liaison#credential-formats).

Browser SSO would add an operator-configured authorization URL and a
short-lived callback bound to the originating session and issuer. The
callback should redeem a code with PKCE when using OAuth, and resume the
pending session through authenticated credential ingress. Provider-specific
SSO protocols and a browser launcher are open work. [OAuth security BCP](https://www.rfc-editor.org/rfc/rfc9700.html).

## Compiled tools and MCP

`Lode.Extension.Tool.define` couples a JSON decoder to a Lean argument type
and its handler. Select the tool list when compiling the executable and
pass `Lode.Extension.Catalog.check tools` to `Lode.App.main`. The standard
binary includes `lean_version`, which runs `lake env lean --version` in the
project. The launch request must explicitly include `"extension"` in `tools`
and the build agent invokes it with `{"name":"lean_version","arguments":{}}`.
The live policy can remove access just like a built-in tool.
[`Main.lean`](../../Main.lean), [`Lode/Extension.lean`](../../Lode/Extension.lean),
[`Lode/Extensions/Lean.lean`](../../Lode/Extensions/Lean.lean).

`Lode.Mcp.stdioTool` adapts one tool from an operator-selected MCP executable.
The definition fixes the command, process arguments and server-side tool
name, and supplies a decoder for the model arguments. Start with servers
that send one JSON-RPC response per request. MCP discovery, interleaved
server requests and notifications, and Streamable HTTP are future protocol
work. Direct models and the scripted fixture can use compiled tools. Liaison
also needs to authorize the `extension` tool before a brokered model can use
it. [`Lode/Mcp.lean`](../../Lode/Mcp.lean), [`test/McpSmoke.lean`](../../test/McpSmoke.lean),
[MCP lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle).

## Cell sources and native packages

A cell revision identifies four immutable records: natural-language intent,
approved platform constraints, the Lean contract, and implementation source
pinned in Git. Typednotes owns the intent and approved constraints. Lode
writes the Lean contract and implementation, and checks them with Lake and
the language server. Lun checks the published implementation against the
contract and builds the native code. A dependent contract can express, for
example, that a function returns a `Vector` whose length is the number of
items in its input. Lun's current outer wire interface uses independent
input and output types. An input-indexed output needs a wire adapter that
decodes and retains the input witness. [Typednotes cell package design](https://github.com/typednotes/typednotes/blob/main/docs/cell-packages.md),
[the five layers](https://github.com/typednotes/typednotes/blob/main/docs/diagrams/cell-package-layers.svg).

Reusable native packages still need a shared contract with Lun. A proposed
variant binds the Git commit and Lean declaration to the artifact digest,
target platform and runtime ABI. A tarball could be stored under its digest
in S3-compatible storage or served as a static file. A detached OpenPGP
signature from the compiler's signing key would authenticate the manifest
that binds those fields. For artifact bytes $B$, the manifest records
$d=\operatorname{SHA256}(B)$ and verifies that digest before code is loaded.
Invocation still requires the runner's live authorization.

## Verification

Use `lake build --wfail` and `lake test` for contracts in Lean. Run
`python3 test/settings.py` to exercise a real service, a temp Git repository,
Secrets rotation, both startup formats, and direct key handoff. Run
`lake exe lode-mcp-smoke` for the stdio MCP exchange. The existing CLI, LSP,
mock Liaison and Lun integration suites cover the remaining current paths.
Comparative runs against Pi and live provider/SSO conformance are separate
verification work. [Test commands](../../README.md#test).
