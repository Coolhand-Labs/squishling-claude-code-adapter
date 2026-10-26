# frozen_string_literal: true

RSpec.describe Squishling::ClaudeCode::Failure do
  def failure(result: nil, status: nil, subtype: "success")
    error = ClaudeAgentSDK::ResultError.new("boom", data: { result:, api_error_status: status, subtype:,
                                                            terminal_reason: "api_error" })
    described_class.for_result(error)
  end

  {
    "not logged in" => [{ result: "Not logged in · Please run /login" }, /isn't logged in.*claude auth login/],
    "a rejected API key" => [{ result: "Invalid API key · Fix external API key", status: 401 },
                             /subscription_only: true/],
    "refused credentials" => [{ result: "Forbidden", status: 403 }, /refused the credentials \(HTTP 403\)/],
    "an unknown model" => [{ result: "no such model", status: 404 }, /doesn't know that model/],
    "a rejected request" => [{ result: "bad request", status: 400 }, /rejected the request \(HTTP 400\)/]
  }.each do |name, (data, message)|
    it "treats #{name} as a setup mistake" do
      expect(failure(**data)).to match([:setup, message])
    end
  end

  {
    "an answer cut off by max_output_tokens" => [{ result: "exceeded the 60 output token maximum" }, /cut off/],
    "a request that doesn't fit" => [{ result: "prompt is too long", status: 400 }, /context window/],
    "a rate or usage limit" => [{ result: "limit reached", status: 429 }, /usage limit \(HTTP 429\)/],
    "a run that stopped early" => [{ subtype: "error_max_turns" }, /stopped early \(error_max_turns\)/],
    "a server error" => [{ result: "overloaded", status: 529 }, /failed \(HTTP 529\)/],
    "an error with no status" => [{}, /\AClaude Code failed\z/]
  }.each do |name, (data, message)|
    it "treats #{name} as worth another attempt" do
      expect(failure(**data)).to match([:retry, message])
    end
  end

  it "never repeats what Claude Code or the API said" do
    _, text = failure(result: "SECRET echoed request content", status: 500)

    expect(text).not_to include("SECRET")
  end
end
