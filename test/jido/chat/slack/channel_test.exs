defmodule Jido.Chat.Slack.AdapterSurfaceTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.Adapter, as: ChatAdapter
  alias Jido.Chat.FileUpload
  alias Jido.Chat.Media
  alias Jido.Chat.MessageSubject
  alias Jido.Chat.Participant
  alias Jido.Chat.PostPayload
  alias Jido.Chat.Thread
  alias Jido.Chat.UserInfo
  alias Jido.Chat.Slack.Adapter

  setup_all do
    Code.ensure_loaded!(Adapter)
    :ok
  end

  defmodule MockTransport do
    @behaviour Jido.Chat.Slack.Transport

    @impl true
    def send_message(channel_id, text, opts) do
      send(self(), {:send_message, channel_id, text, opts})
      {:ok, %{"channel" => channel_id, "ts" => "1706745600.000100"}}
    end

    @impl true
    def send_file(channel_id, upload, opts) do
      send(self(), {:send_file, channel_id, upload, opts})

      {:ok,
       %{
         "ok" => true,
         "files" => [
           %{
             "id" => "F123",
             "name" => upload.filename,
             "mimetype" => upload.media_type || "text/plain",
             "size" => upload.size_bytes || 21,
             "url_private" => "https://files.slack.com/files-pri/T1-F123/#{upload.filename}",
             "shares" => %{
               "public" => %{
                 channel_id => [%{"ts" => "1706745609.000900"}]
               }
             }
           }
         ]
       }}
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
         "num_members" => 12,
         "topic" => %{"value" => "Release coordination"},
         "purpose" => %{"value" => "Ship the next release"}
       }}
    end

    @impl true
    def get_user(user_id, _opts) do
      send(self(), {:get_user, user_id})

      {:ok,
       %{
         "id" => user_id,
         "name" => String.downcase(user_id),
         "real_name" => "User #{user_id}",
         "profile" => %{
           "display_name" => "Display #{user_id}",
           "email" => "#{String.downcase(user_id)}@example.test",
           "image_192" => "https://example.test/#{user_id}.png"
         },
         "is_bot" => user_id == "UBOT"
       }}
    end

    @impl true
    def get_permalink(channel_id, message_id, _opts) do
      send(self(), {:get_permalink, channel_id, message_id})
      {:ok, "https://workspace.slack.com/archives/#{channel_id}/p#{message_id}"}
    end

    @impl true
    def mark_as_read(channel_id, message_id, _opts) do
      send(self(), {:mark_as_read, channel_id, message_id})
      {:ok, true}
    end

    @impl true
    def fetch_thread(channel_id, _opts) do
      send(self(), {:fetch_thread, channel_id})
      {:ok, %{"messages" => [%{"channel" => channel_id, "ts" => "1706745600.000100"}]}}
    end

    @impl true
    def fetch_message(channel_id, message_id, opts) do
      send(self(), {:fetch_message, channel_id, message_id, opts})

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
    def download_file(url, opts) do
      send(self(), {:download_file, url, opts})
      {:ok, "slack file bytes"}
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
    assert caps.open_thread == :native
    assert caps.start_typing == :unsupported
    assert caps.fetch_media == :native
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
            %UserInfo{
              id: "U123",
              username: "u123",
              display_name: "Display U123",
              email: "u123@example.test",
              avatar_url: "https://example.test/U123.png",
              is_bot: false
            }} = Adapter.get_user("U123", transport: MockTransport)

    assert_received {:get_user, "U123"}
  end

  test "get_user/2 rejects malformed successful transport responses" do
    assert {:error, :invalid_user_response} =
             Adapter.get_user("U123", transport: MalformedUserTransport)
  end

  test "get_user/2 preserves transport errors" do
    assert {:error, :provider_down} = Adapter.get_user("U123", transport: FailingUserTransport)
  end

  test "fetch_subject/2 returns channel and thread subjects" do
    assert {:ok,
            %MessageSubject{
              type: "slack_channel",
              id: "C123",
              title: "Release coordination",
              status: "open"
            }} = Adapter.fetch_subject("C123", transport: MockTransport)

    assert {:ok,
            %MessageSubject{
              type: "slack_thread",
              id: "1706745600.000100",
              title: "single",
              url: "https://workspace.slack.com/archives/C123/p1706745600.000100",
              status: "open"
            }} =
             Adapter.fetch_subject("C123",
               external_thread_id: "1706745600.000100",
               transport: MockTransport
             )

    assert_received {:fetch_message, "C123", "1706745600.000100", fetch_opts}
    assert fetch_opts[:thread_ts] == "1706745600.000100"
    assert fetch_opts[:limit] == 1
  end

  test "get_thread_participants/2 follows cursors, de-duplicates users, and includes bots" do
    assert {:ok,
            [
              %Participant{id: "U1", type: :human},
              %Participant{id: "U2", type: :human},
              %Participant{id: "B1", type: :agent}
            ]} =
             ChatAdapter.get_thread_participants(Adapter, "C123",
               external_thread_id: "1",
               transport: PaginatedParticipantsTransport,
               limit: 3,
               page_size: 2
             )

    assert_received {:participant_page, nil, 2}
    assert_received {:participant_page, "page-2", 2}
  end

  test "get_thread_participants/2 enforces participant and page limits" do
    assert {:ok, [%Participant{id: "U1"}]} =
             ChatAdapter.get_thread_participants(Adapter, "C123",
               external_thread_id: "1",
               transport: PaginatedParticipantsTransport,
               limit: 1
             )

    assert {:error, :participant_page_limit_exceeded} =
             ChatAdapter.get_thread_participants(Adapter, "C123",
               external_thread_id: "1",
               transport: PaginatedParticipantsTransport,
               limit: 3,
               max_pages: 1
             )
  end

  test "thread handles pass the external Slack thread timestamp to resource helpers" do
    thread =
      Thread.new(%{
        id: "slack:C123:1",
        adapter_name: :slack,
        adapter: Adapter,
        external_room_id: "C123",
        external_thread_id: "1"
      })

    assert {:ok, %MessageSubject{id: "1", type: "slack_thread"}} =
             Thread.fetch_subject(thread, transport: MockTransport)

    assert {:ok,
            [
              %Participant{id: "U1"},
              %Participant{id: "U2"},
              %Participant{id: "B1"}
            ]} = Thread.participants(thread, transport: PaginatedParticipantsTransport, limit: 3)
  end

  test "mark_as_read/3 delegates an idempotent Slack receipt" do
    assert :ok =
             ChatAdapter.mark_as_read(Adapter, "C123", "1706745600.000100", transport: MockTransport)

    assert :ok =
             ChatAdapter.mark_as_read(Adapter, "C123", "1706745600.000100", transport: MockTransport)

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

    assert {:ok, incoming} = Adapter.transform_incoming(message)
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
          "url_private" => "https://files.slack.com/image.png",
          "url_private_download" => "https://files.slack.com/image-download.png"
        },
        %{
          "id" => "F2",
          "name" => "fallback.png",
          "mimetype" => nil,
          "url_private_download" => "https://files.slack.com/download/F2"
        },
        %{
          "id" => "F3",
          "name" => "extensionless",
          "mimetype" => " ",
          "filetype" => "png",
          "url_private_download" => "https://files.slack.com/download/F3"
        },
        %{
          "id" => "F4",
          "name" => "archive.unknown",
          "mimetype" => nil,
          "filetype" => "unknown",
          "url_private_download" => "https://files.slack.com/download/F4"
        },
        %{
          "id" => "F5",
          "name" => " ",
          "mimetype" => nil,
          "url_private_download" => " ",
          "url_private" => "https://files.slack.com/files/photo.PNG?token=signed"
        },
        %{
          "id" => "F6",
          "name" => "misleading.png",
          "mimetype" => " application/pdf; charset=binary ",
          "filetype" => "PNG",
          "url_private_download" => "https://files.slack.com/download/F6"
        }
      ]
    }

    assert {:ok, incoming} = Adapter.transform_incoming(message)

    assert [explicit, filename_fallback, filetype_fallback, unknown, signed_url, misleading] =
             incoming.media

    assert explicit.kind == :image
    assert explicit.url == "https://files.slack.com/image-download.png"
    assert explicit.media_type == "image/png"
    assert explicit.filename == "image.png"

    assert filename_fallback.kind == :image
    assert filename_fallback.media_type == nil
    assert filename_fallback.filename == "fallback.png"

    assert filetype_fallback.kind == :image
    assert filetype_fallback.media_type == nil
    assert filetype_fallback.filename == "extensionless"

    assert unknown.kind == :file
    assert unknown.media_type == nil

    assert signed_url.kind == :image
    assert signed_url.url == "https://files.slack.com/files/photo.PNG?token=signed"
    assert signed_url.filename == nil

    assert misleading.kind == :file
    assert misleading.media_type == "application/pdf"
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

    assert {:ok, current} = Adapter.transform_incoming(current_message)
    assert current.text == "Current file comment"

    legacy_message =
      current_message
      |> Map.put("text", "")
      |> put_in(["files", Access.at(0), "initial_comment"], %{
        "comment" => "Legacy file comment"
      })

    assert {:ok, legacy} = Adapter.transform_incoming(legacy_message)
    assert legacy.text == "Legacy file comment"
  end

  test "fetch_media/2 downloads raw URLs and media references with a bot token" do
    url = "https://files.slack.com/files-pri/T1-F1/file.png"

    assert {:ok, "slack file bytes"} =
             Adapter.fetch_media(url,
               token: "xoxb-test",
               transport: MockTransport
             )

    assert_received {:download_file, ^url, opts}
    assert opts[:token] == "xoxb-test"

    media = Media.new(%{url: url, filename: "file.png"})

    assert {:ok, "slack file bytes"} =
             Adapter.fetch_media(media,
               token: "xoxb-test",
               transport: MockTransport
             )

    assert_received {:download_file, ^url, _opts}
  end

  test "send/edit/delete/fetch metadata methods work" do
    assert {:ok, result} = Adapter.send_message("C123", "hi", transport: MockTransport)
    assert_received {:send_message, "C123", "hi", []}
    assert result.message_id == "1706745600.000100"

    assert {:ok, edited} =
             Adapter.edit_message("C123", "1706745600.000100", "updated", transport: MockTransport)

    assert_received {:edit_message, "C123", "1706745600.000100", "updated"}
    assert edited.message_id == "1706745600.000100"

    assert :ok = Adapter.delete_message("C123", "1706745600.000100", transport: MockTransport)
    assert_received {:delete_message, "C123", "1706745600.000100"}

    assert {:ok, info} = Adapter.fetch_metadata("C123", transport: MockTransport)
    assert_received {:fetch_metadata, "C123"}
    assert info.id == "C123"
    assert info.name == "general"
    assert info.member_count == 12
  end

  test "send_message/3 maps generic thread routing to slack thread_ts" do
    assert {:ok, _result} =
             Adapter.send_message("C123", "hi",
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
             Adapter.send_file(
               "C123",
               %FileUpload{
                 kind: :file,
                 path: path,
                 filename: Path.basename(path)
               },
               transport: MockTransport,
               caption: "path caption"
             )

    assert path_result.external_message_id == "1706745609.000900"
    assert path_result.external_room_id == "C123"
    assert path_result.metadata.file_id == "F123"
    assert path_result.metadata.filename == Path.basename(path)
    assert path_result.metadata.upload_kind == :file
    assert path_result.metadata.delivered_kind == :file
    assert_received {:send_file, "C123", upload, path_opts}
    assert upload.path == path
    assert Keyword.get(path_opts, :initial_comment) == "path caption"

    assert {:ok, bytes_result} =
             Adapter.send_file(
               "C123",
               %FileUpload{
                 kind: :file,
                 data: "slack bytes upload\n",
                 filename: "bytes.txt",
                 media_type: "text/plain"
               },
               transport: MockTransport,
               external_thread_id: "1706745600.000100"
             )

    assert bytes_result.external_message_id == "1706745609.000900"
    assert bytes_result.metadata.filename == "bytes.txt"
    assert bytes_result.metadata.content_type == "text/plain"
    assert_received {:send_file, "C123", upload, bytes_opts}
    assert upload.data == "slack bytes upload\n"
    assert Keyword.get(bytes_opts, :thread_ts) == "1706745600.000100"
  end

  test "send_file/3 returns explicit validation errors for unsupported or incomplete inputs" do
    assert {:error, :missing_filename} =
             Adapter.send_file(
               "C123",
               %FileUpload{kind: :file, data: "slack bytes upload\n"},
               transport: MockTransport
             )

    assert {:error, :unsupported_remote_url} =
             Adapter.send_file(
               "C123",
               %FileUpload{
                 kind: :file,
                 url: "https://example.com/file.txt",
                 filename: "file.txt"
               },
               transport: MockTransport
             )

    assert {:error, :missing_file_source} =
             Adapter.send_file(
               "C123",
               %FileUpload{kind: :file, filename: "missing.txt"},
               transport: MockTransport
             )
  end

  test "open_dm, post_ephemeral, reactions, and history helpers" do
    assert {:ok, "DU123"} = Adapter.open_dm("U123", transport: MockTransport)
    assert_received {:open_dm, "U123"}

    assert {:ok, ephemeral} =
             Adapter.post_ephemeral("C123", "U123", "secret", transport: MockTransport)

    assert_received {:post_ephemeral, "C123", "U123", "secret"}
    assert ephemeral.used_fallback == false
    assert ephemeral.thread_id == "slack:C123:1706745602.000300"

    assert :ok =
             Adapter.add_reaction("C123", "1706745600.000100", ":wave:", transport: MockTransport)

    assert_received {:add_reaction, "C123", "1706745600.000100", ":wave:"}

    assert :ok =
             Adapter.remove_reaction("C123", "1706745600.000100", ":wave:", transport: MockTransport)

    assert_received {:remove_reaction, "C123", "1706745600.000100", ":wave:"}

    assert {:ok, page} =
             Adapter.fetch_messages("C123",
               transport: MockTransport,
               thread_ts: "1706745600.000100"
             )

    assert_received {:fetch_messages, "C123"}
    assert length(page.messages) == 1
    assert page.next_cursor == "cursor-1"

    assert {:ok, threads} = Adapter.list_threads("C123", transport: MockTransport)
    assert_received {:list_threads, "C123"}
    assert length(threads.threads) == 1
  end

  test "fetch_message/3 preserves channel id when Slack omits it from the payload" do
    assert {:ok, message} =
             Adapter.fetch_message("C123", "1706745600.000100", transport: ChannelOmittingTransport)

    assert_received {:fetch_message_without_channel, "C123", "1706745600.000100"}
    assert message.external_room_id == "C123"
    assert message.channel_id == "C123"
    assert message.external_message_id == "1706745600.000100"
  end

  test "core post_message/4 routes a single file through Slack send_file/3" do
    payload =
      PostPayload.new(%{
        text: "slack canonical upload",
        files: [
          %{
            kind: :file,
            data: "slack canonical bytes\n",
            filename: "canonical.txt",
            media_type: "text/plain"
          }
        ]
      })

    assert {:ok, response} =
             ChatAdapter.post_message(Adapter, "C123", payload, transport: MockTransport)

    assert response.external_message_id == "1706745609.000900"
    assert response.metadata.file_id == "F123"
    assert_received {:send_file, "C123", upload, opts}
    assert upload.filename == "canonical.txt"
    assert Keyword.get(opts, :initial_comment) == "slack canonical upload"
  end

  test "history helpers fail explicitly for unsupported forward direction" do
    assert {:error, :unsupported_direction} =
             Adapter.fetch_messages("C123", transport: MockTransport, direction: :forward)

    assert {:error, :unsupported_direction} =
             Adapter.list_threads("C123", transport: MockTransport, direction: :forward)
  end

  test "open_modal/3 requires trigger_id and normalizes result" do
    assert {:ok, result} =
             Adapter.open_modal(
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
             Adapter.open_modal("C123", %{type: "modal", callback_id: "feedback"}, [])
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
             Adapter.handle_webhook(chat, mention_payload, [])

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

    assert {:ok, _chat, _incoming} = Adapter.handle_webhook(chat, slash_payload, [])
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
             Adapter.handle_webhook(chat, %{"payload" => action_payload}, [])

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
             Adapter.handle_webhook(chat, %{"payload" => modal_payload}, [])

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

    assert {:ok, _chat, _incoming} = Adapter.handle_webhook(chat, reaction_payload, [])
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

  test "webhook pipeline uses chat metadata slack_response for interaction replies" do
    chat =
      Chat.new(adapters: %{slack: Jido.Chat.Slack.Adapter})
      |> Chat.on_slash_command(fn chat, _event ->
        %{chat | metadata: Map.put(chat.metadata, :slack_response, %{"text" => "ack"})}
      end)

    assert {:ok, _chat, _event, response} =
             Jido.Chat.WebhookPipeline.handle_request(
               chat,
               :slack,
               %{
                 "command" => "/help",
                 "text" => "topic",
                 "channel_id" => "C123",
                 "user_id" => "U123",
                 "user_name" => "alice",
                 "trigger_id" => "1337.42"
               },
               [],
               &Jido.Chat.get_adapter/2,
               &Jido.Chat.process_event/4
             )

    assert response.status == 200
    assert response.body == %{"text" => "ack"}
  end

  test "handle_webhook/3 fails closed when signature verification fails" do
    chat = Chat.new(adapters: %{slack: Jido.Chat.Slack.Adapter})
    raw_body = Jason.encode!(%{"command" => "/help", "channel_id" => "C123", "user_id" => "U123"})

    assert {:error, :invalid_signature} =
             Adapter.handle_webhook(
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
