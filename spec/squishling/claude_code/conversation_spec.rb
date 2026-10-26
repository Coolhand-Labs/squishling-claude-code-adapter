# frozen_string_literal: true

RSpec.describe Squishling::ClaudeCode::Conversation do
  it "is just the message for a first attempt" do
    expect(described_class.prompt([{ role: :user, content: "classify this" }])).to eq("classify this")
  end

  it "replays the earlier turns, then asks for the latest message, on a retry" do
    prompt = described_class.prompt([{ role: :user, content: "first" }, { role: :assistant, content: '{"a":1}' },
                                     { role: :user, content: "that was invalid: fix it" }])

    expect(prompt).to eq("The conversation so far:\n\n[user]\nfirst\n\n[assistant]\n{\"a\":1}\n\n" \
                         "Respond to the latest message:\n\nthat was invalid: fix it")
  end
end
