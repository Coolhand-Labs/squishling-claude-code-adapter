# squishling-claude_code

[Squishling](https://github.com/Coolhand-Labs/squishling) adapter for **Claude Code**: run your Ruby LLM calls through
the `claude` CLI on your machine, so they count against your **Claude subscription** (Pro or Max) instead of API billing.
Develop against Squishling with real Claude models without a per-token bill.

```ruby
# Gemfile
gem "squishling"
gem "squishling-claude_code", group: :development
```

```ruby
Squishling.configure do |config|
  config.adapter = :claude_code if Rails.env.development?   # or any check that says "on my machine"
  config.default_model = "haiku"                            # haiku, sonnet, opus, or a full model name
end

class SentimentClassifier
  include Squishling

  purpose "Classify the sentiment of the review."
  output_schema do
    string :sentiment, enum: %w[positive negative neutral]
    optional(:quote) { string }
  end
end

SentimentClassifier.call(review: "Loved it, would buy again!")
# => #<data sentiment="positive", quote=nil>, the same typed result any other adapter returns
```

## Requirements

- The [Claude Code CLI](https://code.claude.com/docs/en/overview) installed and logged in to a Pro or Max plan
  (`claude auth login`; check with `claude auth status`). The adapter finds `claude` on your `PATH`, or use `cli_path:`.
- Ruby 3.3+ and a Squishling release with pluggable adapters.
- The [`claude-agent-sdk`](https://github.com/rubycatco/claude-agent-sdk-ruby) gem, which this gem installs, does the heavy
  lifting of starting `claude` and reading its answers.

## Options

```ruby
config.adapter = { type: :claude_code, timeout: 120, max_concurrency: 1 }
```

| Option | Default | Description |
|---|---|---|
| `timeout` | `180` | Seconds one call may take before it fails with an `LLMError`. |
| `cli_path` | found on `PATH` | The `claude` executable to run. |
| `max_concurrency` | `2` | How many `claude` processes run at once. Squishling's concurrent samples queue behind it, so they don't use up your plan's limits together. |
| `subscription_only` | `true` | Removes `ANTHROPIC_API_KEY` and every other `ANTHROPIC_*` and `CLAUDE_CODE_USE_*` variable (keys, tokens, base URLs, provider switches) from the `claude` process, so a stray one can't turn subscription calls into API or cloud charges. |

`model:` goes to `claude --model`. `max_output_tokens` and `thinking: { effort: }` are supported; `temperature` and other
params raise `Squishling::ConfigurationError`, since Claude Code has no such setting.

## A note on use

Anthropic's [legal and compliance page](https://code.claude.com/docs/en/legal-and-compliance) says OAuth login "is
designed to support ordinary use of Claude Code and other native Anthropic applications", that "building products
or services that interact with Claude's capabilities, including those using the Agent SDK, should use API key
authentication" (for developers), and that Pro and Max limits "assume ordinary, individual usage of Claude Code and the Agent SDK".

This adapter is for the first kind of use: you, on your own machine, developing against Squishling with the unmodified
`claude` you installed. It never touches your credentials and has no way to serve other people's requests. We believe that
fits, but the terms are Anthropic's to interpret, so read them. Don't run it in a hosted service or share one login between
users; use an API key and Squishling's other adapters for that.

Calls also spend your plan's usage limits (five-hour and weekly), shared with your other Claude use, and are slower than
the API: expect a few seconds per call and about 1.5k tokens of fixed overhead each.

## Documentation

- **[How it works](docs/how-it-works.md)**: what Claude Code is started with, billing and credentials, params, how failures
  map to Squishling's errors, and troubleshooting.
- [Squishling's adapters](https://github.com/Coolhand-Labs/squishling/blob/main/docs/adapters.md): the adapter contract
  and the other adapters.
- [Changelog](CHANGELOG.md)

## Development

```bash
bundle install
bundle exec rake                                # RSpec (offline: ClaudeAgentSDK.ask is stubbed) + RuboCop
bin/exhale dry --include-tests                  # duplication gate
bin/exhale complexity                           # complexity gate
bundle exec ruby examples/claude_code_example.rb # live, against your logged-in Claude Code (spends a little plan usage)
```

See [AGENTS.md](AGENTS.md) for the design invariants and the release process.

## License

Apache-2.0. See [LICENSE](LICENSE).
