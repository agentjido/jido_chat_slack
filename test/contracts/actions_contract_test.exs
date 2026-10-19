Code.require_file("support/fixtures_helper.exs", __DIR__)

defmodule Jido.Chat.Slack.ActionsContractTest do
  use Covenant.Case, component: "jido_chat_slack.actions", async: false
  @moduletag capture_log: true
  alias Jido.Chat
  alias Chat.Slack.ContractFixtures, as: F

  setup do
    start_supervised!(F.wire_child(self()))
    :ok
  end

  defp card(client) do
    Chat.Slack.Signal.SendCard.new!(
      %{
        "client_id" => client.id,
        "request_id" => "card-request",
        "room_id" => "C1",
        "thread_id" => "1700000000.000001",
        "card" => %{"title" => "Card", "components" => []}
      },
      source: client.source,
      extensions: %{"traceparent" => F.trace(), "tracestate" => "contract=slack"}
    )
  end

  defp card_plan do
    [
      %{
        "method" => "chat.postMessage",
        "form" => %{"channel" => "C1", "thread_ts" => "1700000000.000001"},
        "body" => %{"ok" => true, "channel" => "C1", "ts" => "1700000000.000002"}
      }
    ]
  end

  @tag obligation: "jido_chat_slack.actions.I1"
  test "all native Actions execute serialized requests and preserve causal context" do
    for row <- F.rows() do
      client = F.client()
      F.plan(row["plan"])
      request = F.request(row, client)
      action = F.module(row["action"])
      assert {:ok, encoded} = Jido.Signal.Serialization.serialize(request)

      assert {:ok, %{signal: completed}} =
               Jido.Exec.run(action, %{"signal" => Jason.decode!(encoded)}, %{client: client}, max_attempts: 1)

      F.checked(client, request, completed)
      assert {:ok, _} = action.validate_output(%{signal: completed})
      F.subset(completed.data["result"], row["result"])
      F.empty()
    end
  end

  @tag obligation: "jido_chat_slack.actions.I2"
  test "SendCard executes through Chat and Exec for separate clients with exact Block Kit" do
    for id <- ["alpha", "beta"], path <- [:chat, :exec] do
      client = F.client(id)
      request = card(client)
      F.plan(card_plan())

      completed =
        case path do
          :chat ->
            assert({:ok, result} = Chat.execute(client, request))
            result

          :exec ->
            assert(
              {:ok, %{signal: result}} =
                Jido.Exec.run(Chat.Slack.SendCard, %{signal: request}, %{client: client}, max_attempts: 1)
            )

            result
        end

      F.checked(client, request, completed)
      assert completed.data["result"]["id"] == "1700000000.000002"
      assert_receive {:wire, "chat.postMessage", opts}

      assert Jason.decode!(opts[:form]["blocks"]) == [
               %{"type" => "header", "text" => %{"type" => "plain_text", "text" => "Card", "emoji" => true}}
             ]

      assert {"authorization", "Bearer fixture-token:" <> id} in opts[:headers]
      F.empty()
    end
  end

  @tag obligation: "jido_chat_slack.actions.I3"
  test "foreign requests and provider failures preserve privacy and causal failure context" do
    client = F.client()
    request = card(client)

    for bad <- [
          %{request | data: Map.put(request.data, "client_id", "beta")},
          %{request | dataschema: "urn:wrong"},
          %{request | data: Map.put(request.data, "token", "never-project-this")}
        ] do
      assert {:error, _} = Chat.execute(client, bad)
    end

    refute_receive {:wire, _, _}

    for {body, code} <- [
          {%{"ok" => false, "error" => "missing_scope", "raw" => "never-project-this"}, :forbidden},
          {"offline", :provider_failure}
        ] do
      F.plan([%{"method" => "chat.postMessage", "body" => body}])
      assert {:error, %{code: ^code, signal: failed}} = Chat.execute(client, request)
      assert failed.data["request_id"] == "card-request"
      assert failed.extensions["causationid"] == request.id
      assert failed.extensions["traceparent"] == F.trace()
      F.round_trip(client, failed)
      F.empty()
    end
  end

  @tag obligation: "jido_chat_slack.actions.I4"
  test "core and Slack Actions compose in a Flow and a failed dependency prevents the card write" do
    client = F.client()
    message = F.request(F.row("send_message"), client)
    card = card(client)
    F.plan(F.row("send_message")["plan"] ++ card_plan())

    assert {:ok, %{message: first, card: second}} =
             Jido.Exec.run(F.Flow, %{message: message, card: card}, %{client: client}, max_attempts: 1)

    F.checked(client, message, first)
    F.checked(client, card, second)
    assert_receive {:wire, "chat.postMessage", _}
    assert_receive {:wire, "chat.postMessage", _}
    F.empty()
    F.plan([%{"method" => "chat.postMessage", "body" => %{"ok" => false, "error" => "missing_scope"}}])
    assert {:error, _} = Jido.Exec.run(F.Flow, %{message: message, card: card}, %{client: client}, max_attempts: 1)
    assert_receive {:wire, "chat.postMessage", _}
    refute_receive {:wire, _, _}
    F.empty()
  end

  @tag obligation: "jido_chat_slack.actions.I3"
  test "a lookup failure after upload completion has an unknown write outcome" do
    client = F.client()
    row = F.row("send_file")

    plan =
      List.replace_at(row["plan"], -1, %{
        "method" => "files.info",
        "form" => %{"file" => "F1"},
        "body" => %{"ok" => false, "error" => "missing_scope"}
      })

    F.plan(plan)
    request = F.request(row, client)
    assert {:error, %{code: :provider_failure, signal: failed}} = Chat.execute(client, request)
    assert failed.data["outcome"] == "unknown"
    assert failed.extensions["causationid"] == request.id
    F.round_trip(client, failed)
    F.empty()
  end
end
