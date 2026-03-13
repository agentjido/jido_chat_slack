defmodule Jido.Chat.Slack.OptionsTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Slack.{
    DeleteOptions,
    EditOptions,
    EphemeralOptions,
    FetchOptions,
    MetadataOptions,
    ModalOptions,
    ReactionOptions,
    SendOptions
  }

  test "SendOptions.new/1 normalizes keyword options into typed struct" do
    options =
      SendOptions.new(
        token: "token",
        blocks: [%{type: "section"}],
        thread_ts: "1706745600.000100",
        reply_broadcast: true,
        req: :req_module
      )

    assert options.token == "token"
    assert options.thread_ts == "1706745600.000100"

    assert %{
             "blocks" => [%{type: "section"}],
             "thread_ts" => "1706745600.000100",
             "reply_broadcast" => true
           } = SendOptions.payload_opts(options)

    assert Keyword.get(SendOptions.transport_opts(options), :token) == "token"
    assert Keyword.get(SendOptions.transport_opts(options), :req) == :req_module
  end

  test "Edit and Ephemeral options normalize payloads" do
    edit_options = EditOptions.new(token: "token", blocks: [%{type: "actions"}], req: :req_module)

    ephemeral_options =
      EphemeralOptions.new(thread_ts: "1706745600.1", attachments: [%{text: "note"}])

    assert %{"blocks" => [%{type: "actions"}]} = EditOptions.payload_opts(edit_options)

    assert %{
             "thread_ts" => "1706745600.1",
             "attachments" => [%{text: "note"}]
           } = EphemeralOptions.payload_opts(ephemeral_options)
  end

  test "Fetch, Metadata, Reaction, Delete, and Modal options normalize transport opts" do
    fetch_options =
      FetchOptions.new(
        token: "token",
        cursor: "next",
        limit: 25,
        direction: :forward,
        thread_ts: "1706745600.1",
        req: :req_module
      )

    metadata_options = MetadataOptions.new(token: "token", include_num_members: false)
    reaction_options = ReactionOptions.new(token: "token")
    delete_options = DeleteOptions.new(token: "token", req: :req_module)
    modal_options = ModalOptions.new(token: "token", trigger_id: "1337.42")

    assert Keyword.get(FetchOptions.transport_opts(fetch_options), :cursor) == "next"
    assert Keyword.get(FetchOptions.transport_opts(fetch_options), :limit) == 25
    assert Keyword.get(FetchOptions.transport_opts(fetch_options), :direction) == :forward
    assert Keyword.get(FetchOptions.transport_opts(fetch_options), :thread_ts) == "1706745600.1"

    assert Keyword.get(MetadataOptions.transport_opts(metadata_options), :include_num_members) ==
             false

    assert Keyword.get(ReactionOptions.transport_opts(reaction_options), :token) == "token"
    assert Keyword.get(DeleteOptions.transport_opts(delete_options), :req) == :req_module
    assert modal_options.trigger_id == "1337.42"
  end
end
