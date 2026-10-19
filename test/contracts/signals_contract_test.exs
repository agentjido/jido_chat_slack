Code.require_file("support/fixtures_helper.exs", __DIR__)

defmodule Jido.Chat.Slack.SignalsContractTest do
  use Covenant.Case, component: "jido_chat_slack.signals", async: true
  alias Jido.Chat
  alias Jido.Chat.Slack.ContractFixtures, as: F

  @tag obligation: "jido_chat_slack.signals.I1"
  test "SendCard has fixed request, completion and failure identities and strict schemas" do
    expected = [
      {Chat.Slack.Signal.SendCard, "jido.chat.slack.command.send_card", "urn:jido:chat:slack:send_card:2"},
      {Chat.Slack.SendCard.Completed, "jido.chat.slack.command.send_card.completed",
       "urn:jido:chat:slack:send_card:2:completed"},
      {Chat.Slack.SendCard.Failed, "jido.chat.slack.command.send_card.failed", "urn:jido:chat:slack:send_card:2:failed"}
    ]

    assert MapSet.new(Chat.Slack.signal_definitions()) == MapSet.new(Enum.map(expected, &elem(&1, 0)))

    for {definition, type, schema} <- expected do
      assert definition.type() == type
      assert definition.dataschema() == schema
    end

    schema = Zoi.to_json_schema(Chat.Slack.Signal.SendCard.schema()) |> Jason.encode!() |> Jason.decode!()
    assert Enum.sort(schema["required"]) == ~w(card client_id request_id room_id)
    assert schema["additionalProperties"] == false
    assert Map.keys(schema["properties"]) |> Enum.sort() == ~w(card client_id request_id room_id thread_id)
  end

  @tag obligation: "jido_chat_slack.signals.I2"
  test "card constructors reject private nested data, runtime values and envelope overrides" do
    data = %{"client_id" => "alpha", "request_id" => "card", "room_id" => "C1", "card" => %{"title" => "Safe"}}

    for card <- [
          %{"token" => "never-project-this"},
          %{"metadata" => %{"secret" => "never-project-this"}},
          %{"title" => self()},
          %{"components" => [%{"kind" => "unknown"}]},
          %{"components" => [%{"kind" => "table", "columns" => ["A"], "rows" => [[1, 2]]}]}
        ] do
      assert {:error, _} = Jido.Chat.Signal.Policy.new(Chat.Slack.Signal.SendCard, %{data | "card" => card})
    end

    for opts <- [
          [type: "wrong"],
          [dataschema: "wrong"],
          [extensions: %{"handle" => "private-trigger"}],
          [source: "https://user:secret@example.test"]
        ] do
      assert {:error, _} = Jido.Chat.Signal.Policy.new(Chat.Slack.Signal.SendCard, data, opts)
    end

    assert {:ok, signal} = Jido.Chat.Signal.Policy.new(Chat.Slack.Signal.SendCard, data)
    F.round_trip(F.client(), signal)

    card = Chat.Card.new(%{title: "Form", components: [Chat.Card.text("Hello")]})

    assert {:ok, signal} =
             Jido.Chat.Signal.Policy.new(Chat.Slack.Signal.SendCard, %{data | "card" => Chat.Card.to_map(card)})

    F.round_trip(F.client(), signal)
  end

  @tag obligation: "jido_chat_slack.signals.I3"
  test "all fourteen incoming fact families match fixed fixtures and serialize without private handles" do
    client = F.client()

    types =
      for fixture <- F.incoming() do
        assert {:ok, delivery} = Chat.normalize(client, fixture["payload"])
        assert [fact] = delivery.signals
        assert fact.type == fixture["type"], fixture["name"]
        assert %Jido.Signal.Trace{} = Jido.Signal.Trace.get(fact)
        F.subset(fact.data, fixture["expected"])
        assert fact.source == client.source
        assert fact.data["delivery_id"] == delivery.id
        assert is_binary(fact.data["item_id"])

        if fact.data["room_id"],
          do: assert(fact.subject == Chat.Signal.Identity.conversation_subject(client.id, fact.data["room_id"]))

        F.round_trip(client, fact)
        fact.type
      end

    assert MapSet.new(types) == MapSet.new(Chat.Slack.Source.signal_types())
  end

  @tag obligation: "jido_chat_slack.signals.I4"
  test "normalization is stable across input forms, isolated by client, and rejects a malformed complete delivery" do
    fixture = hd(F.incoming())
    payload = fixture["payload"]
    alpha = F.client()

    variants = [
      payload,
      Jason.encode!(payload),
      URI.encode_query(%{"payload" => Jason.encode!(payload)}),
      %{payload: payload},
      %{"envelope_id" => "E1", "payload" => payload}
    ]

    signals =
      for value <- variants do
        assert {:ok, delivery} = Chat.normalize(alpha, value)
        [fact] = delivery.signals
        fact
      end

    assert Enum.uniq(Enum.map(signals, & &1.data["item_id"])) |> length() == 1
    assert {:ok, other} = Chat.normalize(F.client("beta"), payload)
    refute hd(other.signals).source == hd(signals).source
    refute hd(other.signals).subject == hd(signals).subject
    assert {:error, _} = Chat.normalize(alpha, %{"envelope_id" => "E", "payload" => 42})
    # An over-size second action cannot return a successful first-action-only delivery.
    actions = %{
      "type" => "block_actions",
      "channel" => %{"id" => "C1"},
      "user" => %{"id" => "U1"},
      "actions" => [
        %{"action_id" => "one", "value" => "safe"},
        %{"action_id" => "two", "value" => String.duplicate("x", 270_000)}
      ]
    }

    assert {:error, _} = Chat.normalize(alpha, actions)
  end
end
