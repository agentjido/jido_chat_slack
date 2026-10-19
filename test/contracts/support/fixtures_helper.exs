defmodule Jido.Chat.Slack.ContractFixtures do
  @moduledoc false
  import ExUnit.Assertions
  alias Jido.Chat
  @root Path.expand("../fixtures", __DIR__)
  @rows @root |> Path.join("operations.json") |> File.read!() |> Jason.decode!()
  @boundary @root |> Path.join("boundary.json") |> File.read!() |> Jason.decode!()
  @incoming @root |> Path.join("incoming.json") |> File.read!() |> Jason.decode!()
  @trace "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

  def wire_child(observer),
    do: %{
      id: __MODULE__.Wire,
      start: {Agent, :start_link, [fn -> %{observer: observer, plan: []} end, [name: __MODULE__.Wire]]}
    }

  def rows, do: @rows
  def row(operation), do: Enum.find(@rows, &(&1["operation"] == operation))
  def boundary, do: @boundary
  def incoming, do: @incoming
  def trace, do: @trace
  def module(name), do: name |> String.split(".") |> Module.concat() |> Code.ensure_loaded!()

  def client(id \\ "alpha") do
    Chat.Client.new!(Chat.Slack.Adapter,
      id: id,
      credentials: %{token: "fixture-token:" <> id, app_token: "fixture-app:" <> id},
      config: [
        req: __MODULE__.Request,
        bot_user_id: "UBOT",
        trigger_id: "private-trigger",
        options_loader: fn _ -> %{options: [%{label: "Alpha", value: "a"}]} end
      ]
    )
  end

  def request(row, client, extra \\ %{}) do
    data = row["data"] |> scope(client.id) |> Map.merge(extra)

    module(row["definition"]).new!(Map.merge(data, %{"client_id" => client.id, "request_id" => "contract-request"}),
      source: client.source,
      extensions: %{"traceparent" => @trace, "tracestate" => "contract=slack"}
    )
  end

  defp scope(value, id) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, if(k == "client_id", do: id, else: scope(v, id))} end)

  defp scope(value, id) when is_list(value), do: Enum.map(value, &scope(&1, id))
  defp scope(value, _), do: value

  def plan(rows) do
    Agent.update(__MODULE__.Wire, fn %{observer: observer} -> %{observer: observer, plan: rows} end)
  end

  def empty do
    assert Agent.get(__MODULE__.Wire, & &1.plan) == []
  end

  def subset(actual, expected) when is_map(expected) do
    for {key, value} <- expected do
      assert Map.has_key?(actual, key), "missing fixture key #{key}"
      subset(actual[key], value)
    end
  end

  def subset(actual, expected), do: assert(actual == expected)

  def checked(client, request, completed) do
    assert completed.type == request.type <> ".completed"
    assert completed.data["request_id"] == request.data["request_id"]
    assert completed.data["client_id"] == client.id
    assert completed.data["operation"] == request.type
    assert completed.source == client.source
    assert completed.extensions["jidocausationid"] == request.id
    assert completed.extensions["traceparent"] == @trace
    assert completed.extensions["tracestate"] == "contract=slack"
    round_trip(client, completed)
    completed
  end

  def round_trip(client, signal) do
    assert {:ok, json} = Jido.Signal.Serialization.serialize(signal)

    for secret <- ["fixture-token:", "fixture-app:", "private-trigger", "private-response", "never-project-this"],
        do: refute(json =~ secret)

    assert {:ok, decoded} = Jido.Signal.Catalog.decode(Chat.catalog(client), json)
    assert decoded == signal
    signal
  end
end

defmodule Jido.Chat.Slack.ContractFixtures.Request do
  @moduledoc false
  import ExUnit.Assertions
  alias Jido.Chat.Slack.ContractFixtures, as: F

  def request(options) do
    {row, observer} =
      Agent.get_and_update(F.Wire, fn
        %{plan: [first | rest], observer: observer} = state -> {{first, observer}, %{state | plan: rest}}
        %{plan: []} -> raise "unplanned provider I/O"
      end)

    method = String.replace_prefix(options[:url], "https://slack.com/api/", "")
    send(observer, {:wire, method, options})
    assert method == row["method"]
    F.subset(options[:form] || %{}, row["form"] || %{})
    if method == "https://files.slack.com/upload/proof", do: assert(options[:body] == "bytes")

    case row["body"] do
      "offline" ->
        {:error, :offline}

      body ->
        {:ok, %Req.Response{status: row["status"] || 200, body: body, headers: %{"content-type" => ["text/plain"]}}}
    end
  end
end

defmodule Jido.Chat.Slack.ContractFixtures.Flow do
  @moduledoc false
  use Jido.Flow, name: "slack_contract_flow"

  flow do
    step("message", action: Jido.Chat.SendMessage, params: %{signal: input(:message)})
    step("card", action: Jido.Chat.Slack.SendCard, params: %{signal: input(:card)}, needs: ["message"])
    output(%{message: result("message", [:signal]), card: result("card", [:signal])})
  end
end
