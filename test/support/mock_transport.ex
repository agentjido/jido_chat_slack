defmodule Jido.Chat.Slack.AdapterSurfaceTest.MockTransport do
  @moduledoc "Recording Slack transport for public boundary tests."
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
           "size" => Map.get(upload, :size_bytes, 21),
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
  def fetch_messages(channel_id, opts) do
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
       "response_metadata" => %{"next_cursor" => if(opts[:cursor], do: nil, else: "cursor-1")}
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
