defmodule Jido.Chat.Slack.Transport.ReqClientTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.FileUpload
  alias Jido.Chat.Slack.Transport.ReqClient

  defmodule MockReq do
    def request(opts) do
      send(self(), {:req_request, opts})

      case opts[:url] do
        "https://slack.com/api/files.getUploadURLExternal" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "ok" => true,
               "upload_url" => "https://files.slack.com/upload/v1/abc123",
               "file_id" => "F123"
             }
           }}

        "https://files.slack.com/upload/v1/abc123" ->
          {:ok, %Req.Response{status: 200, body: "OK - 12"}}

        "https://slack.com/api/files.completeUploadExternal" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "ok" => true,
               "files" => [
                 %{
                   "id" => "F123",
                   "name" => "bytes.txt",
                   "mimetype" => "text/plain",
                   "shares" => %{
                     "public" => %{
                       "C123" => [%{"ts" => "1706745600.000100"}]
                     }
                   }
                 }
               ]
             }
           }}

        _other ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"ok" => true, "channel" => "C123", "ts" => "1706745600.000100"}
           }}
      end
    end
  end

  defmodule ErrorReq do
    def request(_opts) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => false, "error" => "channel_not_found"}}}
    end
  end

  test "send_message/3 encodes Slack payload into form params" do
    assert {:ok, %{"ts" => "1706745600.000100"}} =
             ReqClient.send_message("C123", "hi",
               token: "xoxb-test",
               req: MockReq,
               blocks: [%{type: "section"}],
               reply_broadcast: true
             )

    assert_received {:req_request, opts}
    assert opts[:url] == "https://slack.com/api/chat.postMessage"
    assert opts[:form]["channel"] == "C123"
    assert opts[:form]["text"] == "hi"
    assert opts[:form]["reply_broadcast"] == "true"
    assert is_binary(opts[:form]["blocks"])
  end

  test "Slack API errors are surfaced explicitly" do
    assert {:error, {:slack_api_error, "channel_not_found", _body}} =
             ReqClient.send_message("C123", "hi", token: "xoxb-test", req: ErrorReq)
  end

  test "send_file/3 performs Slack external upload flow" do
    assert {:ok, %{"files" => [%{"id" => "F123"}]}} =
             ReqClient.send_file(
               "C123",
               FileUpload.new(%{
                 kind: :file,
                 data: "hello slack\n",
                 filename: "bytes.txt",
                 media_type: "text/plain"
               }),
               token: "xoxb-test",
               req: MockReq,
               initial_comment: "upload comment",
               thread_ts: "1706745600.000100"
             )

    assert_received {:req_request, get_upload_opts}
    assert get_upload_opts[:url] == "https://slack.com/api/files.getUploadURLExternal"
    assert get_upload_opts[:form]["filename"] == "bytes.txt"
    assert get_upload_opts[:form]["length"] == "12"

    assert_received {:req_request, upload_bytes_opts}
    assert upload_bytes_opts[:url] == "https://files.slack.com/upload/v1/abc123"
    assert upload_bytes_opts[:body] == "hello slack\n"

    assert_received {:req_request, complete_opts}
    assert complete_opts[:url] == "https://slack.com/api/files.completeUploadExternal"
    assert complete_opts[:form]["channel_id"] == "C123"
    assert complete_opts[:form]["initial_comment"] == "upload comment"
    assert complete_opts[:form]["thread_ts"] == "1706745600.000100"
    assert is_binary(complete_opts[:form]["files"])
  end
end
