defmodule Jido.Chat.Slack.Transport.ReqClientTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Slack.Transport.ReqClient

  defmodule MockReq do
    def request(opts) do
      send(self(), {:request, opts})

      body =
        case opts[:url] do
          "https://slack.com/api/conversations.info" ->
            %{"ok" => true, "channel" => %{"id" => "C1"}}

          "https://slack.com/api/users.info" ->
            %{"ok" => true, "user" => %{"id" => "U1"}}

          "https://slack.com/api/conversations.open" ->
            %{"ok" => true, "channel" => %{"id" => "D1"}}

          "https://slack.com/api/files.getUploadURLExternal" ->
            %{"ok" => true, "upload_url" => "https://files.slack.com/upload", "file_id" => "F1"}

          "https://slack.com/api/files.completeUploadExternal" ->
            %{"ok" => true, "files" => [%{"id" => "F1"}]}

          "https://files.slack.com/download" ->
            "bytes"

          _ ->
            %{"ok" => true, "channel" => "C1", "ts" => "M1"}
        end

      {:ok, Req.Response.new(status: 200, body: body)}
    end
  end

  defmodule ErrorReq do
    def request(_opts),
      do: {:ok, Req.Response.new(status: 200, body: %{"ok" => false, "error" => "not_authed"})}
  end

  test "message calls use the explicit token and encode Slack fields" do
    assert {:ok, _} =
             ReqClient.send_message("xoxb-test", "C1", "hello",
               req: MockReq,
               thread_ts: "T1",
               blocks: [%{"type" => "section"}]
             )

    assert_received {:request, opts}
    assert opts[:url] == "https://slack.com/api/chat.postMessage"
    assert {"authorization", "Bearer xoxb-test"} in opts[:headers]
    assert opts[:form]["channel"] == "C1"
    assert opts[:form]["thread_ts"] == "T1"
    assert Jason.decode!(opts[:form]["blocks"]) == [%{"type" => "section"}]
  end

  test "metadata, users, and direct messages unwrap provider objects" do
    assert {:ok, %{"id" => "C1"}} = ReqClient.fetch_metadata("token", "C1", req: MockReq)
    assert {:ok, %{"id" => "U1"}} = ReqClient.get_user("token", "U1", req: MockReq)
    assert {:ok, "D1"} = ReqClient.open_dm("token", "U1", req: MockReq)
  end

  test "external file upload uses the current three-step Slack API" do
    upload = %{body: "bytes", filename: "test.txt", title: "Test", alt_text: "file"}
    assert {:ok, %{"files" => [%{"id" => "F1"}]}} = ReqClient.send_file("token", "C1", upload, req: MockReq)

    assert_received {:request, first}
    assert first[:url] == "https://slack.com/api/files.getUploadURLExternal"
    assert first[:form]["length"] == "5"
    assert_received {:request, upload_request}
    assert upload_request[:url] == "https://files.slack.com/upload"
    assert upload_request[:body] == "bytes"
    assert_received {:request, complete}
    assert complete[:url] == "https://slack.com/api/files.completeUploadExternal"
  end

  test "downloads reject HTML and provider failures remain explicit" do
    assert {:ok, "bytes"} = ReqClient.download_file("token", "https://files.slack.com/download", req: MockReq)

    assert {:error, {:slack_api_error, "not_authed", _}} =
             ReqClient.send_message("token", "C1", "hello", req: ErrorReq)
  end
end
