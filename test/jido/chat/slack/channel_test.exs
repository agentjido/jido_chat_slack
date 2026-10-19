defmodule Jido.Chat.Slack.AdapterSurfaceTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.Slack.Adapter
  alias Jido.Chat.Slack.AdapterSurfaceTest.MockTransport

  defp captured_binding(extra \\ []) do
    {:ok, binding} =
      new_client(
        Adapter,
        Keyword.merge(
          [
            id: "surface",
            token: "fixture-token",
            transport: Jido.Chat.Slack.AdapterSurfaceTest.MockTransport,
            bot_user_id: "Ubot"
          ],
          extra
        )
      )

    binding
  end

  defp native_message(payload) do
    binding = captured_binding()
    {:ok, %{signals: [fact]}} = Chat.normalize(binding, payload)
    {binding, fact}
  end

  setup_all do
    Code.ensure_loaded!(Adapter)
    :ok
  end

  defmodule PaginatedParticipantsTransport do
    def fetch_messages("C123", opts) do
      send(self(), {:participant_page, opts[:cursor], opts[:limit]})

      case opts[:cursor] do
        nil ->
          {:ok,
           %{
             "messages" => [
               %{"user" => "U1", "ts" => "1"},
               %{"user" => "U1", "ts" => "2"}
             ],
             "response_metadata" => %{"next_cursor" => "page-2"}
           }}

        "page-2" ->
          {:ok,
           %{
             "messages" => [
               %{"user" => "U2", "ts" => "3"},
               %{
                 "bot_id" => "B1",
                 "username" => "deploy-bot",
                 "bot_profile" => %{"name" => "Deploy Bot", "icons" => %{"image_72" => "bot.png"}},
                 "ts" => "4"
               }
             ],
             "response_metadata" => %{"next_cursor" => ""}
           }}
      end
    end

    def get_user(user_id, _opts) do
      {:ok,
       %{
         "id" => user_id,
         "name" => String.downcase(user_id),
         "profile" => %{"display_name" => "Person #{user_id}"}
       }}
    end
  end

  defmodule MalformedUserTransport do
    def get_user(_user_id, _opts), do: {:ok, "U123"}
  end

  defmodule FailingUserTransport do
    def get_user(_user_id, _opts), do: {:error, :provider_down}
  end

  defmodule ChannelOmittingTransport do
    @behaviour Jido.Chat.Slack.Transport

    @impl true
    def send_message(_channel_id, _text, _opts), do: {:error, :unsupported}

    @impl true
    def send_file(_channel_id, _upload, _opts), do: {:error, :unsupported}

    @impl true
    def edit_message(_channel_id, _message_id, _text, _opts), do: {:error, :unsupported}

    @impl true
    def delete_message(_channel_id, _message_id, _opts), do: {:error, :unsupported}

    @impl true
    def fetch_metadata(_channel_id, _opts), do: {:error, :unsupported}

    @impl true
    def fetch_thread(_channel_id, _opts), do: {:error, :unsupported}

    @impl true
    def fetch_message(channel_id, message_id, _opts) do
      send(self(), {:fetch_message_without_channel, channel_id, message_id})

      {:ok,
       %{
         "type" => "message",
         "user" => "U123",
         "text" => "single",
         "ts" => message_id
       }}
    end

    @impl true
    def get_user(_user_id, _opts), do: {:error, :unsupported}

    @impl true
    def get_permalink(_channel_id, _message_id, _opts), do: {:error, :unsupported}

    @impl true
    def mark_as_read(_channel_id, _message_id, _opts), do: {:error, :unsupported}

    @impl true
    def download_file(_url, _opts), do: {:error, :unsupported}

    @impl true
    def fetch_messages(_channel_id, _opts), do: {:error, :unsupported}

    @impl true
    def fetch_channel_messages(_channel_id, _opts), do: {:error, :unsupported}

    @impl true
    def list_threads(_channel_id, _opts), do: {:error, :unsupported}

    @impl true
    def add_reaction(_channel_id, _message_id, _emoji, _opts), do: {:error, :unsupported}

    @impl true
    def remove_reaction(_channel_id, _message_id, _emoji, _opts), do: {:error, :unsupported}

    @impl true
    def post_ephemeral(_channel_id, _user_id, _text, _opts), do: {:error, :unsupported}

    @impl true
    def open_dm(_user_id, _opts), do: {:error, :unsupported}

    @impl true
    def open_modal(_trigger_id, _payload, _opts), do: {:error, :unsupported}
  end

  test "channel metadata" do
    caps = Adapter.capabilities()

    assert Adapter.channel_type() == :slack
    assert caps.send_message == :native
    assert caps.send_file == :native
    assert caps.edit_message == :native
    assert caps.create_thread == :unsupported
    assert caps.start_typing == :unsupported
    assert caps.download_file == :native
  end

  test "adapter capabilities matrix declares supported surfaces" do
    caps = Jido.Chat.Slack.Adapter.capabilities()

    assert caps.send_message == :native
    assert caps.send_file == :native
    assert caps.edit_message == :native
    assert caps.start_typing == :unsupported
    assert caps.open_modal == :native
    assert caps.list_threads == :native
    assert caps.get_user == :native
    assert caps.fetch_subject == :native
    assert caps.get_thread_participants == :native
    assert caps.mark_as_read == :native

    assert :ok = Jido.Chat.Adapter.validate_capabilities(Jido.Chat.Slack.Adapter)
  end

  test "get_user/2 returns normalized Slack user information" do
    assert {:ok,
            %{
              id: "U123",
              username: "u123",
              display_name: "Display U123",
              email: "u123@example.test",
              avatar_url: "https://example.test/U123.png",
              is_bot: false
            }} = Jido.Chat.Slack.Operations.get_user("U123", transport: MockTransport)

    assert_received {:get_user, "U123"}
  end

  test "get_user/2 rejects malformed successful transport responses" do
    assert {:error, :invalid_user_response} =
             Jido.Chat.Slack.Operations.get_user("U123", transport: MalformedUserTransport)
  end

  test "get_user/2 preserves transport errors" do
    assert {:error, :provider_down} = Jido.Chat.Slack.Operations.get_user("U123", transport: FailingUserTransport)
  end

  test "fetch_subject/2 returns channel and thread subjects" do
    assert {:ok,
            %{
              type: "slack_channel",
              id: "C123",
              title: "Release coordination",
              status: "open"
            }} = Jido.Chat.Slack.Operations.fetch_subject("C123", transport: MockTransport)

    assert {:ok,
            %{
              type: "slack_thread",
              id: "1706745600.000100",
              title: "single",
              url: "https://workspace.slack.com/archives/C123/p1706745600.000100",
              status: "open"
            }} =
             Jido.Chat.Slack.Operations.fetch_subject("C123",
               external_thread_id: "1706745600.000100",
               transport: MockTransport
             )

    assert_received {:fetch_message, "C123", "1706745600.000100", fetch_opts}
    assert fetch_opts[:thread_ts] == "1706745600.000100"
    assert fetch_opts[:limit] == 1
  end

  test "get_thread_participants/2 follows cursors, de-duplicates users, and includes bots" do
    assert {:ok,
            %{
              participants: [
                %{id: "U1", is_bot: false},
                %{id: "U2", is_bot: false},
                %{id: "B1", is_bot: true}
              ],
              complete: false,
              scope: "observed"
            }} =
             Jido.Chat.Slack.Operations.get_thread_participants("C123",
               external_thread_id: "1",
               transport: PaginatedParticipantsTransport,
               limit: 3,
               page_size: 2
             )

    assert_received {:participant_page, nil, 2}
    assert_received {:participant_page, "page-2", 2}
  end

  test "get_thread_participants/2 enforces participant and page limits" do
    assert {:ok, %{participants: [%{id: "U1"}], complete: false}} =
             Jido.Chat.Slack.Operations.get_thread_participants("C123",
               external_thread_id: "1",
               transport: PaginatedParticipantsTransport,
               limit: 1
             )

    assert {:error, :participant_page_limit_exceeded} =
             Jido.Chat.Slack.Operations.get_thread_participants("C123",
               external_thread_id: "1",
               transport: PaginatedParticipantsTransport,
               limit: 3,
               max_pages: 1
             )
  end

  test "native thread requests pass the external Slack timestamp to resource helpers" do
    subject_binding = captured_binding()

    request =
      Jido.Chat.Signal.FetchSubject.new!(%{
        "client_id" => subject_binding.id,
        "request_id" => "subject",
        "room_id" => "C123",
        "thread_id" => "1"
      })

    assert {:ok, subject} = Chat.execute(subject_binding, request)
    assert subject.data["result"]["id"] == "1"
    assert subject.data["result"]["kind"] == "thread"
    participants_binding = captured_binding(transport: PaginatedParticipantsTransport)

    request =
      Jido.Chat.Signal.GetThreadParticipants.new!(%{
        "client_id" => participants_binding.id,
        "request_id" => "participants",
        "room_id" => "C123",
        "thread_id" => "1"
      })

    assert {:ok, result} = Chat.execute(participants_binding, request)
    assert Enum.map(result.data["result"]["participants"], & &1["id"]) == ["U1", "U2", "B1"]
    assert result.data["result"]["complete"] == false
  end

  test "mark_as_read/3 delegates an idempotent Slack receipt" do
    assert {:ok, true} =
             Jido.Chat.Slack.Operations.mark_as_read("C123", "1706745600.000100", transport: MockTransport)

    assert {:ok, true} =
             Jido.Chat.Slack.Operations.mark_as_read("C123", "1706745600.000100", transport: MockTransport)

    assert_received {:mark_as_read, "C123", "1706745600.000100"}
    assert_received {:mark_as_read, "C123", "1706745600.000100"}
  end

  test "transform_incoming/1 normalizes a slack message map" do
    message = %{
      "type" => "message",
      "channel" => "C123",
      "user" => "U123",
      "text" => "Hello <@U999>",
      "ts" => "1706745600.000100"
    }

    {_binding, incoming} = native_message(message)
    assert incoming.data["room_id"] == "C123"
    assert incoming.data["sender"]["id"] == "U123"
    assert incoming.data["text"] == "Hello <@U999>"
    assert incoming.data["conversation_kind"] == "channel"
    assert Adapter.channel_type() == :slack
    assert length(incoming.data["mentions"]) == 1
  end

  test "transform_incoming/1 preserves file share comments" do
    current_message = %{
      "type" => "message",
      "subtype" => "file_share",
      "channel" => "C123",
      "user" => "U123",
      "text" => "Current file comment",
      "ts" => "1706745600.000100",
      "files" => [%{"id" => "F1", "url_private" => "https://files.slack.com/file.txt"}]
    }

    {_binding, current} = native_message(current_message)
    assert current.data["text"] == "Current file comment"

    legacy_message =
      current_message
      |> Map.put("text", "")
      |> put_in(["files", Access.at(0), "initial_comment"], %{
        "comment" => "Legacy file comment"
      })

    {_binding, legacy} = native_message(legacy_message)
    assert legacy.data["text"] == "Legacy file comment"
  end

  test "fetch_media/2 downloads raw URLs and media references with a bot token" do
    url = "https://files.slack.com/files-pri/T1-F1/file.png"

    assert {:ok, "slack file bytes"} =
             Jido.Chat.Slack.Operations.fetch_media(url,
               token: "xoxb-test",
               transport: MockTransport
             )

    assert_received {:download_file, ^url, opts}
    assert opts[:token] == "xoxb-test"

    media = Map.new(%{url: url, filename: "file.png"})

    assert {:ok, "slack file bytes"} =
             Jido.Chat.Slack.Operations.fetch_media(media,
               token: "xoxb-test",
               transport: MockTransport
             )

    assert_received {:download_file, ^url, _opts}
  end

  test "send/edit/delete/fetch metadata methods work" do
    assert {:ok, result} = Jido.Chat.Slack.Operations.send_message("C123", "hi", transport: MockTransport)
    assert_received {:send_message, "C123", "hi", []}
    assert result["id"] == "1706745600.000100"

    assert {:ok, edited} =
             Jido.Chat.Slack.Operations.edit_message("C123", "1706745600.000100", "updated", transport: MockTransport)

    assert_received {:edit_message, "C123", "1706745600.000100", "updated"}
    assert edited["id"] == "1706745600.000100"

    assert :ok = Jido.Chat.Slack.Operations.delete_message("C123", "1706745600.000100", transport: MockTransport)
    assert_received {:delete_message, "C123", "1706745600.000100"}

    assert {:ok, info} = Jido.Chat.Slack.Operations.fetch_metadata("C123", transport: MockTransport)
    assert_received {:fetch_metadata, "C123"}
    assert info["id"] == "C123"
    assert info["name"] == "general"
    assert info["member_count"] == 12
  end

  test "send_message/3 maps generic thread routing to slack thread_ts" do
    assert {:ok, _result} =
             Jido.Chat.Slack.Operations.send_message("C123", "hi",
               transport: MockTransport,
               external_thread_id: "1706745600.000100",
               reply_to_id: "1706745599.000099"
             )

    assert_received {:send_message, "C123", "hi", opts}
    assert Keyword.get(opts, :thread_ts) == "1706745600.000100"
  end

  test "send_file/3 uploads path-backed and in-memory files" do
    path =
      Path.join(System.tmp_dir!(), "jido-slack-upload-#{System.unique_integer([:positive])}.txt")

    File.write!(path, "slack path upload\n")

    on_exit(fn ->
      File.rm(path)
    end)

    assert {:ok, path_result} =
             Jido.Chat.Slack.Operations.send_file(
               "C123",
               %{
                 kind: :file,
                 path: path,
                 filename: Path.basename(path)
               },
               transport: MockTransport,
               caption: "path caption"
             )

    assert path_result["id"] == "1706745609.000900"
    assert path_result["room_id"] == "C123"
    assert_received {:send_file, "C123", upload, path_opts}
    assert upload.path == path
    assert Keyword.get(path_opts, :initial_comment) == "path caption"

    assert {:ok, bytes_result} =
             Jido.Chat.Slack.Operations.send_file(
               "C123",
               %{
                 kind: :file,
                 data: "slack bytes upload\n",
                 filename: "bytes.txt",
                 media_type: "text/plain"
               },
               transport: MockTransport,
               external_thread_id: "1706745600.000100"
             )

    assert bytes_result["id"] == "1706745609.000900"
    assert_received {:send_file, "C123", upload, bytes_opts}
    assert upload.data == "slack bytes upload\n"
    assert Keyword.get(bytes_opts, :thread_ts) == "1706745600.000100"
  end

  test "send_file/3 returns explicit validation errors for unsupported or incomplete inputs" do
    assert {:error, :missing_filename} =
             Jido.Chat.Slack.Operations.send_file(
               "C123",
               %{kind: :file, data: "slack bytes upload\n"},
               transport: MockTransport
             )

    assert {:error, :unsupported_remote_url} =
             Jido.Chat.Slack.Operations.send_file(
               "C123",
               %{
                 kind: :file,
                 url: "https://example.com/file.txt",
                 filename: "file.txt"
               },
               transport: MockTransport
             )

    assert {:error, :missing_file_source} =
             Jido.Chat.Slack.Operations.send_file(
               "C123",
               %{kind: :file, filename: "missing.txt"},
               transport: MockTransport
             )
  end

  test "open_dm, post_ephemeral, reactions, and history helpers" do
    assert {:ok, "DU123"} = Jido.Chat.Slack.Operations.open_dm("U123", transport: MockTransport)
    assert_received {:open_dm, "U123"}

    assert {:ok, ephemeral} =
             Jido.Chat.Slack.Operations.post_ephemeral("C123", "U123", "secret", transport: MockTransport)

    assert_received {:post_ephemeral, "C123", "U123", "secret"}
    assert ephemeral["room_id"] == "C123"
    assert ephemeral["id"] == "1706745602.000300"

    assert :ok =
             Jido.Chat.Slack.Operations.add_reaction("C123", "1706745600.000100", ":wave:", transport: MockTransport)

    assert_received {:add_reaction, "C123", "1706745600.000100", ":wave:"}

    assert :ok =
             Jido.Chat.Slack.Operations.remove_reaction("C123", "1706745600.000100", ":wave:", transport: MockTransport)

    assert_received {:remove_reaction, "C123", "1706745600.000100", ":wave:"}

    assert {:ok, page} =
             Jido.Chat.Slack.Operations.fetch_messages("C123",
               transport: MockTransport,
               thread_ts: "1706745600.000100"
             )

    assert_received {:fetch_messages, "C123"}
    assert length(page["messages"]) == 1
    assert page["next_cursor"] == "cursor-1"

    assert {:ok, threads} = Jido.Chat.Slack.Operations.list_threads("C123", transport: MockTransport)
    assert_received {:list_threads, "C123"}
    assert length(threads["threads"]) == 1
  end

  test "fetch_message/3 preserves channel id when Slack omits it from the payload" do
    assert {:ok, message} =
             Jido.Chat.Slack.Operations.fetch_message("C123", "1706745600.000100", transport: ChannelOmittingTransport)

    assert_received {:fetch_message_without_channel, "C123", "1706745600.000100"}
    assert message["room_id"] == "C123"
    assert message["room_id"] == "C123"
    assert message["id"] == "1706745600.000100"
  end

  test "history helpers fail explicitly for unsupported forward direction" do
    assert {:error, :unsupported_direction} =
             Jido.Chat.Slack.Operations.fetch_messages("C123", transport: MockTransport, direction: :forward)

    assert {:error, :unsupported_direction} =
             Jido.Chat.Slack.Operations.list_threads("C123", transport: MockTransport, direction: :forward)
  end

  test "native empty delivery and private response handle Slack URL verification" do
    request =
      Map.new(%{
        adapter_name: :slack,
        payload: %{"type" => "url_verification", "challenge" => "hello-challenge"}
      })

    assert {:ok, %{signals: []}} = Chat.normalize(captured_binding(), request)
    response = Jido.Chat.Slack.Operations.format_webhook_response({:ok, []}, request: request)
    assert response.body == "hello-challenge"
  end

  test "private webhook response builder returns the existing interaction response shape" do
    binding = captured_binding()

    payload = %{
      "command" => "/help",
      "text" => "topic",
      "channel_id" => "C123",
      "user_id" => "U123",
      "trigger_id" => "1337.42"
    }

    assert {:ok, delivery} = Chat.normalize(binding, payload)

    response =
      Jido.Chat.Slack.Operations.format_webhook_response({:ok, delivery.signals},
        response_builder: fn _ -> %{"text" => "ack"} end
      )

    assert response.status == 200
    assert response.body == %{"text" => "ack"}
  end

  test "private webhook verification fails closed on an invalid signature" do
    payload = %{"command" => "/help", "channel_id" => "C123", "user_id" => "U123"}

    request =
      Map.new(%{
        adapter_name: :slack,
        payload: payload,
        raw: Jason.encode!(payload),
        headers: %{
          "x-slack-signature" => "v0=bad",
          "x-slack-request-timestamp" => Integer.to_string(System.os_time(:second))
        }
      })

    binding = captured_binding(signing_secret: "secret")

    assert {:error, :invalid_signature} =
             Jido.Chat.Slack.Operations.verify_webhook(request, Jido.Chat.Client.options(binding))
  end

  defp new_client(adapter, opts) do
    Jido.Chat.Client.new(adapter,
      id: opts[:id],
      credentials: opts |> Keyword.take([:token, :secret_token, :signing_secret]) |> Map.new(),
      transport: opts[:transport] || adapter_transport(adapter),
      config: Keyword.drop(opts, [:id, :token, :secret_token, :signing_secret, :transport])
    )
  end

  defp adapter_transport(adapter) do
    if function_exported?(adapter, :default_transport, 0), do: adapter.default_transport(), else: nil
  end
end
