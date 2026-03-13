defmodule Jido.Chat.Slack.SocketMode.ReqClientTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Slack.SocketMode.ReqClient

  defmodule MockReq do
    def request(opts) do
      send(self(), {:req_request, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{"ok" => true, "url" => "wss://slack.example/socket"}
       }}
    end
  end

  defmodule ErrorReq do
    def request(_opts) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"ok" => false, "error" => "not_authed"}
       }}
    end
  end

  test "open_socket/2 calls apps.connections.open with the app token" do
    assert {:ok, "wss://slack.example/socket"} =
             ReqClient.open_socket("xapp-test", req: MockReq)

    assert_received {:req_request, opts}
    assert opts[:url] == "https://slack.com/api/apps.connections.open"
    assert {"authorization", "Bearer xapp-test"} in opts[:headers]
  end

  test "open_socket/2 surfaces Slack API errors explicitly" do
    assert {:error, {:slack_api_error, "not_authed", _body}} =
             ReqClient.open_socket("xapp-test", req: ErrorReq)
  end
end
