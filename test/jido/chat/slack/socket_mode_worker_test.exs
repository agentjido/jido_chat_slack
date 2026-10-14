defmodule Jido.Chat.Slack.SocketModeWorkerTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Slack.{Adapter, SocketModeWorker}
  alias Jido.Chat.Delivery

  defmodule Sink do
    def emit(test_pid, payload, opts) do
      send(test_pid, {:ordered, :sink})
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

  defmodule FailureSink do
    def emit(test_pid, mode, delivery, _opts) do
      send(test_pid, {:ordered, :sink})
      send(test_pid, {:sink_emit, delivery, mode})

      case mode do
        :error -> {:error, :rejected}
        :raise -> raise "sink failure"
        :throw -> throw(:sink_failure)
        :exit -> exit(:sink_failure)
        :invalid -> :unexpected
      end
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
      Process.put({__MODULE__, :test_pid}, test_pid)
      socket = spawn(fn -> loop(owner, test_pid) end)

      send(test_pid, {:socket_connect, url, socket})
      send(owner, {:socket_mode, socket, :connected})

      {:ok, socket}
    end

    @impl true
    def send_text(socket, payload) do
      if test_pid = Process.get({__MODULE__, :test_pid}) do
        send(test_pid, {:ordered, :ack})
        send(test_pid, {:ack_call, payload})
      end

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

  defp captured_binding do
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "bridge_slack", token: "fixture-token", app_token: "xapp-test")
    binding
  end

  test "adapter listener_child_specs/2 returns expected webhook/socket_mode specs" do
    assert {:ok, []} = Adapter.listener_child_specs("bridge_slack", ingress: %{mode: "webhook"})

    assert {:error, :invalid_binding} =
             Adapter.listener_child_specs("bridge_slack", ingress: %{mode: "socket_mode"})

    assert {:ok, [spec]} =
             Adapter.listener_child_specs("bridge_slack",
               binding: captured_binding(),
               ingress: %{
                 mode: "socket_mode",
                 app_token: "xapp-test",
                 transport_opts: %{"base_url" => "https://slack-proxy.test/api"}
               },
               sink_mfa: {Sink, :emit, [self()]}
             )

    assert spec.id == {:slack_socket_mode_worker, "bridge_slack"}
    assert {SocketModeWorker, :start_link, [worker_opts]} = spec.start
    assert worker_opts[:open_client_opts][:base_url] == "https://slack-proxy.test/api"
  end

  test "socket mode worker acknowledges envelopes and emits inner payloads through sink" do
    {:ok, responses_agent} = Agent.start_link(fn -> [{:ok, "wss://slack.example/socket-1"}] end)

    {:ok, pid} =
      start_supervised(
        {SocketModeWorker,
         bridge_id: "bridge_slack",
         binding: captured_binding(),
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

    assert_receive {:sink_emit, %Delivery{signals: [fact]}, opts}, 200
    assert fact.type == "jido.chat.message.received"
    assert fact.data["mentioned"]
    assert opts == []
    refute Map.has_key?(fact.data, "raw")
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
         binding: captured_binding(),
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
         binding: captured_binding(),
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
          "view" => %{
            "id" => "V123",
            "callback_id" => "feedback",
            "private_metadata" => Jason.encode!(%{"channel_id" => "C123"})
          }
        }
      })

    send(pid, {:socket_mode, socket, {:text, raw_envelope}})

    assert_receive {:sink_emit, %Delivery{signals: [fact]}, _opts}, 200
    assert fact.type == "jido.chat.modal.submitted"

    assert_receive {:socket_send_text, ^socket, ack_payload}, 200

    assert Jason.decode!(ack_payload) == %{
             "envelope_id" => "env-inline",
             "payload" => %{"response_action" => "clear"}
           }
  end

  test "ordinary and response-bearing envelopes preserve their declared acknowledgement order" do
    for response? <- [false, true] do
      {:ok, responses} = Agent.start_link(fn -> [{:ok, "wss://slack.example/socket"}] end)

      {:ok, pid} =
        SocketModeWorker.start_link(
          bridge_id: "bridge_slack",
          binding: captured_binding(),
          sink_mfa: {Sink, :emit, [self()]},
          open_client: OpenClient,
          open_client_opts: [test_pid: self(), responses_agent: responses],
          socket_client: SocketClient,
          socket_client_opts: [test_pid: self()],
          reconnect_interval_ms: 60_000
        )

      assert_receive {:open_socket, _}
      assert_receive {:socket_connect, _, socket}

      envelope = %{
        "type" => "events_api",
        "envelope_id" => "ordered",
        "accepts_response_payload" => response?,
        "payload" => %{
          "type" => "event_callback",
          "event_id" => "Ev1",
          "event" => %{"type" => "message", "channel" => "C1", "user" => "U1", "ts" => "1.01", "text" => "hello"}
        }
      }

      send(pid, {:socket_mode, socket, {:text, Jason.encode!(envelope)}})

      assert_receive {:ordered, first}
      assert_receive {:ordered, second}
      assert [first, second] == if(response?, do: [:sink, :ack], else: [:ack, :sink])

      if response? do
        assert_receive {:sink_emit, %Delivery{}, _}
        assert_receive {:ack_call, _}
      else
        assert_receive {:ack_call, _}
        assert_receive {:sink_emit, %Delivery{}, _}
      end

      _ = :sys.get_state(pid)
      assert_receive {:socket_send_text, ^socket, _}
      GenServer.stop(pid)
      SocketClient.close(socket)
      Agent.stop(responses)
      assert_receive {:socket_close, ^socket}
    end
  end

  test "whole-payload size failure prevents acknowledgement and every sink call" do
    {:ok, responses} = Agent.start_link(fn -> [{:ok, "wss://slack.example/socket"}] end)

    {:ok, pid} =
      start_supervised(
        {SocketModeWorker,
         bridge_id: "bridge_slack",
         binding: captured_binding(),
         sink_mfa: {Sink, :emit, [self()]},
         open_client: OpenClient,
         open_client_opts: [test_pid: self(), responses_agent: responses],
         socket_client: SocketClient,
         socket_client_opts: [test_pid: self()],
         reconnect_interval_ms: 60_000}
      )

    assert_receive {:open_socket, _}
    assert_receive {:socket_connect, _, socket}

    envelope = %{
      "type" => "events_api",
      "envelope_id" => "large",
      "payload" => %{
        "type" => "event_callback",
        "event" => %{
          "type" => "message",
          "channel" => "C1",
          "user" => "U1",
          "ts" => "1.01",
          "text" => String.duplicate("x", 262_144)
        }
      }
    }

    send(pid, {:socket_mode, socket, {:text, Jason.encode!(envelope)}})
    _ = :sys.get_state(pid)
    refute_received {:ack_call, _}
    refute_received {:sink_emit, _, _}
    refute_received {:socket_send_text, _, _}
    SocketClient.close(socket)
    assert_receive {:socket_close, ^socket}
  end

  for response? <- [false, true], mode <- [:error, :raise, :throw, :exit, :invalid] do
    test "sink #{mode} keeps acknowledgement order and the worker for response #{response?}" do
      {:ok, responses} = Agent.start_link(fn -> [{:ok, "wss://slack.example/socket"}] end)

      pid =
        start_supervised!(
          {SocketModeWorker,
           bridge_id: "bridge_slack",
           binding: captured_binding(),
           sink_mfa: {FailureSink, :emit, [self(), unquote(mode)]},
           open_client: OpenClient,
           open_client_opts: [test_pid: self(), responses_agent: responses],
           socket_client: SocketClient,
           socket_client_opts: [test_pid: self()],
           reconnect_interval_ms: 60_000}
        )

      assert_receive {:open_socket, _}
      assert_receive {:socket_connect, _, socket}

      envelope = %{
        "type" => "events_api",
        "envelope_id" => "failure",
        "accepts_response_payload" => unquote(response?),
        "payload" => %{
          "type" => "event_callback",
          "event_id" => "Ev1",
          "event" => %{"type" => "message", "channel" => "C1", "user" => "U1", "ts" => "1.01", "text" => "hello"}
        }
      }

      send(pid, {:socket_mode, socket, {:text, Jason.encode!(envelope)}})
      assert_receive {:ordered, first}
      assert_receive {:ordered, second}
      assert [first, second] == if(unquote(response?), do: [:sink, :ack], else: [:ack, :sink])
      assert_receive {:sink_emit, %Delivery{signals: [_]}, mode}
      assert mode == unquote(mode)
      assert_receive {:ack_call, ack}
      assert Jason.decode!(ack) == %{"envelope_id" => "failure"}
      assert_receive {:socket_send_text, ^socket, ^ack}
      assert :sys.get_state(pid).socket == socket
      refute_received {:ordered, _}
      refute_received {:sink_emit, _, _}
      refute_received {:ack_call, _}
      SocketClient.close(socket)
      assert_receive {:socket_close, ^socket}
    end
  end

  for response? <- [false, true], limit <- [:count, :failures, :aggregate] do
    test "complete #{limit} rejection has zero sink and ack calls for response #{response?}" do
      {:ok, responses} = Agent.start_link(fn -> [{:ok, "wss://slack.example/socket"}] end)
      binding = captured_binding()

      pid =
        start_supervised!(
          {SocketModeWorker,
           bridge_id: "bridge_slack",
           binding: binding,
           sink_mfa: {Sink, :emit, [self()]},
           open_client: OpenClient,
           open_client_opts: [test_pid: self(), responses_agent: responses],
           socket_client: SocketClient,
           socket_client_opts: [test_pid: self()],
           reconnect_interval_ms: 60_000}
        )

      assert_receive {:open_socket, _}
      assert_receive {:socket_connect, _, socket}

      actions =
        case unquote(limit) do
          :count -> Enum.map(1..101, &%{"action_id" => to_string(&1)})
          :failures -> Enum.map(1..21, &%{"value" => to_string(&1)})
          :aggregate -> Enum.map(1..60, &%{"action_id" => to_string(&1), "value" => String.duplicate("x", 20_000)})
        end

      envelope = %{
        "envelope_id" => "limit",
        "accepts_response_payload" => unquote(response?),
        "payload" => %{
          "type" => "block_actions",
          "channel" => %{"id" => "C1"},
          "trigger_id" => "private-trigger",
          "actions" => actions
        }
      }

      send(pid, {:socket_mode, socket, {:text, Jason.encode!(envelope)}})
      _ = :sys.get_state(pid)
      refute_received {:ordered, _}
      refute_received {:sink_emit, _, _}
      refute_received {:ack_call, _}
      refute_received {:socket_send_text, _, _}
      resources = Enum.filter(:ets.tab2list(binding.resources), &(elem(elem(&1, 0), 0) == :resource))
      assert [{{:resource, _}, _, "result", nil, _, :cancelled}] = resources
      SocketClient.close(socket)
      assert_receive {:socket_close, ^socket}
    end
  end
end
