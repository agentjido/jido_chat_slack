Code.require_file("support/fixtures_helper.exs", __DIR__)

defmodule Jido.Chat.Slack.SourceContractTest do
  use Covenant.Case, component: "jido_chat_slack.source", async: false
  @moduletag capture_log: true
  alias Jido.Chat
  alias Jido.Chat.Slack.ContractFixtures, as: F
  alias Jido.Chat.Slack.{InteractionResponse, Operations}
  alias Jido.Chat.Slack.SocketFixtures.{Connection, TestSocket}
  alias Jido.Chat.Slack.Source

  defmodule StaticConnection do
    def open_socket(_, _), do: {:ok, "wss://contract"}
  end

  defmodule StaticSocket do
    def connect(_, owner, _) do
      socket = spawn(fn -> receive do: (:close -> :ok) end)
      send(F.Observer, {:socket, socket, owner})
      {:ok, socket}
    end

    def send_text(socket, text),
      do:
        (
          send(F.Observer, {:ack, socket, Jason.decode!(text)})
          :ok
        )

    def close(socket), do: send(socket, :close)
  end

  setup do
    control = start_supervised!({Agent, fn -> [] end})
    start_supervised!(F.wire_child(self()))

    options = [
      connection_client: Connection,
      socket_client: TestSocket,
      connection_options: [test: self(), control: control],
      socket_options: [test: self()],
      reconnect_interval: 5,
      max_reconnect_interval: 10,
      push_timeout: 40
    ]

    %{client: F.client(), options: options}
  end

  defp envelope(id \\ "E1") do
    %{
      "envelope_id" => id,
      "accepts_response_payload" => true,
      "payload" => %{
        "event_id" => "Ev-contract",
        "event" => %{
          "type" => "message",
          "channel" => "C1",
          "user" => "U1",
          "text" => "Jido Agent proof contract",
          "ts" => "1700000000.000001"
        }
      }
    }
  end

  defp deliver(socket, worker, envelope), do: send(worker, {:socket_mode, socket, {:text, Jason.encode!(envelope)}})

  defp sensor(ctx, extra \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {Chat.Sensor,
         Keyword.merge(
           [
             client: ctx.client,
             source: Source,
             rooms: ["C1"],
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

  @tag obligation: "jido_chat_slack.source.I1"
  test "source ownership is hashed and discovery cannot send a Chat command", ctx do
    assert Source.mode() == :push
    assert MapSet.new(Source.signal_types()) == MapSet.new(Enum.map(Chat.event_definitions(ctx.client), & &1.type()))
    assert Source.key(ctx.client, []) == :crypto.hash(:sha256, "fixture-app:alpha")
    assert Source.key(F.client("beta"), []) != Source.key(ctx.client, [])
    assert {:error, :missing_app_token} = Source.start_link(%{ctx.client | credentials: %{}}, self(), ctx.options)
    refute_receive :open_socket
    refute_receive {:wire, _, _}
  end

  @tag obligation: "jido_chat_slack.source.I2"
  test "shared Sensor admits one scoped fact, suppresses duplicates and filters rooms before ACK", ctx do
    pid = sensor(ctx)
    assert_receive {:socket, socket, worker}, 1_000
    deliver(socket, worker, envelope())
    assert_receive {:signal, fact}, 1_000
    assert fact.data["room_id"] == "C1"
    assert fact.data["message_id"] == "1700000000.000001"
    F.round_trip(ctx.client, fact)
    assert_receive {:ack, ^socket, %{"envelope_id" => "E1"} = ack}, 1_000
    assert map_size(ack) == 1
    deliver(socket, worker, envelope("E2"))
    assert_receive {:ack, ^socket, %{"envelope_id" => "E2"}}, 1_000
    refute_receive {:signal, _}, 30
    filtered = put_in(envelope("E3"), ["payload", "event", "channel"], "C-other")
    deliver(socket, worker, filtered)
    assert_receive {:ack, ^socket, %{"envelope_id" => "E3"}}, 1_000
    refute_receive {:signal, _}, 30
    GenServer.stop(pid)
    assert_receive :closed, 1_000
    refute Process.alive?(worker)
    refute_receive {:wire, _, _}
  end

  @tag obligation: "jido_chat_slack.source.I2"
  test "ACK cannot occur while Sensor admission is pending", ctx do
    owner = self()

    gate =
      spawn_link(fn ->
        receive do
          {:"$gen_call", from, {:push, facts}} ->
            send(owner, {:pending_admission, self(), facts})

            receive do
              :release -> GenServer.reply(from, :ok)
            end

            receive do: (:stop -> :ok)
        end
      end)

    {:ok, worker} = Source.start_link(ctx.client, gate, Keyword.put(ctx.options, :push_timeout, 1_000))

    on_exit(fn ->
      if Process.alive?(worker), do: GenServer.stop(worker)
      send(gate, :stop)
    end)

    assert_receive {:socket, socket, ^worker}, 1_000
    deliver(socket, worker, envelope())
    assert_receive {:pending_admission, ^gate, [_]}, 1_000
    refute_receive {:ack, _, _}, 40
    send(gate, :release)
    assert_receive {:ack, ^socket, %{"envelope_id" => "E1"}}, 1_000
    GenServer.stop(worker)
    send(gate, :stop)
  end

  @tag obligation: "jido_chat_slack.source.I3"
  test "timed-out admission has no ACK and a fresh socket ignores frames from the old session", ctx do
    gate = spawn_link(fn -> receive do: (:stop -> :ok) end)
    {:ok, worker} = Source.start_link(ctx.client, gate, ctx.options)

    on_exit(fn ->
      if Process.alive?(worker), do: GenServer.stop(worker)
      send(gate, :stop)
    end)

    assert_receive {:socket, socket, ^worker}, 1_000
    deliver(socket, worker, envelope())
    assert_receive :closed, 1_000
    refute_receive {:ack, ^socket, _}, 30
    assert_receive {:socket, next, ^worker}, 1_000
    refute socket == next
    deliver(socket, worker, envelope("old"))
    refute_receive {:ack, _, _}, 30
    GenServer.stop(worker)
    send(gate, :stop)
    assert_receive :closed, 1_000
  end

  @tag obligation: "jido_chat_slack.source.I3"
  test "disconnect refreshes the connection and Sensor shutdown closes all owned work", ctx do
    pid = sensor(ctx)
    assert_receive {:socket, socket, worker}, 1_000
    deliver(socket, worker, %{"type" => "disconnect", "reason" => "refresh_requested"})
    assert_receive :closed, 1_000
    assert_receive {:socket, next, ^worker}, 1_000
    refute socket == next
    ref = Process.monitor(worker)
    socket_ref = Process.monitor(next)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, _, ^worker, reason}, 1_000
    assert reason in [:normal, :shutdown]
    assert_receive :closed, 1_000
    assert_receive {:DOWN, ^socket_ref, _, ^next, :normal}, 1_000
  end

  @tag obligation: "jido_chat_slack.source.I4"
  test "webhook signatures use exact bytes and explicit option responses remain a host boundary", ctx do
    timestamp = "1000"
    body = "{\"event\":\"proof\"}"
    mac = :crypto.mac(:hmac, :sha256, "private-signing-secret", "v0:" <> timestamp <> ":" <> body)
    signature = "v0=" <> Base.encode16(mac, case: :lower)
    request = %{headers: %{"x-slack-request-timestamp" => timestamp, "x-slack-signature" => signature}, raw: body}
    assert :ok = Operations.verify_webhook(request, signing_secret: "private-signing-secret", now: 1_000)

    assert {:error, :invalid_signature} =
             Operations.verify_webhook(%{request | raw: body <> " "},
               signing_secret: "private-signing-secret",
               now: 1_000
             )

    assert {:error, :stale_timestamp} =
             Operations.verify_webhook(request, signing_secret: "private-signing-secret", now: 1_301)

    req = F.request(F.row("load_options"), ctx.client)
    started = System.monotonic_time(:millisecond)
    assert {:ok, complete} = Chat.execute(ctx.client, req)
    # This is a local response budget check. It does not prove a deployed HTTP deadline.
    assert System.monotonic_time(:millisecond) - started < 2_500
    e = %{"envelope_id" => "E-options", "accepts_response_payload" => true}

    expected = %{
      "options" => [%{"text" => %{"type" => "plain_text", "text" => "Alpha", "emoji" => true}, "value" => "a"}]
    }

    assert InteractionResponse.socket_ack_payload(e, {:ok, complete}) == %{
             "envelope_id" => "E-options",
             "payload" => expected
           }

    assert InteractionResponse.socket_ack_payload(Map.delete(e, "accepts_response_payload"), {:ok, complete}) == %{
             "envelope_id" => "E-options"
           }

    assert InteractionResponse.webhook_response({:ok, complete}) == %{status: 200, body: expected}
    F.round_trip(ctx.client, complete)
  end

  @tag obligation: "jido_chat_slack.source.I5"
  test "Socket input reaches a real Agent Plugin and shared Action before one provider reply", ctx do
    {:ok, _} = Application.ensure_all_started(:jido)
    start_supervised!({Jido, name: Jido.Chat.Slack.ContractJido})
    definition = Jido.Chat.Slack.LiveAgent.definition()
    [entry] = definition.extensions
    [connection] = entry.data.connections
    Process.register(self(), F.Observer)
    on_exit(fn -> if Process.whereis(F.Observer) == self(), do: Process.unregister(F.Observer) end)
    source_options = [connection_client: StaticConnection, socket_client: StaticSocket]
    source = %{connection.source | options: source_options}

    connection = %{
      connection
      | rooms: ["C1"],
        source: source,
        client:
          Map.merge(
            connection.client,
            Map.take(%{ctx.client | config: [req: F.Request, bot_user_id: "UBOT"]}, [
              :adapter,
              :id,
              :credentials,
              :config,
              :transport
            ])
          )
    }

    definition = %{definition | extensions: [%{entry | data: %{entry.data | connections: [connection]}}]}
    {:ok, server} = Jido.start_agent(Jido.Chat.Slack.ContractJido, definition, id: "slack-contract-agent")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert :ok = Jido.AgentServer.await_ready(server)
    assert_receive {:socket, socket, worker}, 2_000

    F.plan([
      %{
        "method" => "chat.postMessage",
        "form" => %{
          "channel" => "C1",
          "thread_ts" => "1700000000.000001",
          "text" => "Jido Agent received Socket Mode input."
        },
        "body" => %{"ok" => true, "channel" => "C1", "ts" => "1700000000.000002"}
      }
    ])

    deliver(socket, worker, envelope())
    assert_receive {:wire, "chat.postMessage", _}, 3_000
    assert_receive {:ack, ^socket, %{"envelope_id" => "E1"}}, 1_000
    result = await_result(server, 100)
    assert result.data["client_id"] == ctx.client.id
    assert result.data["result"]["thread_id"] == "1700000000.000001"
    assert result.data["result"]["id"] == "1700000000.000002"
    F.round_trip(ctx.client, result)
    deliver(socket, worker, envelope("E-duplicate"))
    assert_receive {:ack, ^socket, %{"envelope_id" => "E-duplicate"}}, 1_000
    refute_receive {:wire, _, _}, 40
    F.empty()
  end

  defmodule FailingSocket do
    defdelegate connect(url, owner, options), to: TestSocket

    def send_text(_, _) do
      Process.put(:private_debug, "private-response dictionary")
      raise("private-response and private-trigger must not reach a report")
    end

    defdelegate close(socket), to: TestSocket
  end

  @tag obligation: "jido_chat_slack.source.I6"
  test "OTP failure reports redact the raw frame, private options and exception data", ctx do
    import ExUnit.CaptureLog

    log =
      capture_log(fn ->
        pid = sensor(%{ctx | options: Keyword.put(ctx.options, :socket_client, FailingSocket)})
        assert_receive {:socket, socket, worker}, 1_000
        status = :sys.get_status(worker) |> inspect(limit: :infinity)
        refute status =~ "fixture-token"
        refute status =~ "fixture-app"
        refute status =~ "private-trigger"
        :ok = :sys.log(worker, true)
        ref = Process.monitor(pid)
        value = Map.put(envelope(), "response_url", "https://private-response.example/secret")
        deliver(socket, worker, value)
        assert_receive {:DOWN, ^ref, _, ^pid, _}, 2_000
      end)

    for value <- [
          "fixture-token",
          "fixture-app",
          "private-trigger",
          "private-response",
          "https://",
          "Jido Agent proof contract"
        ],
        do: refute(log =~ value)

    assert log =~ "source_failure"

    socket_status =
      Chat.Slack.SocketMode.WebSockexClient.format_status(:terminate, [
        [secret: "private-response"],
        %{raw: "private-trigger"}
      ])

    assert socket_status == [data: [{"State", :redacted}]]
  end

  defp await_result(_, 0), do: flunk("Agent result was not recorded")

  defp await_result(server, count) do
    case Jido.AgentServer.agent(server).state.result do
      nil ->
        Process.sleep(10)
        await_result(server, count - 1)

      result ->
        result
    end
  end
end
