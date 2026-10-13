defmodule Jido.Chat.Slack.NormalizerTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.{Delivery, Resources, WebhookRequest}
  alias Jido.Chat.Slack.Normalizer

  defmodule FixtureAdapter do
    def channel_type, do: :slack
    def signal_protocol, do: 1
    def configure_binding(opts), do: {:ok, opts}
    def normalize_event(binding, input), do: Normalizer.normalize(binding, input)
  end

  setup do
    {:ok, binding} = Jido.Chat.bind(FixtureAdapter, id: "slack-native", bot_user_id: "UBOT")
    %{binding: binding}
  end

  defp callback(event), do: %{"type" => "event_callback", "event_id" => "Ev1", "event" => event}

  defp message(extra \\ %{}),
    do: Map.merge(%{"type" => "message", "channel" => "C1", "user" => "U1", "ts" => "1.01", "text" => "hello"}, extra)

  defp normalized(binding, payload) do
    assert {:ok, %Delivery{} = delivery} = Normalizer.normalize(binding, payload)
    catalog = Jido.Signal.Catalog.new!(Jido.Chat.signal_definitions())

    for fact <- delivery.signals do
      assert {:ok, json} = Jido.Signal.Serialization.serialize(fact)
      assert {:ok, ^fact} = Jido.Signal.Catalog.decode(catalog, json)
      refute Map.has_key?(fact.data, "raw")
      refute json =~ "private-trigger"
      refute json =~ "https://private-response"
    end

    delivery
  end

  test "webhook, JSON, form, and Socket Mode use one message mapper", %{binding: binding} do
    payload = callback(message())

    variants = [
      payload,
      Jason.encode!(payload),
      URI.encode_query(%{"payload" => Jason.encode!(payload)}),
      WebhookRequest.new(%{payload: payload}),
      %{"type" => "events_api", "envelope_id" => "socket-1", "payload" => payload}
    ]

    units = Enum.map(variants, &normalized(binding, &1))
    assert Enum.all?(units, &(hd(&1.signals).type == "jido.chat.message.received"))
    assert Enum.uniq(Enum.map(units, &hd(&1.signals).data["item_id"])) |> length() == 1
    assert List.last(units).id != hd(units).id
  end

  test "message updates and deletes retain provider lifecycle distinctions", %{binding: binding} do
    updated = %{
      "type" => "message",
      "subtype" => "message_changed",
      "channel" => "C1",
      "message" => %{"ts" => "1.01", "text" => "after", "user" => "U1"},
      "previous_message" => %{"ts" => "1.01", "thread_ts" => "0.99"}
    }

    [fact] = normalized(binding, callback(updated)).signals
    assert fact.type == "jido.chat.message.updated"
    assert fact.data["thread_id"] == "0.99"
    assert fact.data["text"] == "after"

    [deleted] =
      normalized(
        binding,
        callback(%{"type" => "message", "subtype" => "message_deleted", "channel" => "C1", "deleted_ts" => "1.01"})
      ).signals

    assert deleted.type == "jido.chat.message.deleted"
    assert deleted.data["message_id"] == "1.01"
  end

  test "app mentions remain message facts with mention details", %{binding: binding} do
    [fact] = normalized(binding, callback(message(%{"type" => "app_mention", "text" => "<@UBOT> hello"}))).signals
    assert fact.type == "jido.chat.message.received"
    assert fact.data["mentioned"]
    assert fact.data["mentions"] == ["UBOT"]
  end

  for {type, transition, status, is_member} <- [
        {"member_joined_channel", "joined", "member", true},
        {"member_left_channel", "left", "left", false}
      ] do
    test "#{type} retains partial prior state and absent actor", %{binding: binding} do
      [fact] = normalized(binding, callback(%{"type" => unquote(type), "channel" => "C1", "user" => "U1"})).signals
      assert fact.type == "jido.chat.membership.changed"
      assert fact.data["transition"] == unquote(transition)
      assert fact.data["previous"] == nil
      assert fact.data["actor_id"] == nil
      assert fact.data["current"] == %{"status" => unquote(status), "is_member" => unquote(is_member)}
    end
  end

  test "reaction add and remove each select their registered fact", %{binding: binding} do
    for {type, expected} <- [
          {"reaction_added", "jido.chat.reaction.added"},
          {"reaction_removed", "jido.chat.reaction.removed"}
        ] do
      [fact] =
        normalized(
          binding,
          callback(%{
            "type" => type,
            "user" => "U1",
            "reaction" => "thumbsup",
            "item" => %{"channel" => "C1", "ts" => "1.01"}
          })
        ).signals

      assert fact.type == expected
      assert fact.data["reaction"] == "thumbsup"
    end
  end

  test "all block actions are retained and transient controls stay private", %{binding: binding} do
    payload = %{
      "type" => "block_actions",
      "channel" => %{"id" => "C1"},
      "user" => %{"id" => "U1"},
      "trigger_id" => "private-trigger",
      "response_url" => "https://private-response",
      "actions" => [
        %{"action_id" => "first", "value" => "yes"},
        %{"action_id" => "second", "selected_users" => ["U2", "U3"]}
      ]
    }

    facts = normalized(binding, payload).signals
    assert Enum.map(facts, & &1.data["action_id"]) == ["first", "second"]
    assert Enum.at(facts, 1).data["values"]["second"] == ["U2", "U3"]
    assert {:ok, controls} = Normalizer.interaction(binding, hd(facts).data["interaction_id"])
    assert controls["trigger_id"] == "private-trigger"
    assert controls["response_url"] == "https://private-response"
    result = Task.async(fn -> Normalizer.interaction(binding, hd(facts).data["interaction_id"]) end) |> Task.await()
    assert {:error, %Jido.Chat.Errors.Contract{code: :resource_owner_mismatch}} = result
  end

  test "modal submissions and closes retain values in the declared conversation context", %{binding: binding} do
    view = %{
      "id" => "V1",
      "callback_id" => "modal",
      "private_metadata" => Jason.encode!(%{"channel_id" => "C1"}),
      "state" => %{"values" => %{"block" => %{"choice" => %{"selected_option" => %{"value" => "yes"}}}}}
    }

    [submitted] = normalized(binding, %{"type" => "view_submission", "view" => view, "user" => %{"id" => "U1"}}).signals
    assert submitted.type == "jido.chat.modal.submitted"
    assert submitted.data["values"] == %{"choice" => "yes"}
    [closed] = normalized(binding, %{"type" => "view_closed", "view" => view}).signals
    assert closed.type == "jido.chat.modal.closed"
  end

  test "external options and slash requests retain typed portable data", %{binding: binding} do
    [options] =
      normalized(binding, %{
        "type" => "block_suggestion",
        "channel" => %{"id" => "C1"},
        "action_id" => "select",
        "value" => "query"
      }).signals

    assert options.type == "jido.chat.options.requested"
    assert options.data["query"] == "query"

    [slash] =
      normalized(binding, %{
        "command" => "/help",
        "channel_id" => "C1",
        "user_id" => "U1",
        "text" => "args",
        "trigger_id" => "private-trigger"
      }).signals

    assert slash.type == "jido.chat.slash_command.received"
    assert slash.data["text"] == "args"
  end

  test "assistant thread and context events use their native schemas", %{binding: binding} do
    for {type, expected} <- [
          {"assistant_thread_started", "jido.chat.assistant.thread_started"},
          {"assistant_thread_context_changed", "jido.chat.assistant.context_changed"}
        ] do
      [fact] =
        normalized(
          binding,
          callback(%{
            "type" => type,
            "assistant_thread" => %{
              "channel_id" => "D1",
              "thread_ts" => "1.01",
              "context" => %{"channel_id" => "C1", "team_id" => "T1"}
            }
          })
        ).signals

      assert fact.type == expected
      assert fact.data["thread_id"] == "1.01"
    end
  end

  test "media links stay private behind scoped references", %{binding: binding} do
    [fact] =
      normalized(
        binding,
        callback(
          message(%{
            "files" => [
              %{"id" => "F1", "name" => "file.png", "mimetype" => "image/png", "url_private" => "https://private-file"}
            ]
          })
        )
      ).signals

    assert [media] = fact.data["media"]
    assert media["kind"] == "image"
    assert {:ok, %{url: "https://private-file"}} = Resources.resolve(binding, media["resource_ref"])
    refute Jason.encode!(fact.data) =~ "https://private-file"
  end

  test "unknown and malformed items have typed failures; size rejection keeps the complete unit", %{binding: binding} do
    assert normalized(binding, %{"type" => "url_verification", "challenge" => "private"}).signals == []
    [unsupported] = normalized(binding, callback(%{"type" => "unknown"})).signals
    assert unsupported.type == "jido.chat.normalization.failed"
    [invalid] = normalized(binding, callback(message(%{"user" => nil, "ts" => nil}))).signals
    assert invalid.type == "jido.chat.normalization.failed"

    assert {:error, %Jido.Chat.Errors.Contract{code: :signal_too_large}} =
             Normalizer.normalize(binding, callback(message(%{"text" => String.duplicate("x", 262_144)})))
  end

  test "valid actions remain ordered around a malformed action", %{binding: binding} do
    actions = [
      %{"action_id" => "first", "value" => "yes"},
      %{"value" => "invalid"},
      %{"action_id" => "third", "value" => "yes"}
    ]

    facts =
      normalized(binding, %{"type" => "block_actions", "channel" => %{"id" => "C1"}, "actions" => actions}).signals

    assert Enum.map(facts, & &1.type) == [
             "jido.chat.action.received",
             "jido.chat.normalization.failed",
             "jido.chat.action.received"
           ]

    assert hd(facts).data["action_id"] == "first"
    assert List.last(facts).data["action_id"] == "third"
    assert length(Enum.uniq(Enum.map(facts, & &1.data["item_id"]))) == 3
  end

  test "action count and failure count breaches reject the whole delivery", %{binding: binding} do
    for {actions, code} <- [
          {Enum.map(1..101, &%{"action_id" => Integer.to_string(&1)}), :too_many_signals},
          {Enum.map(1..21, &%{"value" => Integer.to_string(&1)}), :too_many_failures}
        ] do
      assert {:error, %Jido.Chat.Errors.Contract{code: ^code}} =
               Normalizer.normalize(binding, %{
                 "type" => "block_actions",
                 "channel" => %{"id" => "C1"},
                 "actions" => actions
               })
    end
  end

  test "failed complete units cancel private interaction values", %{binding: binding} do
    actions = Enum.map(1..101, &%{"action_id" => Integer.to_string(&1)})

    assert {:error, _} =
             Normalizer.normalize(binding, %{
               "type" => "block_actions",
               "channel" => %{"id" => "C1"},
               "trigger_id" => "private-trigger",
               "actions" => actions
             })

    resources = Enum.filter(:ets.tab2list(binding.resources), &(elem(elem(&1, 0), 0) == :resource))
    assert [{{:resource, _}, _, "result", nil, _, :cancelled}] = resources
  end
end
