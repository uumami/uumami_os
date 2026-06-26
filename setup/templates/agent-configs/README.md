# Per-agent post-install guide (SG7)

The `dev_base` image installs each agent **binary only** — no credentials, no config. That
keeps the image credential-free and shareable. Each tenant initializes its own credentials
and (optionally) local-Ollama config **after first entry**, into its own profile. Nothing
here is automated for the cloud-auth agents; secrets never live in the image or this repo.

Drop the template files in this directory into the tenant profile at the paths below.
The default model in the templates is the flavor's `model.primary` (`qwen3-coder:30b`);
Hermes uses `hermes3:8b`. Change them if you changed the flavor.

| Agent | Credential init (after first entry) | Local-Ollama config file | Template |
|---|---|---|---|
| **claude-code** | `claude login` (Anthropic, cloud) | `~/.claude/settings.json` — **needs a proxy**, see below | `claude-settings.json` |
| **codex** | `codex login` or `OPENAI_API_KEY` | `~/.codex/config.toml` (`codex --profile qwen-ollama`, or `codex --oss`) | `codex-config.toml` |
| **opencode** | provider login or key | `~/.config/opencode/opencode.json` | `opencode.json` |
| **pi** | endpoint + optional key on first run | `~/.pi/agent/models.json` | `pi-models.json` |
| **omp** | endpoint + optional key on first run | `~/.omp/agent/models.yml` | `omp-models.yml` |
| **hermes** | `hermes model` wizard (first run) | `~/.hermes/config.yaml` | `hermes-config.yaml` |

All connect to the shared llm_server over loopback `http://127.0.0.1:11434/v1` (OpenAI-
compatible). Agents never hold model weights — they reach models only via this endpoint.

## Cloud vs local, per agent (spike-verified 2026-06-25)

- **Codex** and **OpenCode** are clean drop-ins for local Ollama (`/v1` OpenAI-compatible).
- **Pi** and **omp** point at `/v1` with `api: openai-completions` / `type: openai-compatible`.
  *(omp's exact `models.yml` field names are MEDIUM-confidence — verify on first run.)*
- **Hermes** needs ≥ 64K context for tool use; the llm_server injects
  `OLLAMA_CONTEXT_LENGTH` from the active flavor's `model.context_length` (131072 on the
  reference machine — well over 64K). Prefer the interactive `hermes model` wizard, then
  reconcile `~/.hermes/config.yaml`.
- **Claude Code is NOT a first-class local-Ollama client.** `ANTHROPIC_BASE_URL` expects
  the **Anthropic Messages API**, but Ollama speaks the OpenAI shape. To use Claude Code
  against local models you must run a **translation proxy** (e.g. LiteLLM in
  `anthropic`-passthrough mode, or claude-code-router) in front of Ollama, then point
  `ANTHROPIC_BASE_URL` at the proxy (the template uses `http://127.0.0.1:8787`). Without
  the proxy, use Claude Code in its default cloud mode (`claude login`). The proxy itself
  is out of scope for the base image — it's an optional per-tenant add-on.

## Credential isolation invariant

Each tenant's credentials live only in that tenant's profile/HOME. Never copy or symlink
a credential dir (`~/.claude`, `~/.codex`, `~/.config/opencode`, `~/.pi`, `~/.omp`,
`~/.hermes`) between profiles — that breaks the identity boundary (§2.8).
