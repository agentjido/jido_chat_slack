Code.require_file("support/fixtures_helper.exs", __DIR__)

defmodule Jido.Chat.Slack.AdapterContractTest do
  use Covenant.Case, component: "jido_chat_slack.adapter", async: false
  @moduletag capture_log: true
  alias Jido.Chat
  alias Jido.Chat.Slack.ContractFixtures, as: F

  setup do
    observer = self()
    start_supervised!(F.wire_child(observer))
    :ok
  end

  @tag obligation: "jido_chat_slack.adapter.I1"
  test "public exports, capability statuses and catalogs are explicit and have no I/O" do
    client = F.client()

    for {name, exports} <- F.boundary()["exports"] do
      module = F.module(name)
      actual = module.__info__(:functions) |> Enum.map(fn {n, a} -> [to_string(n), a] end) |> Enum.sort()
      assert actual == Enum.sort(exports)
    end

    assert Chat.capabilities(client) |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end) ==
             F.boundary()["capabilities"]

    assert length(Chat.operations()) == 23
    assert Chat.operations(client) == Chat.operations() ++ [{Chat.Slack.Signal.SendCard, Chat.Slack.SendCard}]
    assert Chat.Slack.actions() == [Chat.Slack.SendCard]
    assert Chat.Slack.signal_definitions() == Chat.Slack.SendCard.signal_definitions()
    assert Chat.actions(client) == Enum.map(Chat.operations(client), &elem(&1, 1))
    assert Enum.sort(Enum.map(Chat.event_definitions(client), &inspect/1)) == Enum.sort(F.boundary()["events"])
    assert Chat.catalog(client)
    assert Chat.Slack.adapter() == Chat.Slack.Adapter
    assert Chat.Slack.Adapter.channel_type() == :slack
    assert Application.spec(:jido_chat_slack, :mod) == []
    assert Application.spec(:jido_chat_slack, :registered) == []
    refute :jido_messaging in Application.spec(:jido_chat_slack, :applications)
    F.empty()
    refute_receive {:wire, _, _}
  end

  @tag obligation: "jido_chat_slack.adapter.I2"
  test "every native operation uses the fixed wire sequence and exact canonical result for two clients" do
    assert length(F.rows()) == 20

    expected =
      F.boundary()["capabilities"]
      |> Enum.filter(fn {_, v} -> v == "native" end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    assert Enum.sort(Enum.map(F.rows(), & &1["operation"])) == expected

    for id <- ["alpha", "beta"], row <- F.rows() do
      client = F.client(id)
      F.plan(row["plan"])
      request = F.request(row, client)
      assert {:ok, completed} = Chat.execute(client, request), row["operation"]
      F.checked(client, request, completed)
      F.subset(completed.data["result"], row["result"])

      for entry <- row["plan"] do
        method = entry["method"]
        assert_receive {:wire, ^method, opts}

        if String.starts_with?(method, "https://files.slack.com/upload/") do
          refute Enum.any?(opts[:headers], fn {k, _} -> k == "authorization" end)
        else
          assert {"authorization", "Bearer fixture-token:" <> id} in opts[:headers]
        end
      end

      F.empty()
    end
  end

  @tag obligation: "jido_chat_slack.adapter.I3"
  test "all facade helpers execute their shared Actions and unsupported helpers make no I/O" do
    client = F.client()

    helpers = [
      {"send_message",
       fn -> Chat.send_text(client, "C1", "Hello", thread_id: "1700000000.000001", request_id: "facade") end},
      {"send_message",
       fn ->
         Chat.send_message(client, %{
           "request_id" => "facade",
           "room_id" => "C1",
           "text" => "Hello",
           "thread_id" => "1700000000.000001"
         })
       end},
      {"send_file",
       fn -> Chat.send_file(client, "C1", %{"content_base64" => "Ynl0ZXM=", "filename" => "bytes.txt"}) end},
      {"edit_message", fn -> Chat.edit_message(client, "C1", "1700000000.000001", "Edited") end},
      {"delete_message", fn -> Chat.delete_message(client, "C1", "1700000000.000001") end},
      {"download_file",
       fn ->
         Chat.download_file(client, %{
           "client_id" => "alpha",
           "kind" => "file",
           "id" => "https://files.slack.com/files-pri/T1-F1/bytes.txt"
         })
       end},
      {"add_reaction", fn -> Chat.add_reaction(client, "C1", "1700000000.000001", "wave") end},
      {"remove_reaction", fn -> Chat.remove_reaction(client, "C1", "1700000000.000001", "wave") end},
      {"fetch_metadata", fn -> Chat.fetch_metadata(client, "C1") end}
    ]

    for {operation, call} <- helpers do
      F.plan(F.row(operation)["plan"])
      assert {:ok, completed} = call.()
      F.subset(completed.data["result"], F.row(operation)["result"])
      F.round_trip(client, completed)
      F.empty()
    end

    # Flush the recorded successful calls before proving that unsupported calls have none.
    drain()

    for call <- [
          fn -> Chat.stream_text(client, "C1", Stream.map(["x"], fn _ -> flunk("unsupported stream was read") end)) end,
          fn -> Chat.start_typing(client, "C1") end,
          fn -> Chat.create_thread(client, "C1", "Topic") end
        ] do
      assert {:error, %{code: :unsupported, signal: failed}} = call.()
      assert failed.data["outcome"] == "not_attempted"
      F.round_trip(client, failed)
    end

    assert Chat.emoji(":smile:") == ":smile:"
    refute_receive {:wire, _, _}
    F.empty()
  end

  defp drain do
    receive do
      {:wire, _, _} -> drain()
    after
      0 -> :ok
    end
  end

  @tag obligation: "jido_chat_slack.adapter.I4"
  test "unsupported formats, foreign resources and invalid facade options fail before I/O" do
    client = F.client()

    for result <- [
          Chat.send_text(client, "C1", "Hello", format: :html),
          Chat.send_text(client, "C1", "Hello", token: "do-not-use"),
          Chat.download_file(client, %{"client_id" => "beta", "kind" => "file", "id" => "https://files.slack.com/f"}),
          Chat.send_file(client, "C1", %{"content_base64" => "YQ==", "filename" => "a"}, keyboard: %{"rows" => []}),
          Chat.send_file(client, "C1", %{"content_base64" => "YQ==", "filename" => "a"}, format: :plain)
        ],
        do: assert(match?({:error, _}, result))

    refute_receive {:wire, _, _}
    F.empty()
  end
end
