defmodule Jido.Chat.Slack.MessageLifecycleEventTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.Slack.Adapter

  test "parses a Slack message_changed callback into a typed update event" do
    previous_message = %{
      "type" => "message",
      "user" => "U123",
      "text" => "before",
      "thread_ts" => "1706745500.000010",
      "ts" => "1706745600.000100"
    }

    payload = %{
      "type" => "event_callback",
      "event_id" => "Ev-update-1",
      "event" => %{
        "type" => "message",
        "subtype" => "message_changed",
        "channel" => "C123",
        "event_ts" => "1706745700.000200",
        "message" => %{
          "type" => "message",
          "user" => "U123",
          "username" => "alice",
          "text" => "after",
          "thread_ts" => "1706745500.000010",
          "ts" => "1706745600.000100"
        },
        "previous_message" => previous_message
      },
      "team_id" => "T123"
    }

    assert {:ok, binding, event} = parse(payload)
    assert event.type == "jido.chat.message.updated"
    assert event.data["room_id"] == "C123"
    assert event.data["thread_id"] == "1706745500.000010"
    assert event.data["message_id"] == "1706745600.000100"
    assert event.data["timestamp"] == "1706745700.000200"
    assert event.data["sender"]["id"] == "U123"
    assert event.data["sender"]["username"] == "alice"
    assert event.data["text"] == "after"
    assert event.source == binding.source
    assert event.data["item_id"] =~ "Ev-update-1"
    refute Map.has_key?(event.data, "raw")
    refute Map.has_key?(event.data, "previous_message")
    assert {:ok, wire} = Jido.Signal.Serialization.serialize(event)
    refute wire =~ "before"
  end

  test "accepts atom-key Slack provider maps for message_changed" do
    payload = %{
      type: "event_callback",
      event_id: "Ev-update-atom",
      event: %{
        type: :message,
        subtype: :message_changed,
        channel: "C234",
        event_ts: "1706745800.000300",
        message: %{
          type: "message",
          text: "updated by bot",
          ts: "1706745750.000250"
        },
        previous_message: %{
          type: "message",
          bot_id: "B234",
          username: "helper",
          text: "old"
        }
      }
    }

    assert {:ok, binding, event} = parse(payload)
    assert event.type == "jido.chat.message.updated"
    assert event.data["message_id"] == "1706745750.000250"
    assert event.data["thread_id"] == nil
    assert event.subject == Jido.Chat.Signal.Identity.conversation_subject(binding.id, "C234")
    assert event.data["sender"]["id"] == "bot:B234"
    assert event.data["sender"]["username"] == "helper"
    assert event.data["text"] == "updated by bot"
    refute Map.has_key?(event.data, "raw")
  end

  test "parses a Slack message_deleted callback without deleted content" do
    previous_message = %{
      "type" => "message",
      "user" => "U345",
      "username" => "casey",
      "text" => "deleted text must not become lifecycle content",
      "thread_ts" => "1706745900.000400",
      "ts" => "1706745950.000450"
    }

    payload = %{
      "type" => "event_callback",
      "event_id" => "Ev-delete-1",
      "event" => %{
        "type" => "message",
        "subtype" => "message_deleted",
        "channel" => "C345",
        "deleted_ts" => "1706745950.000450",
        "event_ts" => "1706746000.000500",
        "previous_message" => previous_message
      }
    }

    assert {:ok, binding, event} = parse(payload)
    assert event.type == "jido.chat.message.deleted"
    assert event.data["room_id"] == "C345"
    assert event.data["thread_id"] == "1706745900.000400"
    assert event.data["message_id"] == "1706745950.000450"
    assert event.data["timestamp"] == "1706746000.000500"
    assert event.source == binding.source
    assert event.data["item_id"] =~ "Ev-delete-1"
    refute Map.has_key?(event.data, "text")
    refute Map.has_key?(event.data, "raw")
    refute Map.has_key?(event.data, "previous_message")
    assert {:ok, wire} = Jido.Signal.Serialization.serialize(event)
    refute wire =~ "deleted text must not become lifecycle content"
  end

  test "accepts a minimal atom-key delete and keeps unavailable values absent" do
    payload = %{
      type: "event_callback",
      event: %{
        type: :message,
        subtype: :message_deleted,
        channel: "C456",
        deleted_ts: "1706746100.000600"
      }
    }

    assert {:ok, binding, event} = parse(payload)
    assert event.type == "jido.chat.message.deleted"
    assert event.data["message_id"] == "1706746100.000600"
    assert event.data["thread_id"] == nil
    assert event.subject == Jido.Chat.Signal.Identity.conversation_subject(binding.id, "C456")
    refute Map.has_key?(event.data, "sender")
    refute Map.has_key?(event.data, "text")
    refute Map.has_key?(event.data, "raw")
  end

  defp parse(payload) do
    request =
      Map.new(%{
        adapter_name: :slack,
        path: "/slack/events",
        payload: payload,
        raw: payload
      })

    {:ok, binding} = Jido.Chat.Client.new(Adapter, id: "lifecycle", credentials: %{token: "fixture-token"})
    with {:ok, %{signals: [event]}} <- Chat.normalize(binding, request), do: {:ok, binding, event}
  end
end
