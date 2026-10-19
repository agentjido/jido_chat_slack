defmodule Jido.Chat.Slack.SourceTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias Jido.Chat.{Client, Sensor}
  alias Jido.Chat.Slack.{Adapter, Source}

  alias Jido.Chat.Slack.SocketFixtures.{Connection, TestSocket}

  setup do
    control = start_supervised!({Agent, fn -> [] end})
    client = Client.new!(Adapter, id: "slack-source", credentials: %{token: "bot", app_token: "app"})

    options = [
      connection_client: Connection,
      socket_client: TestSocket,
      connection_options: [test: self(), control: control],
      socket_options: [test: self()],
      reconnect_interval: 5,
      max_reconnect_interval: 10
    ]

    %{client: client, options: options, control: control}
  end

  defp envelope(id \\ "E1", event_id \\ "Ev1") do
    %{
      "type" => "events_api",
      "envelope_id" => id,
      "payload" => %{
        "event_id" => event_id,
        "event" => %{"type" => "message", "channel" => "C1", "user" => "U1", "ts" => "1.001", "text" => "hello"}
      }
    }
  end

  defp start_sensor(ctx, extra \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {Sensor,
         Keyword.merge(
           [
             client: ctx.client,
             source: Source,
             emit: "jido.chat.**",
             dispatch: {:pid, target: self()},
             options: ctx.options
           ],
           extra
         )},
        restart: :temporary
      )
    )
  end

  defp deliver(socket, worker, value), do: send(worker, {:socket_mode, socket, {:text, Jason.encode!(value)}})

  test "source declares admitted facts and hides credential identity", ctx do
    assert Source.mode() == :push
    assert "jido.chat.message.received" in Source.signal_types()
    assert byte_size(Source.key(ctx.client, [])) == 32
    assert Source.key(%{ctx.client | credentials: %{}}, []) == nil
    assert {:error, :missing_app_token} = Source.start_link(%{ctx.client | credentials: %{}}, self(), [])
  end

  test "input reaches shared Sensor before ACK and repeated events are suppressed", ctx do
    sensor = start_sensor(ctx)
    assert_receive {:socket, socket, worker}
    send(worker, {:socket_mode, socket, :connected})
    deliver(socket, worker, envelope())
    assert_receive {:signal, signal}
    assert signal.type == "jido.chat.message.received"
    assert signal.data["text"] == "hello"
    assert_receive {:ack, ^socket, %{"envelope_id" => "E1"}}
    deliver(socket, worker, envelope("E2"))
    assert_receive {:ack, ^socket, %{"envelope_id" => "E2"}}
    refute_receive {:signal, _}, 30
    GenServer.stop(sensor)
    assert_receive :closed
    refute Process.alive?(worker)
  end

  test "filtered rooms are admitted without chat dispatch", ctx do
    start_sensor(ctx, rooms: ["C2"])
    assert_receive {:socket, socket, worker}
    deliver(socket, worker, envelope())
    assert_receive {:ack, ^socket, _}
    refute_receive {:signal, _}, 30
  end

  test "connection failures retry and disconnect opens a fresh URL", ctx do
    Agent.update(ctx.control, fn _ -> [{:error, :offline}] end)
    start_sensor(ctx)
    assert_receive :open_socket
    assert_receive :open_socket
    assert_receive {:socket, socket, worker}
    deliver(socket, worker, %{"type" => "disconnect", "reason" => "refresh_requested"})
    assert_receive :closed
    assert_receive :open_socket
    assert_receive {:socket, next, ^worker}
    refute socket == next
    # Frames from the previous session cannot produce an ACK or a fact.
    deliver(socket, worker, envelope())
    refute_receive {:ack, ^socket, _}, 20
    deliver(next, worker, envelope())
    assert_receive {:signal, _}, 1_000
    assert_receive {:ack, ^next, _}, 1_000
  end

  test "malformed frames are ignored and socket death reconnects", ctx do
    start_sensor(ctx)
    assert_receive {:socket, socket, worker}
    send(worker, {:socket_mode, socket, {:text, "bad json"}})
    deliver(socket, worker, %{"type" => "hello"})
    send(worker, {:socket_mode, socket, {:binary, <<0>>}})
    send(worker, :unused)
    refute_receive {:ack, _, _}, 20
    Process.exit(socket, :kill)
    assert_receive {:socket, next, ^worker}
    send(worker, {:socket_mode, next, {:disconnected, :closed}})
    assert_receive :closed
    assert_receive {:socket, _, ^worker}
  end

  test "rejected input is not acknowledged and reconnects", ctx do
    # A dead dispatch PID rejects admission.
    target = spawn(fn -> :ok end)
    ref = Process.monitor(target)
    assert_receive {:DOWN, ^ref, _, _, _}
    start_sensor(ctx, dispatch: {:pid, target: target})
    assert_receive {:socket, socket, worker}
    deliver(socket, worker, envelope())
    assert_receive :closed
    refute_receive {:ack, ^socket, _}, 20
    assert_receive {:socket, _, ^worker}
  end

  test "worker failure stops the Sensor and its socket", ctx do
    sensor = start_sensor(ctx)
    assert_receive {:socket, socket, worker}
    sensor_ref = Process.monitor(sensor)
    socket_ref = Process.monitor(socket)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^sensor_ref, :process, ^sensor, {:source_exit, :killed}}
    assert_receive {:DOWN, ^socket_ref, :process, ^socket, :normal}
    assert_receive :owner_down
  end

  test "normalization failure is not acknowledged", ctx do
    start_sensor(ctx)
    assert_receive {:socket, socket, worker}
    deliver(socket, worker, %{"envelope_id" => "invalid", "payload" => 42})
    assert_receive :closed
    refute_receive {:ack, ^socket, _}, 20
  end
end
