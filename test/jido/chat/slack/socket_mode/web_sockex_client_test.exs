defmodule Jido.Chat.Slack.SocketMode.WebSockexClientTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.Slack.SocketMode.WebSockexClient, as: W

  test "Socket Mode defaults verify the peer, trust chain, SNI and HTTPS hostname" do
    opts = W.connection_options("wss://wss-primary.slack.com/link", [])
    refute opts[:insecure]
    ssl = opts[:ssl_options]
    assert ssl[:verify] == :verify_peer
    assert ssl[:cacerts] == :public_key.cacerts_get()
    assert ssl[:server_name_indication] == ~c"wss-primary.slack.com"
    match = ssl[:customize_hostname_check][:match_fun]
    assert match.({:dns_id, ~c"wss-primary.slack.com"}, {:dNSName, ~c"*.slack.com"})
    refute match.({:dns_id, ~c"evil.example"}, {:dNSName, ~c"*.slack.com"})
  end

  test "frames reach the owner and ACK frames contain only the requested payload" do
    state = %{owner: self()}
    assert {:ok, state} = W.handle_connect(nil, state)
    assert_receive {:socket_mode, _, :connected}
    assert is_reference(state.owner_monitor)
    assert {:ok, ^state} = W.handle_frame({:text, "envelope"}, state)
    assert_receive {:socket_mode, _, {:text, "envelope"}}
    assert {:ok, ^state} = W.handle_frame({:binary, <<1>>}, state)
    assert_receive {:socket_mode, _, {:binary, <<1>>}}
    assert {:ok, ^state} = W.handle_frame({:ping, ""}, state)
    assert {:reply, {:text, "ack"}, ^state} = W.handle_cast({:send_text, "ack"}, state)
    assert {:close, ^state} = W.handle_cast(:close, state)
    assert {:ok, ^state} = W.handle_cast(:unknown, state)
    assert {:ok, ^state} = W.handle_info(:unknown, state)
    assert {:close, ^state} = W.handle_info({:DOWN, state.owner_monitor, :process, self(), :normal}, state)
    assert {:ok, ^state} = W.handle_disconnect(%{reason: :closed}, state)
    assert_receive {:socket_mode, _, {:disconnected, :closed}}
    Process.demonitor(state.owner_monitor)
  end

  test "socket handles accept send and close requests" do
    assert W.send_text(self(), "ack") == :ok
    assert_receive {_, {:send_text, "ack"}}
    assert W.close(self()) == :ok
    assert_receive {_, :close}
  end

  test "connections link to their worker and stop when the worker stops" do
    Process.flag(:trap_exit, true)

    for headers <- [nil, %{"x-test" => "yes"}, [{"x-test", "yes"}]] do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, socket} = W.connect("ws://127.0.0.1:1", owner, headers: headers)
      ref = Process.monitor(socket)
      W.close(socket)
      assert_receive {:DOWN, ^ref, :process, ^socket, _}, 2_000
      send(owner, :stop)
    end
  end
end
