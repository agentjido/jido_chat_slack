defmodule Jido.Chat.Slack.OptionsRoundtripTest do
  use ExUnit.Case, async: true

  test "provider options retain explicit transport settings and accept typed reuse" do
    modules = [
      Jido.Chat.Slack.DeleteOptions,
      Jido.Chat.Slack.EditOptions,
      Jido.Chat.Slack.EphemeralOptions,
      Jido.Chat.Slack.FetchOptions,
      Jido.Chat.Slack.MetadataOptions,
      Jido.Chat.Slack.ModalOptions,
      Jido.Chat.Slack.ReactionOptions,
      Jido.Chat.Slack.SendOptions
    ]

    for module <- modules do
      opts = module.new(%{token: "test", req: Req, base_url: "https://proxy.test"})
      assert module.new(opts) == opts
      assert module.schema()
      transport = module.transport_opts(opts)
      assert transport[:token] == "test"
      assert transport[:req] == Req
      assert transport[:base_url] == "https://proxy.test"
      empty = module.new([])
      refute Keyword.has_key?(module.transport_opts(empty), :token)
    end
  end
end
