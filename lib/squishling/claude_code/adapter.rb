# frozen_string_literal: true

require "json"
require "timeout"
require "tmpdir"

module Squishling
  module ClaudeCode
    # Runs requests through the Claude Code CLI installed on this machine (`claude -p`, driven by the claude-agent-sdk
    # gem), which authenticates with your own Claude subscription: calls count against your plan's usage limits, not API
    # billing. For development, on your own machine. Claude Code is started with no tools, no settings, no MCP servers,
    # and no session, from an empty directory, so a call sees only what Squishling sends. See the README.
    #
    #   Squishling.configure do |config|
    #     config.adapter = :claude_code
    #     config.default_model = "haiku"
    #   end
    class Adapter < Squishling::Adapter::Base
      # What moves Claude Code off the subscription login: every ANTHROPIC_* variable (API keys, auth tokens, base URLs,
      # environment-selected federation and profile credentials, provider endpoints: all of which outrank or replace the
      # login) and every CLAUDE_CODE_USE_* provider switch, matched by prefix so a variable Claude Code adds later is
      # covered too, plus Bedrock's bearer token. The named ones are removed even when unset.
      BILLING_ENV_PATTERN = /\A(ANTHROPIC_|CLAUDE_CODE_USE_)/
      BILLING_ENV = %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
                       CLAUDE_CODE_USE_FOUNDRY AWS_BEARER_TOKEN_BEDROCK].freeze
      # Keep Claude Code from reading memory files, which the setting sources don't govern.
      ISOLATION_ENV = { "CLAUDE_CODE_DISABLE_AUTO_MEMORY" => "1", "CLAUDE_CODE_DISABLE_CLAUDE_MDS" => "1" }.freeze

      class TimedOut < StandardError
      end
      private_constant :BILLING_ENV_PATTERN, :BILLING_ENV, :ISOLATION_ENV, :TimedOut

      # timeout: seconds one call may take. cli_path: the claude executable (default: found on PATH, as the
      # claude-agent-sdk gem does). max_concurrency: how many claude processes this adapter runs at once, so
      # Squishling's concurrent samples don't spend your plan's limits all at once. subscription_only: remove
      # the credentials that would bill the API (ANTHROPIC_API_KEY and friends) from the claude process, so a stray
      # key can't turn subscription calls into charges. Raises ConfigurationError for a bad option.
      def initialize(timeout: 180, cli_path: nil, max_concurrency: 2, subscription_only: true)
        super()
        @timeout = positive(:timeout, timeout, Numeric)
        @cli_path = cli_path&.to_s
        @subscription_only = subscription_only != false
        @slots = Thread::SizedQueue.new(positive(:max_concurrency, max_concurrency, Integer))
        max_concurrency.times { @slots << true }
      end

      def complete(request)
        check_cli_path(request)
        options = Options.build(request, cli_path: @cli_path, env: child_env(request))
        response_for(request, run(request, options))
      rescue ClaudeAgentSDK::CLINotFoundError
        raise configuration_error(request, "Claude Code wasn't found: install it, or give the adapter a cli_path:")
      rescue ClaudeAgentSDK::ResultError => e
        raise failure_for(request, *Failure.for_result(e))
      rescue TimedOut
        raise llm_error(request, "Claude Code took longer than #{@timeout}s")
      rescue ClaudeAgentSDK::ClaudeSDKError
        raise llm_error(request, "Claude Code failed to answer")
      end

      private

      # One claude process at a time per slot, from an empty directory.
      def run(request, options)
        slot do
          Dir.mktmpdir("squishling_claude_code") do |dir|
            options.cwd = dir
            Timeout.timeout(@timeout, TimedOut) do
              ClaudeAgentSDK.ask(Conversation.prompt(request.messages), options:)
            end
          end
        end
      end

      # The slot is taken before the begin: a thread killed while it waits for one must not give back a slot it never
      # held.
      def slot
        @slots.pop
        begin
          yield
        ensure
          @slots << true
        end
      end

      # A cli_path that is an absolute file but can't be run is a setup mistake, not a failed call.
      def check_cli_path(request)
        return unless @cli_path && File.absolute_path?(@cli_path) && !File.executable?(@cli_path)

        raise configuration_error(request, "cli_path #{@cli_path.inspect} isn't an executable file")
      end

      def child_env(request)
        env = ISOLATION_ENV.dup
        env.merge!(billing_env_removals) if @subscription_only
        max = request.params[:max_output_tokens]
        env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = max.to_s if max
        env
      end

      def billing_env_removals
        (BILLING_ENV + ENV.keys.grep(BILLING_ENV_PATTERN)).uniq.to_h { |name| [name, nil] }
      end

      # An error result that came back without raising (the CLI exited cleanly) is classified like a raised one, so its
      # text is never mistaken for the model's answer.
      def response_for(request, result)
        raise failure_for(request, *Failure.for_result(result)) if result.is_error

        Squishling::Adapter::Response.new(content: content_of(result), tokens: tokens_of(result.usage),
          model: (result.model_usage&.keys&.first || request.model)&.to_s)
      end

      # The structured answer, as JSON text like every other adapter's. Without one (Claude declined) the text it wrote,
      # which Squishling reports as invalid output.
      def content_of(result)
        result.structured_output.nil? ? result.result.to_s : JSON.generate(result.structured_output)
      end

      def tokens_of(usage)
        return {} unless usage.is_a?(Hash)

        { input_tokens: usage[:input_tokens], output_tokens: usage[:output_tokens],
          cache_read_tokens: usage[:cache_read_input_tokens],
          thinking_tokens: usage.dig(:output_tokens_details, :thinking_tokens) }
          .select { |_, count| count.is_a?(Integer) }
      end

      def failure_for(request, kind, text)
        kind == :setup ? configuration_error(request, text) : llm_error(request, text)
      end

      def positive(name, value, type)
        return value if value.is_a?(type) && value.positive?

        raise ConfigurationError,
          "adapter :claude_code #{name} must be a positive #{type.name.downcase}, got #{value.inspect}"
      end
    end
  end
end
