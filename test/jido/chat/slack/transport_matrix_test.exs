defmodule Jido.Chat.Slack.TransportMatrixTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.Slack.Transport.ReqClient, as: T

  defmodule Request do
    def request(opts) do
      send(self(), {:request, opts})

      case Process.get(:responses, []) do
        [response | rest] ->
          Process.put(:responses, rest)
          response

        [] ->
          {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
      end
    end
  end

  defp options, do: [token: "test", req: Request, headers: %{"x-test" => "yes"}]
  defp response(body, status \\ 200), do: {:ok, %Req.Response{status: status, body: body}}
  defp reply(body), do: Process.put(:responses, [response(body)])

  test "Web API methods map identifiers and payloads" do
    calls = [
      {:send_message, ["C", "hello"], "chat.postMessage"},
      {:edit_message, ["C", "1", "edit"], "chat.update"},
      {:delete_message, ["C", "1"], "chat.delete"},
      {:mark_as_read, ["C", "1"], "conversations.mark"},
      {:add_reaction, ["C", "1", ":wave:"], "reactions.add"},
      {:remove_reaction, ["C", "1", "wave"], "reactions.remove"},
      {:post_ephemeral, ["C", "U", "private"], "chat.postEphemeral"},
      {:open_modal, ["trigger", %{"type" => "modal"}], "views.open"}
    ]

    for {function, args, method} <- calls do
      assert {:ok, _} =
               apply(T, function, args ++ [options() ++ [blocks: [%{"type" => "divider"}], unfurl_links: false]])

      assert_receive {:request, opts}
      assert opts[:url] == "https://slack.com/api/" <> method
      assert {"authorization", "Bearer test"} in opts[:headers]
      assert {"x-test", "yes"} in opts[:headers]
    end

    reply(%{"ok" => true, "channel" => %{"id" => "D1"}})
    assert {:ok, "D1"} = T.open_dm("U", options())
    reply(%{"ok" => true, "channel" => %{"id" => "C"}})
    assert {:ok, %{"id" => "C"}} = T.fetch_metadata("C", options())
  end

  test "history and replies preserve thread and pagination policy" do
    page = %{
      "ok" => true,
      "messages" => [%{"ts" => "1", "thread_ts" => "1"}, %{"ts" => "2", "reply_count" => 2}, %{"ts" => "3"}]
    }

    reply(page)
    assert {:ok, %{}} = T.fetch_thread("C", options() ++ [message_id: "1", cursor: "next", inclusive: false])
    assert_receive {:request, opts}
    assert opts[:url] =~ "conversations.replies"
    assert opts[:form]["inclusive"] == "false"
    assert {:error, :missing_thread_ts} = T.fetch_thread("C", options())
    reply(page)
    assert {:ok, %{"ts" => "1"}} = T.fetch_message("C", "1", options() ++ [thread_ts: "1"])
    reply(page)
    assert {:ok, %{"ts" => "1"}} = T.fetch_message("C", "1", options())
    reply(page)
    assert {:error, :not_found} = T.fetch_message("C", "missing", options())
    reply(Map.put(page, "has_more", true))
    assert {:ok, %{"has_more" => true, "threads" => roots}} = T.list_threads("C", options())
    assert length(roots) == 2
    reply(%{"ok" => true, "messages" => []})
    assert {:error, :not_found} = T.fetch_message("C", "missing", options())
    reply(%{"ok" => true, "messages" => []})
    assert {:error, :not_found} = T.fetch_message("C", "missing", options() ++ [thread_ts: "1"])
    reply(%{"ok" => true})
    assert {:ok, %{"threads" => []}} = T.list_threads("C", options())
  end

  test "provider and network failures are returned for each method" do
    calls = [
      {:delete_message, ["C", "1"]},
      {:mark_as_read, ["C", "1"]},
      {:add_reaction, ["C", "1", "wave"]},
      {:remove_reaction, ["C", "1", "wave"]},
      {:fetch_metadata, ["C"]},
      {:get_user, ["U"]},
      {:get_permalink, ["C", "1"]},
      {:open_dm, ["U"]},
      {:fetch_message, ["C", "1"]},
      {:list_threads, ["C"]}
    ]

    for {function, args} <- calls do
      Process.put(:responses, [{:error, :offline}])
      assert {:error, :offline} = apply(T, function, args ++ [options()])
    end

    for {body, expected} <- [{%{}, :missing_channel}, {%{"channel" => %{}}, :missing_channel}] do
      reply(body)
      assert {:error, ^expected} = T.open_dm("U", options())
    end

    reply(%{})
    assert {:error, :missing_channel} = T.fetch_metadata("C", options())
    reply(%{"user" => 1})
    assert {:error, :invalid_user_response} = T.get_user("U", options())
    reply(%{"permalink" => 1})
    assert {:error, :invalid_permalink_response} = T.get_permalink("C", "1", options())
    Process.put(:responses, [response("bad", 503)])
    assert {:error, {:http_error, 503, "bad"}} = T.send_message("C", "hi", options())
    reply(%{"ok" => false, "error" => "invalid_auth"})
    assert {:error, {:slack_api_error, "invalid_auth", _}} = T.send_message("C", "hi", options())
    reply("not a map")
    assert {:error, {:invalid_response, "not a map"}} = T.send_message("C", "hi", options())
    assert_raise ArgumentError, fn -> T.send_message("C", "hi", req: Request) end
  end

  test "downloads reject invalid bodies and return network errors" do
    for url <- ["https://example.test/a", "http://files.slack.com/a", "https://files.slack.com.example.test/a"] do
      assert {:error, {:not_attempted, :invalid_media_reference}} = T.download_file(url, options())
      refute_receive {:request, _}
    end

    for {response, expected} <- [
          {response(%{}), {:error, {:invalid_download_body, %{}}}},
          {{:error, :offline}, {:error, :offline}},
          {response("bad", 503), {:error, {:http_error, 503, "bad"}}}
        ] do
      Process.put(:responses, [response])
      assert T.download_file("https://files.slack.com/test", options()) == expected
    end
  end

  test "uploads read files, validate sources, and handle each external upload failure" do
    path = Path.join(System.tmp_dir!(), "slack-transport-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "bytes")
    on_exit(fn -> File.rm(path) end)
    first = response(%{"ok" => true, "upload_url" => "https://files.slack.com/upload", "file_id" => "F"})

    Process.put(:responses, [
      first,
      response("OK"),
      response(%{"ok" => true, "files" => [%{"id" => "F", "shares" => %{"public" => %{"C" => [%{"ts" => "1"}]}}}]})
    ])

    assert {:ok, _} =
             T.send_file(
               "C",
               %{path: path, filename: nil, metadata: %{title: "File", alt_text: "Text"}},
               options() ++ [thread_ts: "1", initial_comment: "hello"]
             )

    File.write!(path, "")
    assert {:error, :missing_file_source} = T.send_file("C", %{path: path, filename: nil}, options())
    File.rm!(path)
    assert {:error, :enoent} = T.send_file("C", %{path: path, filename: nil}, options())

    for {source, reason} <- [
          {%{data: "a"}, :missing_filename},
          {%{url: "https://example.test"}, :unsupported_remote_url},
          {%{}, :missing_file_source}
        ] do
      assert {:error, ^reason} = T.send_file("C", source, options())
    end

    source = %{data: "bytes", filename: "a.txt"}
    reply(%{"ok" => true})
    assert {:error, :invalid_upload_response} = T.send_file("C", source, options())

    for {failure, expected} <- [{response("no", 500), {:http_error, 500, "no"}}, {{:error, :offline}, :offline}] do
      Process.put(:responses, [first, failure])
      assert {:error, ^expected} = T.send_file("C", source, options())
    end
  end

  test "upload identity lookup is bounded and preserves post-write failures" do
    first = response(%{"ok" => true, "upload_url" => "https://files.slack.com/upload", "file_id" => "F"})
    complete = response(%{"ok" => true, "files" => [%{"id" => "F"}]})
    source = %{data: "bytes", filename: "proof.txt"}

    for {followup, expected} <- [
          {[response(%{"ok" => false, "error" => "missing_scope"})], :upload_identity_unavailable},
          {[response(%{"ok" => true})], :upload_identity_unavailable},
          {List.duplicate(response(%{"ok" => true, "file" => %{"id" => "F"}}), 3), :upload_identity_unavailable}
        ] do
      Process.put(:responses, [first, response("OK"), complete] ++ followup)
      assert {:error, reason} = T.send_file("C", source, options())

      assert reason == expected
      assert Process.get(:responses) == []
    end
  end
end
