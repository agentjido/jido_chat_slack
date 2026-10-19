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

  test "open_socket/2 uses runtime base_url" do
    assert {:ok, "wss://slack.example/socket"} =
             ReqClient.open_socket("xapp-test",
               req: MockReq,
               base_url: "https://slack-proxy.test/api"
             )

    assert_received {:req_request, opts}
    assert opts[:url] == "https://slack-proxy.test/api/apps.connections.open"
  end

  defmodule ResponseReq do
    def request(_opts), do: Process.get(:socket_response)
  end

  test "opening a session returns network, HTTP, and invalid response errors" do
    for {response, expected} <- [
          {{:error, :offline}, {:error, :offline}},
          {{:ok, %Req.Response{status: 503, body: "bad"}}, {:error, {:http_error, 503, "bad"}}},
          {{:ok, %Req.Response{status: 200, body: %{"ok" => true}}}, {:error, {:missing_socket_url, %{"ok" => true}}}},
          {{:ok, %Req.Response{status: 200, body: "bad"}}, {:error, {:invalid_response, "bad"}}}
        ] do
      Process.put(:socket_response, response)
      assert ReqClient.open_socket("test", req: ResponseReq) == expected
    end

    for headers <- [%{"x-test" => "yes"}, [{"x-test", "yes"}]] do
      assert {:ok, _} = ReqClient.open_socket("test", req: MockReq, headers: headers)
      assert_receive {:req_request, opts}
      assert {"x-test", "yes"} in opts[:headers]
    end
  end
end
