defmodule Jido.Chat.Slack.MessageLifecycleEventTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.{EventEnvelope, MessageDeletedEvent, MessageUpdatedEvent, WebhookRequest}
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

    assert {:ok,
            %EventEnvelope{
              event_type: :message_updated,
              payload: %MessageUpdatedEvent{} = event
            } = envelope} = parse(payload)

    assert envelope.channel_id == "C123"
    assert envelope.thread_id == "slack:C123:1706745500.000010"
    assert envelope.message_id == "1706745600.000100"
    assert envelope.raw == payload

    assert event.adapter_name == :slack
    assert event.channel_id == "C123"
    assert event.thread_id == "slack:C123:1706745500.000010"
    assert event.message_id == "1706745600.000100"
    assert event.timestamp == "1706745700.000200"
    assert event.author.user_id == "U123"
    assert event.author.user_name == "alice"
    assert event.message.text == "after"
    assert event.message.external_message_id == "1706745600.000100"
    assert event.message.external_room_id == "C123"
    assert event.metadata.previous_message == previous_message
    assert event.metadata.event_id == "Ev-update-1"
    assert event.raw == payload
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

    assert {:ok, %EventEnvelope{payload: %MessageUpdatedEvent{} = event}} = parse(payload)

    assert event.message_id == "1706745750.000250"
    assert event.thread_id == "slack:C234"
    assert event.author.user_id == "bot:B234"
    assert event.message.author.user_id == "bot:B234"
    assert event.message.text == "updated by bot"
    assert event.raw == payload
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

    assert {:ok,
            %EventEnvelope{
              event_type: :message_deleted,
              payload: %MessageDeletedEvent{} = event
            } = envelope} = parse(payload)

    assert envelope.channel_id == "C345"
    assert envelope.thread_id == "slack:C345:1706745900.000400"
    assert envelope.message_id == "1706745950.000450"
    assert envelope.raw == payload

    assert event.message_id == "1706745950.000450"
    assert event.timestamp == "1706746000.000500"
    assert event.author.user_id == "U345"
    assert event.author.user_name == "casey"
    assert event.message == nil
    assert event.metadata.previous_message == previous_message
    assert event.metadata.event_id == "Ev-delete-1"
    assert event.raw == payload
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

    assert {:ok, %EventEnvelope{payload: %MessageDeletedEvent{} = event}} = parse(payload)

    assert event.message_id == "1706746100.000600"
    assert event.thread_id == "slack:C456"
    assert event.author == nil
    assert event.message == nil
    assert event.raw == payload
  end

  test "routes lifecycle callbacks only to lifecycle handlers and preserves create routing" do
    chat =
      Chat.new(adapters: %{slack: Adapter})
      |> Chat.on_new_message(~r/.*/, fn _thread, incoming ->
        send(self(), {:new_message, incoming.external_message_id})
      end)
      |> Chat.on_message_updated(fn event ->
        send(self(), {:message_updated, event.message_id})
      end)

    update_payload = %{
      "type" => "event_callback",
      "event" => %{
        "type" => "message",
        "subtype" => "message_changed",
        "channel" => "C567",
        "message" => %{
          "type" => "message",
          "user" => "U567",
          "text" => "edited",
          "ts" => "1706746200.000700"
        }
      }
    }

    assert {:ok, update_result} = Chat.route_request(chat, :slack, update_payload)
    assert update_result.event.event_type == :message_updated
    assert_received {:message_updated, "1706746200.000700"}
    refute_received {:new_message, _}

    create_payload = %{
      "type" => "event_callback",
      "event" => %{
        "type" => "message",
        "channel" => "C567",
        "user" => "U567",
        "text" => "new",
        "ts" => "1706746300.000800"
      }
    }

    assert {:ok, create_result} = Chat.route_request(update_result.chat, :slack, create_payload)
    assert create_result.event.event_type == :message
    assert_received {:new_message, "1706746300.000800"}
  end

  defp parse(payload) do
    request =
      WebhookRequest.new(%{
        adapter_name: :slack,
        path: "/slack/events",
        payload: payload,
        raw: payload
      })

    Adapter.parse_event(request, [])
  end
end
