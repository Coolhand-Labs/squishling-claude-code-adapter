# frozen_string_literal: true

RSpec.describe Squishling::ClaudeCode::Adapter do
  let(:adapter) { described_class.new }
  let(:answer) do
    { structured_output: { label: "ok", note: nil }, result: '{"label":"ok"}', usage: usage, model_usage: model_usage,
      is_error: false, subtype: "success", api_error_status: nil }
  end
  let(:usage) do
    { input_tokens: 12, output_tokens: 4, cache_read_input_tokens: 3, output_tokens_details: { thinking_tokens: 2 } }
  end
  let(:model_usage) { { "claude-haiku-4-5-20251001": { inputTokens: 12 } } }
  let(:seen) { [] }

  # ClaudeAgentSDK.ask, replaced: records the prompt and options, answers with a canned ResultMessage.
  def stub_ask(result = answer)
    allow(ClaudeAgentSDK).to receive(:ask) do |prompt, options:|
      seen << { prompt:, options:, cwd_existed: File.directory?(options.cwd) }
      block_given? ? yield : Struct.new(*result.keys, keyword_init: true).new(**result)
    end
  end

  def result_error(**data)
    ClaudeAgentSDK::ResultError.new("SECRET detail", data: { terminal_reason: "api_error", subtype: "success", **data })
  end

  it "is registered as :claude_code, built from a Hash of options" do
    Squishling.configure { |config| config.adapter = { type: :claude_code, timeout: 30, max_concurrency: 1 } }

    expect(Squishling.config.adapter).to be_a(described_class)
    expect(Squishling.adapters).to include(:claude_code)
  end

  it "doesn't support judgments" do
    expect(adapter.judgments?).to be(false)
  end

  describe "#complete" do
    it "returns the structured answer as JSON text, the resolved model id, and token counts" do
      stub_ask

      response = adapter.complete(adapter_request)

      expect(response).to have_attributes(content: '{"label":"ok","note":null}', model: "claude-haiku-4-5-20251001",
        tokens: { input_tokens: 12, output_tokens: 4, cache_read_tokens: 3, thinking_tokens: 2 })
    end

    it "returns the text Claude wrote when it gave no structured answer, for Squishling to reject" do
      stub_ask(answer.merge(structured_output: nil, result: "I can't help with that."))

      expect(adapter.complete(adapter_request).content).to eq("I can't help with that.")
    end

    it "classifies an error result that came back without raising, instead of passing its text on as the answer" do
      stub_ask(answer.merge(is_error: true, structured_output: nil, result: "Not logged in · Please run /login"))
      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::ConfigurationError, /claude auth login/)

      stub_ask(answer.merge(is_error: true, structured_output: nil, result: "SECRET overloaded", api_error_status: 529))
      expect { adapter.complete(adapter_request) }
        .to raise_error(Squishling::LLMError, "Klass#call: Claude Code failed (HTTP 529)")
    end

    it "falls back to the requested model name, and reports no tokens, when Claude Code reported none" do
      stub_ask(answer.merge(usage: nil, model_usage: nil))

      expect(adapter.complete(adapter_request(model: "opus"))).to have_attributes(model: "opus", tokens: {})
    end

    it "ignores token counts that aren't integers" do
      stub_ask(answer.merge(usage: { input_tokens: "7", output_tokens: 3 }))

      expect(adapter.complete(adapter_request).tokens).to eq({ output_tokens: 3 })
    end

    describe "the Claude Code it starts" do
      before { stub_ask }

      let(:options) { adapter.complete(adapter_request) && seen.last[:options] }

      it "is a plain completion: no tools, no settings, no MCP servers, no saved session, no slash commands" do
        expect(options).to have_attributes(tools: [], setting_sources: [], strict_mcp_config: true,
          extra_args: { "no-session-persistence" => nil, "disable-slash-commands" => nil })
      end

      it "is told the instructions, the model, and the schema (without its $schema), and is asked for JSON" do
        expect(options).to have_attributes(system_prompt: "Classify.", model: "haiku")
        expect(options.output_format).to eq(
          type: "json_schema",
          schema: { "type" => "object", "properties" => { "label" => { "type" => "string" } },
                    "required" => ["label"], "additionalProperties" => false }
        )
      end

      it "gets a default instruction when Squishling sent none, and no model flag when none is named" do
        adapter.complete(adapter_request(instructions: nil, model: nil))

        expect(seen.last[:options]).to have_attributes(system_prompt: a_string_including("requested JSON"), model: nil)
      end

      it "runs in a fresh empty directory that is gone afterwards" do
        adapter.complete(adapter_request)

        expect(seen.last[:cwd_existed]).to be(true)
        expect(File.exist?(seen.last[:options].cwd)).to be(false)
      end

      it "is told where the claude executable is, when the adapter knows" do
        Tempfile.create("claude") do |file|
          File.chmod(0o755, file.path)
          described_class.new(cli_path: file.path).complete(adapter_request)

          expect(seen.last[:options].cli_path).to eq(file.path)
        end
      end

      it "raises ConfigurationError for a cli_path that is a file but can't be run, before starting anything" do
        Tempfile.create("claude") do |file|
          File.chmod(0o644, file.path)

          expect { described_class.new(cli_path: file.path).complete(adapter_request) }
            .to raise_error(Squishling::ConfigurationError, /isn't an executable file/)
          expect(ClaudeAgentSDK).not_to have_received(:ask)
        end
      end

      it "ignores the SDK's global default_options: nothing a host app configured for its own agents reaches a call" do
        ClaudeAgentSDK.configure do |config|
          config.default_options = {
            mcp_servers: { "files" => { type: "stdio", command: "echo" } },
            plugins: [{ type: "local", path: "/tmp/p" }],
            allowed_tools: ["Bash"], permission_mode: "bypassPermissions", add_dirs: ["/etc"], model: "opus",
            env: { "LEAKED" => "1" }, extra_args: { "leaked" => nil }
          }
        end

        adapter.complete(adapter_request(model: nil))
        options = seen.last[:options]

        expect(options).to have_attributes(allowed_tools: [], add_dirs: [], model: nil, permission_mode: nil, tools: [],
          setting_sources: [], extra_args: { "no-session-persistence" => nil, "disable-slash-commands" => nil })
        expect(options.mcp_servers).to be_nil.or(be_empty)
        expect(options.plugins).to be_nil.or(be_empty)
        expect(options.env.keys).not_to include("LEAKED")
      ensure
        ClaudeAgentSDK.configure { |config| config.default_options = nil }
      end

      it "replays a retry's earlier turns in the prompt" do
        turns = [{ role: :user, content: "first" }, { role: :assistant, content: "{}" },
                 { role: :user, content: "fix it" }]
        adapter.complete(adapter_request(messages: turns))

        expect(seen.last[:prompt]).to include("[assistant]\n{}").and end_with("fix it")
      end
    end

    describe "billing" do
      before { stub_ask }

      let(:env) { adapter.complete(adapter_request) && seen.last[:options].env }

      it "removes the credentials that would bill the API from Claude Code's environment" do
        expect(env).to include("ANTHROPIC_API_KEY" => nil, "ANTHROPIC_AUTH_TOKEN" => nil,
          "CLAUDE_CODE_USE_BEDROCK" => nil, "CLAUDE_CODE_USE_VERTEX" => nil, "CLAUDE_CODE_USE_FOUNDRY" => nil,
          "AWS_BEARER_TOKEN_BEDROCK" => nil)
      end

      it "also removes any ANTHROPIC_* or CLAUDE_CODE_USE_* variable that is set, by prefix, but not the login token" do
        stub_const("ENV", ENV.to_h.merge(
          "ANTHROPIC_BASE_URL" => "https://gateway.example", "ANTHROPIC_FUTURE_THING" => "x",
          "CLAUDE_CODE_USE_MANTLE" => "1", "CLAUDE_CODE_OAUTH_TOKEN" => "subscription-token",
          "HOME_ANTHROPIC_X" => "y"
        ))

        expect(env).to include("ANTHROPIC_BASE_URL" => nil, "ANTHROPIC_FUTURE_THING" => nil,
          "CLAUDE_CODE_USE_MANTLE" => nil)
        expect(env.keys).not_to include("CLAUDE_CODE_OAUTH_TOKEN", "HOME_ANTHROPIC_X")
      end

      it "keeps Claude Code from reading memory files, which the setting sources don't govern" do
        expect(env).to include("CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1", "CLAUDE_CODE_DISABLE_CLAUDE_MDS" => "1")
      end

      it "leaves the credentials alone with subscription_only: false" do
        described_class.new(subscription_only: false).complete(adapter_request)

        expect(seen.last[:options].env).to eq("CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1",
          "CLAUDE_CODE_DISABLE_CLAUDE_MDS" => "1")
      end

      it "never reads or sets a subscription token itself" do
        expect(env.keys).not_to include("CLAUDE_CODE_OAUTH_TOKEN")
      end
    end

    describe "params" do
      before { stub_ask }

      it "sets Claude Code's output cap from max_output_tokens" do
        adapter.complete(adapter_request(params: { max_output_tokens: 300 }))

        expect(seen.last[:options].env).to include("CLAUDE_CODE_MAX_OUTPUT_TOKENS" => "300")
      end

      it "maps thinking: { effort: } to Claude Code's effort, and thinking: false to disabled" do
        adapter.complete(adapter_request(params: { thinking: { effort: :low } }))
        expect(seen.last[:options].effort).to eq("low")

        adapter.complete(adapter_request(params: { thinking: false }))
        expect(seen.last[:options].thinking).to eq({ type: "disabled" })
      end

      it "leaves thinking alone for true" do
        adapter.complete(adapter_request(params: { thinking: true }))

        expect(seen.last[:options]).to have_attributes(effort: nil, thinking: nil)
      end

      it "raises ConfigurationError for temperature and any other param Claude Code has no use for" do
        [{ temperature: 0.2 }, { top_p: 0.5 }].each do |params|
          expect { adapter.complete(adapter_request(params:)) }
            .to raise_error(Squishling::ConfigurationError, /Klass#call: .*takes only the max_output_tokens/)
        end
      end

      it "raises ConfigurationError for an effort Claude Code doesn't have, or other thinking options" do
        [{ thinking: { effort: :extreme } }, { thinking: { budget: 1024 } }].each do |params|
          expect { adapter.complete(adapter_request(params:)) }
            .to raise_error(Squishling::ConfigurationError, /thinking must be false or \{ effort:/)
        end
      end
    end

    describe "when Claude Code fails" do
      it "raises ConfigurationError when it isn't installed" do
        allow(ClaudeAgentSDK).to receive(:ask).and_raise(ClaudeAgentSDK::CLINotFoundError)

        expect { adapter.complete(adapter_request) }
          .to raise_error(Squishling::ConfigurationError, /Klass#call: Claude Code wasn't found.*cli_path:/)
      end

      it "raises ConfigurationError for a setup mistake in the result, and LLMError for the rest" do
        allow(ClaudeAgentSDK).to receive(:ask).and_raise(result_error(result: "Not logged in · Please run /login"))
        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::ConfigurationError, /claude auth login/)

        allow(ClaudeAgentSDK).to receive(:ask).and_raise(result_error(api_error_status: 529))
        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /HTTP 529/)
      end

      it "raises LLMError for any other Claude Agent SDK failure" do
        [ClaudeAgentSDK::ProcessError.new("SECRET", exit_code: 1),
         ClaudeAgentSDK::CLIJSONDecodeError.new("SECRET", "x"),
         ClaudeAgentSDK::ControlRequestTimeoutError.new("SECRET")].each do |error|
          allow(ClaudeAgentSDK).to receive(:ask).and_raise(error)

          expect do
            adapter.complete(adapter_request)
          end.to raise_error(Squishling::LLMError, "Klass#call: Claude Code failed to answer")
        end
      end

      it "never repeats what the SDK or Claude Code said" do
        allow(ClaudeAgentSDK).to receive(:ask).and_raise(result_error(result: "SECRET", api_error_status: 500))

        expect { adapter.complete(adapter_request) }
          .to raise_error(Squishling::LLMError) { |error| expect(error.message).not_to include("SECRET") }
      end

      it "lets an exception that isn't the SDK's propagate unwrapped" do
        allow(ClaudeAgentSDK).to receive(:ask).and_raise(NoMethodError)

        expect { adapter.complete(adapter_request) }.to raise_error(NoMethodError)
      end

      it "stops waiting after the timeout and raises LLMError, leaving no directory behind" do
        directories = []
        allow(ClaudeAgentSDK).to receive(:ask) do |_prompt, options:|
          directories << options.cwd
          sleep 5
        end
        adapter = described_class.new(timeout: 0.2)

        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /took longer than 0.2s/)
        expect(File.exist?(directories.first)).to be(false)
      end
    end

    describe "concurrency" do
      # A regression here deadlocks instead of failing an assertion, so it must not be allowed to stall the suite.
      around { |example| Timeout.timeout(10) { example.run } }

      it "runs no more claude processes at once than max_concurrency" do
        running = 0
        peak = 0
        lock = Mutex.new
        allow(ClaudeAgentSDK).to receive(:ask) do
          lock.synchronize { peak = [peak, running += 1].max }
          sleep 0.1
          lock.synchronize { running -= 1 }
          Struct.new(:structured_output, :result, :usage, :model_usage, :is_error).new({ label: "ok" }, "", nil, nil,
            false)
        end
        adapter = described_class.new(max_concurrency: 2)

        Array.new(6) { Thread.new { adapter.complete(adapter_request) } }.each(&:value)

        expect(peak).to eq(2)
      end

      it "doesn't hand out a slot twice when a thread is killed while it waits for one" do
        running = 0
        peak = 0
        lock = Mutex.new
        release = Queue.new
        allow(ClaudeAgentSDK).to receive(:ask) do
          lock.synchronize { peak = [peak, running += 1].max }
          release.pop
          lock.synchronize { running -= 1 }
          Struct.new(:structured_output, :result, :usage, :model_usage, :is_error).new({ label: "ok" }, "", nil, nil,
            false)
        end
        adapter = described_class.new(max_concurrency: 1)

        holder = Thread.new { adapter.complete(adapter_request) }
        sleep 0.05 until running == 1
        waiter = Thread.new { adapter.complete(adapter_request) }
        sleep 0.1
        waiter.kill.join
        release << true
        holder.join
        release << true << true
        Array.new(2) { Thread.new { adapter.complete(adapter_request) } }.each(&:join)

        expect(peak).to eq(1)
      end

      it "gives its slot back when a call fails, so later calls still run" do
        allow(ClaudeAgentSDK).to receive(:ask).and_raise(result_error(api_error_status: 500))
        adapter = described_class.new(max_concurrency: 1)

        3.times { expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError) }
      end
    end
  end

  describe "options" do
    it "rejects a timeout or max_concurrency that isn't a positive number" do
      [0, -1, "30", nil].each do |value|
        expect { described_class.new(timeout: value) }
          .to raise_error(Squishling::ConfigurationError, /timeout must be a positive numeric/)
      end
      [0, 1.5, "2", nil].each do |value|
        expect { described_class.new(max_concurrency: value) }
          .to raise_error(Squishling::ConfigurationError, /max_concurrency must be a positive integer/)
      end
    end

    it "rejects options it doesn't have when built from a Hash" do
      expect { Squishling.configure { |config| config.adapter = { type: :claude_code, temperature: 1 } } }
        .to raise_error(Squishling::ConfigurationError, /doesn't take temperature/)
    end
  end

  it "runs a squished class end to end, returning the same typed result as any adapter" do
    stub_ask(answer.merge(structured_output: { sentiment: "positive", note: nil }))
    Squishling.configure do |config|
      config.adapter = :claude_code
      config.default_escalation = [{ model: "haiku", attempts: 1 }]
    end
    klass = Class.new do
      include Squishling

      purpose "Classify the review."
      output_schema do
        string :sentiment, enum: %w[positive negative]
        optional(:note) { string }
      end
    end

    result = klass.call(review: "Loved it")

    expect(result).to have_attributes(sentiment: "positive", note: nil)
    expect(result.squished?).to be(true)
    expect(seen.last[:options].output_format[:schema]["properties"]["note"]["anyOf"])
      .to eq([{ "type" => "string" }, { "type" => "null" }])
  end
end
