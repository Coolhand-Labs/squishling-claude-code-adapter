# frozen_string_literal: true

module Squishling
  module ClaudeCode
    # Builds the claude-agent-sdk options for one request. Claude Code is locked down to a plain completion: no tools,
    # no user/project/local settings (so no hooks, CLAUDE.md, or MCP servers), no session saved, structured output on.
    module Options
      # ClaudeAgentOptions merges ClaudeAgentSDK.configure's global default_options into every instance, and a nil
      # means "keep the default". A host app that configured the SDK for its own agents (MCP servers, plugins,
      # allowed tools, a permission mode, a model) would then leak all of it into a call that must see nothing but
      # what Squishling sends. The SDK has no opt-out, so this skips the merge: the one place this gem overrides an SDK
      # method, guarded by a spec that sets defaults and checks none arrive.
      class Isolated < ClaudeAgentSDK::ClaudeAgentOptions
        private

        def merge_with_defaults(attributes)
          attributes
        end
      end
      private_constant :Isolated

      PORTABLE_PARAMS = %i[max_output_tokens thinking].freeze
      ISOLATION_ARGS = { "no-session-persistence" => nil, "disable-slash-commands" => nil }.freeze
      DEFAULT_INSTRUCTIONS = "Follow the user's instructions and answer with the requested JSON."
      private_constant :PORTABLE_PARAMS, :ISOLATION_ARGS, :DEFAULT_INSTRUCTIONS

      module_function

      # request: the Squishling::Adapter::Request. env: variables to set (a nil value removes one) in the claude
      # process.
      # Raises ConfigurationError for a param Claude Code can't take.
      def build(request, cli_path:, env:)
        Isolated.new(
          system_prompt: request.instructions || DEFAULT_INSTRUCTIONS, model: request.model&.to_s,
          tools: [], setting_sources: [], strict_mcp_config: true, extra_args: ISOLATION_ARGS, env:, cli_path:,
          output_format: { type: "json_schema", schema: request.schema["schema"].except("$schema") },
          **thinking(request)
        )
      end

      # Only max_output_tokens (an environment variable, set by the adapter) and thinking effort map to Claude Code.
      def thinking(request)
        params = request.params
        unsupported = params.keys - PORTABLE_PARAMS
        unless unsupported.empty?
          raise ConfigurationError, "#{request.label}: Claude Code takes only the max_output_tokens and thinking: " \
                                    "{ effort: } params, not #{unsupported.join(', ')}"
        end

        effort(request, params[:thinking])
      end

      def effort(request, thinking)
        return { thinking: { type: "disabled" } } if thinking == false
        return {} unless thinking.is_a?(Hash)

        level = thinking[:effort].to_s
        if (thinking.keys - [:effort]).any? || !ClaudeAgentSDK::EFFORT_LEVELS.include?(level)
          raise ConfigurationError,
            "#{request.label}: thinking must be false or { effort: #{ClaudeAgentSDK::EFFORT_LEVELS.join(' | ')} }"
        end

        { effort: level }
      end
    end
  end
end
