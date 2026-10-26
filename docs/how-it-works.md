# How it works

`squishling-claude_code` runs Squishling's requests through the Claude Code CLI on your machine. Squishling builds the
request, this adapter makes one completion, and Squishling does the rest: validation, retries and escalation, harnesses,
`squawk`, and fallbacks. See
[Squishling's adapter contract](https://github.com/Coolhand-Labs/squishling/blob/main/docs/adapters.md#writing-your-own).

## What runs

Each call starts one `claude` process through the [`claude-agent-sdk`](https://github.com/rubycatco/claude-agent-sdk-ruby)
gem, which finds the executable, speaks its stream-JSON protocol, and parses the result. Claude Code is started as a
**plain completion**, so a call sees only what Squishling sends:

| Setting | Why |
|---|---|
| `--tools ""` | no Bash, file, or web tools |
| `--setting-sources ""` | no user, project, or local settings: no hooks, `CLAUDE.md`, or MCP servers |
| `--strict-mcp-config` | no MCP servers from anywhere else |
| `--no-session-persistence` | nothing saved to resume, nothing added to your history |
| `--disable-slash-commands` | skills and your custom slash commands aren't loaded or expanded |
| `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1`, `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` | memory files, which the setting sources don't govern, aren't read |
| an empty temporary working directory | no project files in reach; removed after the call |
| `--system-prompt` | Squishling's instructions replace Claude Code's own |
| `--json-schema` | Squishling's strict schema; the answer comes back as `structured_output` |

A call takes a few seconds: structured output is a second turn inside Claude Code, and each call carries about 1.5k tokens
of fixed overhead on top of your prompt. A retry replays the earlier turns in the prompt as a transcript.

## Billing and credentials

The `claude` process authenticates itself with your login, so calls count against your plan's usage limits. This gem never
reads, stores, logs, or forwards your token or any key.

Claude Code prefers an `ANTHROPIC_API_KEY`, an environment-selected federation or profile credential, a different `ANTHROPIC_BASE_URL`, or a
cloud-provider switch over your login, which would silently bill the API or another provider (or send your calls to a
gateway). So by default (`subscription_only: true`) the adapter removes **every `ANTHROPIC_*` and `CLAUDE_CODE_USE_*`
variable** that is set, plus `AWS_BEARER_TOKEN_BEDROCK`, from the `claude` process's environment (not from yours). Matching by
prefix means a variable Claude Code adds later is covered too. `CLAUDE_CODE_OAUTH_TOKEN`, a subscription token you chose to
set, is left alone. Set `subscription_only: false` only if you want Claude Code to use the others.

One thing environment variables can't undo: a Workload Identity Federation profile that is *active* in `~/.config/anthropic`
(an `active_config` file) outranks your login with no variable involved. If you have set one up, switch it off for
development with this adapter, or check `claude auth status` shows `claude.ai`.

Claude Code's options also ignore `ClaudeAgentSDK.configure`'s global `default_options`, so MCP servers, plugins, allowed
tools, a permission mode, or a model that your app configured for its own agents never reach a call.

The adapter never starts Claude Code with `--bare`: bare mode ignores your login and needs an API key.

`total_cost_usd` in Claude Code's own output is a list-price estimate, not a charge on a subscription; the adapter reports
token counts only.

## Params

| Squishling | Claude Code |
|---|---|
| `model:` | `--model` (`haiku`, `sonnet`, `opus`, or a full model name); none leaves Claude Code's default |
| `max_output_tokens` | `CLAUDE_CODE_MAX_OUTPUT_TOKENS` |
| `thinking: { effort: }` | `--effort` (`low`, `medium`, `high`, `xhigh`, `max`; which levels a model supports varies) |
| `thinking: false` | thinking disabled |
| `temperature`, `top_p`, anything else | `ConfigurationError`: Claude Code has no such setting |
| `provider:` | ignored |

The response's `model` is the model id Claude Code resolved (for example `claude-haiku-4-5-20251001`), and token counts
(`input_tokens`, `output_tokens`, `cache_read_tokens`, `thinking_tokens`) come from its usage.

## Concurrency

Squishling's harnesses (`:squishsum`, `:judged_squishsum`) take samples on worker threads, each its own `claude` process.
`max_concurrency` (default 2) queues them behind a small number of slots so a burst doesn't spend your five-hour limit at
once. Slots are always given back, including when a call fails or times out, and a timed-out process is stopped.

## Failures

| What happened | Raised | Notes |
|---|---|---|
| `claude` isn't installed (or `cli_path:` is wrong) | `ConfigurationError` | never retried |
| Not logged in | `ConfigurationError` | the message says `claude auth login` |
| A rejected API key or credential (401, 403) | `ConfigurationError` | with the default `subscription_only: true` the key is removed |
| An unknown model (404), or a rejected request (400) | `ConfigurationError` | check `model:` |
| A param Claude Code can't take | `ConfigurationError` | |
| A rate or usage limit (429) | `LLMError` | your plan's five-hour or weekly limit may be used up |
| An overlong request, a cut-off answer (`max_output_tokens`) | `LLMError` | depends on the input |
| A crash, a protocol error, an early stop, or longer than `timeout` | `LLMError` | |

Messages carry only the kind of failure. What Claude Code or the API said, and the SDK's exception text, never appear in an
error or log.

## Troubleshooting

- `Claude Code isn't logged in`: run `claude auth login`, then `claude auth status` (it should say `claude.ai`, with your
  plan).
- `Claude Code wasn't found`: install Claude Code, make sure `claude` is on the `PATH` of the process running Ruby (a Rails
  server may not inherit your shell's `PATH`), or pass `cli_path:`.
- `usage limit` errors: your plan's limits are shared with all your Claude use. Lower `max_concurrency`, use `haiku`, or wait
  for the window to reset.
- Slow calls: expect a few seconds each. Use a smaller model alias, and keep the work you're developing small.
