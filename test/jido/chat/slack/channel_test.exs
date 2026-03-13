defmodule Jido.Chat.Slack.ChannelTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.Slack.Channel

  defmodule MockTransport do
    @behaviour Jido.Chat.Slack.Transport

    @impl true
    def send_message(channel_id, text, _opts) do
      send(self(), {:send_message, channel_id, text})
      {:ok, %{"channel" => channel_id, "ts" => "1706745600.000100"}}
    end

    @impl true
    def edit_message(channel_id, message_id, text, _opts) do
      send(self(), {:edit_message, channel_id, message_id, text})
      {:ok, %{"channel" => channel_id, "ts" => message_id}}
    end

    @impl true
    def delete_message(channel_id, message_id, _opts) do
      send(self(), {:delete_message, channel_id, message_id})
      {:ok, true}
    end

    @impl true
    def fetch_metadata(channel_id, _opts) do
      send(self(), {:fetch_metadata, channel_id})

      {:ok,
       %{
         "id" => channel_id,
         "name" => "general",
         "is_channel" => true,
         "num_members" => 12
       }}
    end

    @impl true
    def fetch_thread(channel_id, _opts) do
      send(self(), {:fetch_thread, channel_id})
      {:ok, %{"messages" => [%{"channel" => channel_id, "ts" => "1706745600.000100"}]}}
    end

    @impl true
    def fetch_message(channel_id, message_id, _opts) do
      send(self(), {:fetch_message, channel_id, message_id})

      {:ok,
       %{
         "type" => "message",
         "channel" => channel_id,
         "user" => "U123",
         "text" => "single",
         "ts" => message_id
       }}
    end

    @impl true
    def fetch_messages(channel_id, _opts) do
      send(self(), {:fetch_messages, channel_id})

      {:ok,
       %{
         "messages" => [
           %{
             "type" => "message",
             "channel" => channel_id,
             "user" => "U123",
             "text" => "history",
             "thread_ts" => "1706745600.000100",
             "ts" => "1706745601.000200"
           }
         ],
         "response_metadata" => %{"next_cursor" => "cursor-1"}
       }}
    end

    @impl true
    def fetch_channel_messages(channel_id, opts), do: fetch_messages(channel_id, opts)

    @impl true
    def list_threads(channel_id, _opts) do
      send(self(), {:list_threads, channel_id})

      {:ok,
       %{
         "threads" => [
           %{
             "type" => "message",
             "channel" => channel_id,
             "user" => "U123",
             "text" => "root",
             "thread_ts" => "1706745600.000100",
             "ts" => "1706745600.000100",
             "reply_count" => 2,
             "latest_reply" => "1706745603.000400"
           }
         ],
         "response_metadata" => %{"next_cursor" => nil}
       }}
    end

    @impl true
    def add_reaction(channel_id, message_id, emoji, _opts) do
      send(self(), {:add_reaction, channel_id, message_id, emoji})
      {:ok, true}
    end

    @impl true
    def remove_reaction(channel_id, message_id, emoji, _opts) do
      send(self(), {:remove_reaction, channel_id, message_id, emoji})
      {:ok, true}
    end

    @impl true
    def post_ephemeral(channel_id, user_id, text, _opts) do
      send(self(), {:post_ephemeral, channel_id, user_id, text})
      {:ok, %{"message_ts" => "1706745602.000300"}}
    end

    @impl true
    def open_dm(user_id, _opts) do
      send(self(), {:open_dm, user_id})
      {:ok, "D#{user_id}"}
    end

    @impl true
    def open_modal(trigger_id, payload, _opts) do
      send(self(), {:open_modal, trigger_id, payload})

      {:ok,
       %{
         "view" => %{
           "id" => "V123",
           "callback_id" => payload["callback_id"] || payload[:callback_id]
         }
       }}
    end
  end

  test "channel metadata" do
    assert Channel.channel_type() == :slack
    assert :text in Channel.capabilities()
    assert :threads in Channel.capabilities()
    assert :slash_commands in Channel.capabilities()
    refute :typing in Channel.capabilities()
  end

  test "adapter capabilities matrix declares supported surfaces" do
    caps = Jido.Chat.Slack.Adapter.capabilities()

    assert caps.send_message == :native
    assert caps.edit_message == :native
    assert caps.start_typing == :unsupported
    assert caps.open_modal == :native
    assert caps.list_threads == :native

    assert :ok = Jido.Chat.Adapter.validate_capabilities(Jido.Chat.Slack.Adapter)
  end

  test "transform_incoming/1 normalizes a slack message map" do
    message = %{
      "type" => "message",
      "channel" => "C123",
      "user" => "U123",
      "text" => "Hello <@U999>",
      "ts" => "1706745600.000100"
    }

    assert {:ok, incoming} = Channel.transform_incoming(message)
    assert incoming.external_room_id == "C123"
    assert incoming.external_user_id == "U123"
    assert incoming.text == "Hello <@U999>"
    assert incoming.chat_type == :channel
    assert incoming.channel_meta.adapter_name == :slack
    assert length(incoming.mentions) == 1
  end

  test "transform_incoming/1 extracts files as media" do
    message = %{
      "type" => "message",
      "channel" => "C123",
      "user" => "U123",
      "text" => nil,
      "ts" => "1706745600.000100",
      "files" => [
        %{
          "id" => "F1",
          "name" => "image.png",
          "mimetype" => "image/png",
          "url_private" => "https://files.slack.com/image.png"
        }
      ]
    }

    assert {:ok, incoming} = Channel.transform_incoming(message)
    assert [%{kind: :image, url: "https://files.slack.com/image.png"}] = incoming.media
  end

  test "send/edit/delete/fetch metadata methods work" do
    assert {:ok, result} = Channel.send_message("C123", "hi", transport: MockTransport)
    assert_received {:send_message, "C123", "hi"}
    assert result.message_id == "1706745600.000100"

    assert {:ok, edited} =
             Channel.edit_message("C123", "1706745600.000100", "updated",
               transport: MockTransport
             )

    assert_received {:edit_message, "C123", "1706745600.000100", "updated"}
    assert edited.message_id == "1706745600.000100"

    assert :ok = Channel.delete_message("C123", "1706745600.000100", transport: MockTransport)
    assert_received {:delete_message, "C123", "1706745600.000100"}

    assert {:ok, info} = Channel.fetch_metadata("C123", transport: MockTransport)
    assert_received {:fetch_metadata, "C123"}
    assert info.id == "C123"
    assert info.name == "general"
    assert info.member_count == 12
  end

  test "open_dm, post_ephemeral, reactions, and history helpers" do
    assert {:ok, "DU123"} = Channel.open_dm("U123", transport: MockTransport)
    assert_received {:open_dm, "U123"}

    assert {:ok, ephemeral} =
             Channel.post_ephemeral("C123", "U123", "secret", transport: MockTransport)

    assert_received {:post_ephemeral, "C123", "U123", "secret"}
    assert ephemeral.used_fallback == false
    assert ephemeral.thread_id == "slack:C123:1706745602.000300"

    assert :ok =
             Channel.add_reaction("C123", "1706745600.000100", ":wave:", transport: MockTransport)

    assert_received {:add_reaction, "C123", "1706745600.000100", ":wave:"}

    assert :ok =
             Channel.remove_reaction("C123", "1706745600.000100", ":wave:",
               transport: MockTransport
             )

    assert_received {:remove_reaction, "C123", "1706745600.000100", ":wave:"}

    assert {:ok, page} =
             Channel.fetch_messages("C123",
               transport: MockTransport,
               thread_ts: "1706745600.000100"
             )

    assert_received {:fetch_messages, "C123"}
    assert length(page.messages) == 1
    assert page.next_cursor == "cursor-1"

    assert {:ok, threads} = Channel.list_threads("C123", transport: MockTransport)
    assert_received {:list_threads, "C123"}
    assert length(threads.threads) == 1
  end

  test "open_modal/3 requires trigger_id and normalizes result" do
    assert {:ok, result} =
             Channel.open_modal(
               "C123",
               %{
                 type: "modal",
                 callback_id: "feedback",
                 title: %{type: "plain_text", text: "Feedback"}
               },
               transport: MockTransport,
               trigger_id: "1337.42"
             )

    assert result.status == :opened

    assert_received {:open_modal, "1337.42",
                     %{
                       type: "modal",
                       callback_id: "feedback",
                       title: %{type: "plain_text", text: "Feedback"}
                     }}

    assert {:error, :missing_trigger_id} =
             Channel.open_modal("C123", %{type: "modal", callback_id: "feedback"}, [])
  end

  test "handle_webhook/3 routes app_mention, slash, action, modal, and reaction events" do
    chat =
      Chat.new(user_name: "jido", adapters: %{slack: Jido.Chat.Slack.Adapter})
      |> Chat.on_new_mention(fn _thread, _incoming -> send(self(), :mention_hit) end)
      |> Chat.on_slash_command(fn _event -> send(self(), :slash_hit) end)
      |> Chat.on_action(fn _event -> send(self(), :action_hit) end)
      |> Chat.on_modal_submit(fn _event -> send(self(), :modal_submit_hit) end)
      |> Chat.on_reaction(fn _event -> send(self(), :reaction_hit) end)

    mention_payload = %{
      "type" => "event_callback",
      "event" => %{
        "type" => "app_mention",
        "channel" => "C123",
        "user" => "U123",
        "text" => "<@Ubot> ping",
        "ts" => "1706745600.000100"
      }
    }

    assert {:ok, _chat, %Jido.Chat.Incoming{} = incoming} =
             Channel.handle_webhook(chat, mention_payload, [])

    assert incoming.external_message_id == "1706745600.000100"
    assert_received :mention_hit

    slash_payload = %{
      "command" => "/help",
      "text" => "topic",
      "channel_id" => "C123",
      "user_id" => "U123",
      "user_name" => "alice",
      "trigger_id" => "1337.42"
    }

    assert {:ok, _chat, _incoming} = Channel.handle_webhook(chat, slash_payload, [])
    assert_received :slash_hit

    action_payload =
      Jason.encode!(%{
        "type" => "block_actions",
        "trigger_id" => "1337.43",
        "user" => %{"id" => "U123", "username" => "alice"},
        "channel" => %{"id" => "C123"},
        "container" => %{"message_ts" => "1706745600.000100"},
        "message" => %{"ts" => "1706745600.000100"},
        "actions" => [%{"action_id" => "approve", "value" => "yes"}]
      })

    assert {:ok, _chat, _incoming} =
             Channel.handle_webhook(chat, %{"payload" => action_payload}, [])

    assert_received :action_hit

    modal_payload =
      Jason.encode!(%{
        "type" => "view_submission",
        "user" => %{"id" => "U123", "username" => "alice"},
        "view" => %{
          "id" => "V123",
          "callback_id" => "feedback",
          "state" => %{
            "values" => %{
              "block_1" => %{"notes" => %{"type" => "plain_text_input", "value" => "great"}}
            }
          }
        }
      })

    assert {:ok, _chat, _incoming} =
             Channel.handle_webhook(chat, %{"payload" => modal_payload}, [])

    assert_received :modal_submit_hit

    reaction_payload = %{
      "type" => "event_callback",
      "event" => %{
        "type" => "reaction_added",
        "user" => "U123",
        "reaction" => "wave",
        "item" => %{"type" => "message", "channel" => "C123", "ts" => "1706745600.000100"}
      }
    }

    assert {:ok, _chat, _incoming} = Channel.handle_webhook(chat, reaction_payload, [])
    assert_received :reaction_hit
  end

  test "parse_event/2 noop and webhook response handle Slack url verification" do
    request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :slack,
        payload: %{"type" => "url_verification", "challenge" => "hello-challenge"}
      })

    assert {:ok, :noop} = Jido.Chat.Slack.Adapter.parse_event(request, [])

    response =
      Jido.Chat.Slack.Adapter.format_webhook_response(
        {:ok, Chat.new(adapters: %{slack: Jido.Chat.Slack.Adapter}), :noop},
        request: request
      )

    assert response.body == "hello-challenge"
  end

  test "handle_webhook/3 fails closed when signature verification fails" do
    chat = Chat.new(adapters: %{slack: Jido.Chat.Slack.Adapter})
    raw_body = Jason.encode!(%{"command" => "/help", "channel_id" => "C123", "user_id" => "U123"})

    assert {:error, :invalid_signature} =
             Channel.handle_webhook(
               chat,
               %{"command" => "/help", "channel_id" => "C123", "user_id" => "U123"},
               signing_secret: "secret",
               headers: %{
                 "x-slack-signature" => "v0=bad",
                 "x-slack-request-timestamp" => Integer.to_string(System.os_time(:second))
               },
               raw_body: raw_body
             )
  end
end
