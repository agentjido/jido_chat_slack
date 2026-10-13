defmodule Jido.Chat.Slack.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat
  alias Jido.Chat.FileUpload
  alias Jido.Chat.Slack.Adapter

  @run_live System.get_env("RUN_LIVE_SLACK_TESTS") in ["1", "true", "TRUE", "yes", "on"]
  @token System.get_env("SLACK_BOT_TOKEN")
  @channel_id System.get_env("SLACK_TEST_CHANNEL_ID")
  @user_id System.get_env("SLACK_TEST_USER_ID")
  @reaction System.get_env("SLACK_TEST_REACTION") || "wave"

  @moduletag :live
  @moduletag :slack_live

  if not @run_live do
    @moduletag skip: "set RUN_LIVE_SLACK_TESTS=true to run live Slack integration tests"
  end

  if @run_live and (is_nil(@token) or @token == "" or is_nil(@channel_id) or @channel_id == "") do
    @moduletag skip: "set SLACK_BOT_TOKEN and SLACK_TEST_CHANNEL_ID when RUN_LIVE_SLACK_TESTS=true"
  end

  setup_all do
    {:ok, token: @token, channel_id: @channel_id, opts: [token: @token]}
  end

  test "send/fetch/edit/delete message against live Slack API", ctx do
    text = "jido slack live #{System.system_time(:millisecond)}"

    assert {:ok, sent} = Adapter.send_message(ctx.channel_id, text, ctx.opts)
    message_id = sent["id"]
    assert is_binary(message_id)

    assert {:ok, fetched} = Adapter.fetch_message(ctx.channel_id, message_id, ctx.opts)
    assert fetched["id"] == message_id
    assert fetched["room_id"] == ctx.channel_id

    assert {:ok, edited} =
             Adapter.edit_message(ctx.channel_id, message_id, text <> " (edited)", ctx.opts)

    assert edited["id"] == message_id
    assert :ok = Adapter.delete_message(ctx.channel_id, message_id, ctx.opts)
  end

  test "metadata lookup succeeds against live Slack API", ctx do
    assert {:ok, info} = Adapter.fetch_metadata(ctx.channel_id, ctx.opts)
    assert info["id"] == ctx.channel_id
  end

  test "stream fallback edits a visible draft and leaves the final content", ctx do
    parts = [
      "jido",
      " slack",
      " streaming",
      " fallback",
      " should",
      " be",
      " visible"
    ]

    chunk_stream =
      Stream.concat([
        [hd(parts)],
        Stream.map(tl(parts), fn chunk ->
          Process.sleep(500)
          chunk
        end)
      ])

    {:ok, binding} =
      Chat.bind(
        Adapter,
        Keyword.merge(ctx.opts, id: "live-stream", placeholder_text: "jido slack draft...", update_every: 1)
      )

    {:ok, ref} = Chat.put_resource(binding, "stream", chunk_stream)

    request =
      Jido.Chat.Signal.Stream.new!(%{
        "request_id" => Chat.ID.generate!(),
        "room_id" => ctx.channel_id,
        "resource_ref" => ref
      })

    assert {:ok, result} = Chat.execute(binding, request)
    sent = result.data["result"]

    message_id = sent["id"]
    assert is_binary(message_id)

    Process.sleep(1_000)

    assert {:ok, fetched} = Adapter.fetch_message(ctx.channel_id, message_id, ctx.opts)
    assert fetched["id"] == message_id
    assert fetched["text"] == Enum.join(parts)

    assert :ok = Adapter.delete_message(ctx.channel_id, message_id, ctx.opts)
  end

  test "reply continuity preserves Slack thread metadata", ctx do
    root_text = "jido slack reply root #{System.system_time(:millisecond)}"
    reply_text = "jido slack reply child #{System.system_time(:millisecond)}"

    assert {:ok, root} = Adapter.send_message(ctx.channel_id, root_text, ctx.opts)
    root_id = root["id"]

    on_exit(fn ->
      cleanup_delete(fn -> Adapter.delete_message(ctx.channel_id, root_id, ctx.opts) end)
    end)

    assert {:ok, reply} =
             Adapter.send_message(
               ctx.channel_id,
               reply_text,
               Keyword.merge(ctx.opts, reply_to_id: root_id)
             )

    reply_id = reply["id"]

    on_exit(fn ->
      cleanup_delete(fn -> Adapter.delete_message(ctx.channel_id, reply_id, ctx.opts) end)
    end)

    assert {:ok, fetched} =
             Adapter.fetch_message(
               ctx.channel_id,
               reply_id,
               Keyword.merge(ctx.opts, thread_ts: root_id)
             )

    assert fetched["id"] == reply_id
    assert fetched["room_id"] == ctx.channel_id
    assert fetched["thread_id"] == root_id
    assert reply["thread_id"] == root_id
  end

  test "reaction flow succeeds against live Slack API", ctx do
    assert {:ok, sent} =
             Adapter.send_message(
               ctx.channel_id,
               "jido slack reaction target #{System.system_time(:millisecond)}",
               ctx.opts
             )

    message_id = sent["id"]

    on_exit(fn ->
      cleanup_delete(fn -> Adapter.delete_message(ctx.channel_id, message_id, ctx.opts) end)
    end)

    assert :ok = Adapter.add_reaction(ctx.channel_id, message_id, @reaction, ctx.opts)
    assert :ok = Adapter.remove_reaction(ctx.channel_id, message_id, @reaction, ctx.opts)
  end

  test "send_file accepts local filesystem paths and raw byte uploads", ctx do
    path =
      write_temp_file(
        "jido-slack-live-",
        ".txt",
        "slack live file #{System.system_time(:millisecond)}\n"
      )

    on_exit(fn ->
      File.rm(path)
    end)

    path_upload =
      FileUpload.new(%{
        kind: :file,
        path: path,
        filename: Path.basename(path)
      })

    assert {:ok, path_response} = Adapter.send_file(ctx.channel_id, path_upload, ctx.opts)
    path_message_id = path_response["id"]
    assert is_binary(path_message_id)

    on_exit(fn ->
      cleanup_delete(fn -> Adapter.delete_message(ctx.channel_id, path_message_id, ctx.opts) end)
    end)

    bytes_upload =
      FileUpload.new(%{
        kind: :file,
        data: "slack live bytes #{System.system_time(:millisecond)}\n",
        filename: "slack-live-bytes.txt",
        media_type: "text/plain"
      })

    assert {:ok, bytes_response} = Adapter.send_file(ctx.channel_id, bytes_upload, ctx.opts)
    bytes_message_id = bytes_response["id"]
    assert is_binary(bytes_message_id)

    on_exit(fn ->
      cleanup_delete(fn -> Adapter.delete_message(ctx.channel_id, bytes_message_id, ctx.opts) end)
    end)
  end

  test "core post_message routes canonical single-file payloads through Slack send_file", ctx do
    upload =
      FileUpload.new(%{
        kind: :file,
        data: "slack canonical bytes #{System.system_time(:millisecond)}\n",
        filename: "slack-canonical.txt",
        media_type: "text/plain"
      })

    {:ok, binding} = Chat.bind(Adapter, Keyword.put(ctx.opts, :id, "live-post"))
    {:ok, ref} = Chat.put_resource(binding, "file", upload)

    request =
      Jido.Chat.Signal.PostMessage.new!(%{
        "request_id" => Chat.ID.generate!(),
        "room_id" => ctx.channel_id,
        "content" => %{
          "kind" => "media",
          "resource_ref" => ref,
          "caption" => "jido slack canonical file #{System.system_time(:millisecond)}"
        }
      })

    assert {:ok, result} = Chat.execute(binding, request)
    message_id = result.data["result"]["id"]
    assert is_binary(message_id)

    on_exit(fn ->
      cleanup_delete(fn -> Adapter.delete_message(ctx.channel_id, message_id, ctx.opts) end)
    end)
  end

  if @user_id not in [nil, ""] do
    test "open_dm and post_ephemeral succeed when SLACK_TEST_USER_ID is provided", ctx do
      assert {:ok, dm_channel_id} = Adapter.open_dm(@user_id, ctx.opts)
      assert is_binary(dm_channel_id)

      {:ok, binding} = Chat.bind(Adapter, Keyword.put(ctx.opts, :id, "live-ephemeral"))

      request =
        Jido.Chat.Signal.PostEphemeral.new!(%{
          "request_id" => Chat.ID.generate!(),
          "room_id" => ctx.channel_id,
          "user_id" => @user_id,
          "text" => "jido slack ephemeral #{System.system_time(:millisecond)}",
          "fallback_to_dm" => false
        })

      assert Adapter.capabilities().post_ephemeral == :native
      assert {:ok, result} = Chat.execute(binding, request)
      assert result.type == "jido.chat.operation.completed"
      ephemeral = result.data["result"]

      assert is_binary(ephemeral["id"])
      assert ephemeral["room_id"] == ctx.channel_id
      assert ephemeral["text"] =~ "jido slack ephemeral"
    end
  else
    test "open_dm and post_ephemeral live tests require SLACK_TEST_USER_ID" do
      assert is_nil(@user_id) or @user_id == ""
    end
  end

  defp cleanup_delete(fun) when is_function(fun, 0) do
    case fun.() do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp write_temp_file(prefix, suffix, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}#{System.unique_integer([:positive])}#{suffix}"
      )

    File.write!(path, contents)
    path
  end
end
