defmodule Jido.Chat.Slack.SocketModeWorkerTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Slack.{Adapter, SocketModeWorker}

  defmodule Sink do
    def emit(test_pid, payload, opts) do
      send(test_pid, {:sink_emit, payload, opts})
      {:ok, :accepted}
    end
  end

  defmodule ReplySink do
    def emit(test_pid, payload, opts) do
      send(test_pid, {:sink_emit, payload, opts})
      {:reply, %{"response_action" => "clear"}}
    end
  end

  defmodule OpenClient do
    @behaviour Jido.Chat.Slack.SocketMode.Client

    @impl true
    def open_socket(app_token, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      responses_agent = Keyword.fetch!(opts, :responses_agent)

      send(test_pid, {:open_socket, app_token})

      Agent.get_and_update(responses_agent, fn
        [next | rest] -> {next, rest}
        [] -> {{:ok, "wss://slack.example/socket"}, []}
      end)
    end
  end

  defmodule SocketClient do
    @behaviour Jido.Chat.Slack.SocketMode.SocketClient

    @impl true
    def connect(url, owner, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      socket = spawn(fn -> loop(owner, test_pid) end)

      send(test_pid, {:socket_connect, url, socket})
      send(owner, {:socket_mode, socket, :connected})

      {:ok, socket}
    end

    @impl true
    def send_text(socket, payload) do
      send(socket, {:send_text, payload})
      :ok
    end

    @impl true
    def close(socket) do
      send(socket, :close)
      :ok
    end

    defp loop(owner, test_pid) do
      receive do
        {:send_text, payload} ->
          send(test_pid, {:socket_send_text, self(), payload})
          loop(owner, test_pid)

        :close ->
          send(test_pid, {:socket_close, self()})
          send(owner, {:socket_mode, self(), {:disconnected, :closed}})
          :ok
      end
    end
  end

  test "adapter listener_child_specs/2 returns expected webhook/socket_mode specs" do
    assert {:ok, []} = Adapter.listener_child_specs("bridge_slack", ingress: %{mode: "webhook"})

    assert {:error, :invalid_sink_mfa} =
             Adapter.listener_child_specs("bridge_slack", ingress: %{mode: "socket_mode"})

    assert {:ok, [spec]} =
             Adapter.listener_child_specs("bridge_slack",
               ingress: %{mode: "socket_mode", app_token: "xapp-test"},
               sink_mfa: {Sink, :emit, [self()]}
             )

    assert spec.id == {:slack_socket_mode_worker, "bridge_slack"}
  end

  test "socket mode worker acknowledges envelopes and emits inner payloads through sink" do
    {:ok, responses_agent} = Agent.start_link(fn -> [{:ok, "wss://slack.example/socket-1"}] end)

    {:ok, pid} =
      start_supervised(
        {SocketModeWorker,
         bridge_id: "bridge_slack",
         sink_mfa: {Sink, :emit, [self()]},
         app_token: "xapp-test",
         open_client: OpenClient,
         open_client_opts: [test_pid: self(), responses_agent: responses_agent],
         socket_client: SocketClient,
         socket_client_opts: [test_pid: self()],
         reconnect_interval_ms: 10,
         max_backoff_ms: 50}
      )

    assert_receive {:open_socket, "xapp-test"}, 200
    assert_receive {:socket_connect, "wss://slack.example/socket-1", socket}, 200

    envelope = %{
      "envelope_id" => "env-1",
      "type" => "events_api",
      "accepts_response_payload" => false,
      "payload" => %{
        "type" => "event_callback",
        "event" => %{
          "type" => "app_mention",
          "channel" => "C123",
          "user" => "U123",
          "text" => "<@Ubot> ping",
          "ts" => "1706745600.000100"
        }
      }
    }

    raw_envelope = Jason.encode!(envelope)
    send(pid, {:socket_mode, socket, {:text, raw_envelope}})

    assert_receive {:socket_send_text, ^socket, ack_payload}, 200
    assert Jason.decode!(ack_payload) == %{"envelope_id" => "env-1"}

    assert_receive {:sink_emit, payload, opts}, 200
    assert payload["type"] == "event_callback"
    assert opts[:mode] == :payload
    assert opts[:method] == "SOCKET"
    assert opts[:path] == "/socket_mode/events_api"
    assert opts[:raw_body] == raw_envelope
    assert opts[:request_metadata][:source] == :socket_mode
    assert opts[:request_metadata][:socket_envelope_id] == "env-1"
  end

  test "socket mode worker reconnects after Slack requests a disconnect" do
    {:ok, responses_agent} =
      Agent.start_link(fn ->
        [
          {:ok, "wss://slack.example/socket-1"},
          {:ok, "wss://slack.example/socket-2"}
        ]
      end)

    {:ok, pid} =
      start_supervised(
        {SocketModeWorker,
         bridge_id: "bridge_slack",
         sink_mfa: {Sink, :emit, [self()]},
         app_token: "xapp-test",
         open_client: OpenClient,
         open_client_opts: [test_pid: self(), responses_agent: responses_agent],
         socket_client: SocketClient,
         socket_client_opts: [test_pid: self()],
         reconnect_interval_ms: 10,
         max_backoff_ms: 50}
      )

    assert_receive {:open_socket, "xapp-test"}, 200
    assert_receive {:socket_connect, "wss://slack.example/socket-1", socket_1}, 200

    raw_envelope =
      Jason.encode!(%{
        "envelope_id" => "env-disconnect",
        "type" => "disconnect",
        "reason" => "refresh_requested"
      })

    send(pid, {:socket_mode, socket_1, {:text, raw_envelope}})

    assert_receive {:socket_send_text, ^socket_1, ack_payload}, 200
    assert Jason.decode!(ack_payload) == %{"envelope_id" => "env-disconnect"}
    assert_receive {:socket_close, ^socket_1}, 200
    assert_receive {:open_socket, "xapp-test"}, 300
    assert_receive {:socket_connect, "wss://slack.example/socket-2", socket_2}, 300
    refute socket_1 == socket_2
  end

  test "socket mode worker includes inline response payload when Slack accepts it" do
    {:ok, responses_agent} = Agent.start_link(fn -> [{:ok, "wss://slack.example/socket-1"}] end)

    {:ok, pid} =
      start_supervised(
        {SocketModeWorker,
         bridge_id: "bridge_slack",
         sink_mfa: {ReplySink, :emit, [self()]},
         app_token: "xapp-test",
         open_client: OpenClient,
         open_client_opts: [test_pid: self(), responses_agent: responses_agent],
         socket_client: SocketClient,
         socket_client_opts: [test_pid: self()],
         reconnect_interval_ms: 10,
         max_backoff_ms: 50}
      )

    assert_receive {:open_socket, "xapp-test"}, 200
    assert_receive {:socket_connect, "wss://slack.example/socket-1", socket}, 200

    raw_envelope =
      Jason.encode!(%{
        "envelope_id" => "env-inline",
        "type" => "interactive",
        "accepts_response_payload" => true,
        "payload" => %{
          "type" => "view_submission",
          "user" => %{"id" => "U123"},
          "view" => %{"id" => "V123", "callback_id" => "feedback"}
        }
      })

    send(pid, {:socket_mode, socket, {:text, raw_envelope}})

    assert_receive {:sink_emit, payload, _opts}, 200
    assert payload["type"] == "view_submission"

    assert_receive {:socket_send_text, ^socket, ack_payload}, 200

    assert Jason.decode!(ack_payload) == %{
             "envelope_id" => "env-inline",
             "payload" => %{"response_action" => "clear"}
           }
  end
end
