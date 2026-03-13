defmodule Jido.Chat.Slack.Transport.ReqClientTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Slack.Transport.ReqClient

  defmodule MockReq do
    def request(opts) do
      send(self(), {:req_request, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"ok" => true, "channel" => "C123", "ts" => "1706745600.000100"}
       }}
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
end
