# Lode v0.6.0

Lode 0.6.0 adds TOML and JSON operator settings, direct model credential
handoffs, and a Lean extension catalog around the existing session loop.
The Lake lockfile, container and project defaults use Linen 3.0.0 on Lean
4.36.0.

- `serve` and `run` share one operator settings schema. Use `--settings`
  to select a file or `LODE_SETTINGS` as the default source.
- Configure a direct model with an OpenAI, Anthropic, Scaleway, or Baseten
  preset. Read and rotate an endpoint-bound key through Typednotes Secrets,
  or hand an in-memory key to an authenticated Lode session.
- A compiled extension pairs a typed decoder with its handler. The build
  agent can invoke it when the caller explicitly grants `extension`.
  `Lode.Mcp.stdioTool` adapts a named tool from a configured subprocess.

Browser SSO, broader MCP transports, and reusable signed cell binaries are
tracked as follow-up work. The architecture describes the authoring and
compiler responsibilities for cells. [Architecture](architecture/lode.md),
[contracts](../SPEC.md), [follow-up work](../TODO.md).
