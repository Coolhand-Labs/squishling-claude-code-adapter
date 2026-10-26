# frozen_string_literal: true

module Squishling
  module ClaudeCode
    # Decides what a failed Claude Code run means to Squishling: a setup mistake (:setup, never retried) or something
    # another attempt may get past (:retry). Only fixed texts come back: what Claude Code or the API said is read to
    # decide, never repeated, since it can echo the request.
    module Failure
      NOT_LOGGED_IN = %r{not logged in|please run /login}i
      API_KEY_REJECTED = /invalid api key/i
      OUTPUT_CUT_OFF = /output token maximum/i
      TOO_LONG = /too long|context (length|window)|too many tokens/i
      private_constant :NOT_LOGGED_IN, :API_KEY_REJECTED, :OUTPUT_CUT_OFF, :TOO_LONG

      module_function

      # error: a ClaudeAgentSDK::ResultError, or a ResultMessage with is_error set (both answer result, subtype, and
      # api_error_status). Returns [:setup | :retry, text].
      def for_result(error)
        status = error.api_error_status
        text = error.result.to_s
        setup(status, text) || [:retry, retryable(status, text, error.subtype)]
      end

      def setup(status, text)
        return [:setup, api_key_rejected] if text.match?(API_KEY_REJECTED)
        return [:setup, "Claude Code isn't logged in: run `claude auth login`"] if text.match?(NOT_LOGGED_IN)
        return [:setup, "Claude Code refused the credentials (HTTP #{status})"] if [401, 403].include?(status)
        return [:setup, "Claude Code doesn't know that model: check model:"] if status == 404

        [:setup, "Claude Code rejected the request (HTTP 400)"] if status == 400 && !text.match?(TOO_LONG)
      end

      def api_key_rejected
        "Claude Code was refused the API key it was given; for subscription use leave subscription_only: true, " \
          "which removes ANTHROPIC_API_KEY"
      end

      def retryable(status, text, subtype)
        return "the answer was cut off at max_output_tokens" if text.match?(OUTPUT_CUT_OFF)
        return "the request didn't fit the model's context window" if text.match?(TOO_LONG)
        return "Claude Code hit a rate or usage limit (HTTP 429): your plan's limit may be used up" if status == 429
        return "Claude Code stopped early (#{subtype})" if subtype.to_s.start_with?("error_")

        status ? "Claude Code failed (HTTP #{status})" : "Claude Code failed"
      end
      private_class_method :setup, :api_key_rejected, :retryable
    end
  end
end
