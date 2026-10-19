defmodule Jido.Chat.Slack.PublicApiTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias Jido.Chat
  alias Jido.Chat.Slack.{Adapter, Operations}
  alias Jido.Chat.Slack.AdapterSurfaceTest.MockTransport

  defmodule PlainEphemeralRequest do
    import ExUnit.Assertions

    def request(options) do
      assert options[:form]["mrkdwn"] == "false"
      {:ok, %Req.Response{status: 200, body: %{"ok" => true, "message_ts" => "1"}}}
    end
  end

  defp client(options \\ []) do
    Chat.Client.new!(Adapter, id: "test", credentials: %{token: "fixture"}, transport: MockTransport, config: options)
  end

  defp run(client, definition, data, options \\ []) do
    request = definition.new!(Map.merge(%{"client_id" => client.id, "request_id" => "req"}, data))
    Chat.execute(client, request, options: options)
  end

  test "all supported Chat operations return catalog validated Signals" do
    client =
      client(
        options_loader: fn _ -> %{options: [%{label: "A", value: "a"}]} end,
        trigger_id: "trigger"
      )

    room = %{"room_id" => "C123"}
    message = Map.put(room, "message_id", "1")

    requests = [
      {Chat.Signal.SendMessage, Map.put(room, "text", "hi")},
      {Chat.Signal.SendFile,
       Map.merge(room, %{"source" => %{"content_base64" => Base.encode64("abc"), "filename" => "a.txt"}})},
      {Chat.Signal.EditMessage, Map.put(message, "text", "edit")},
      {Chat.Signal.DeleteMessage, message},
      {Chat.Signal.FetchMetadata, room},
      {Chat.Signal.FetchThread, Map.put(room, "thread_id", "1")},
      {Chat.Signal.FetchMessage, message},
      {Chat.Signal.GetUser, %{"user_id" => "U1"}},
      {Chat.Signal.FetchSubject, room},
      {Chat.Signal.GetThreadParticipants, Map.put(room, "thread_id", "1")},
      {Chat.Signal.MarkAsRead, message},
      {Chat.Signal.DownloadFile,
       %{"resource_ref" => %{"id" => "https://files.slack.com/a", "client_id" => client.id, "kind" => "file"}}},
      {Chat.Signal.AddReaction, Map.put(message, "reaction", "wave")},
      {Chat.Signal.RemoveReaction, Map.put(message, "reaction", "wave")},
      {Chat.Signal.OpenDm, %{"user_id" => "U1"}},
      {Chat.Signal.PostEphemeral, Map.merge(room, %{"user_id" => "U1", "text" => "secret"})},
      {Chat.Signal.FetchMessages, Map.put(room, "direction", "backward")},
      {Chat.Signal.ListThreads, room},
      {Chat.Signal.OpenModal, Map.put(room, "modal", %{"title" => "Test", "callback_id" => "test", "elements" => []})},
      {Chat.Signal.LoadOptions, %{"interaction_id" => "I1", "query" => "a"}}
    ]

    tested =
      MapSet.new(requests, fn {definition, _} ->
        {_, operation, _, _, _} = Chat.Operations.Definitions.lookup(definition.type())
        operation
      end)

    declared =
      Adapter.capabilities() |> Enum.filter(fn {_, support} -> support == :native end) |> MapSet.new(&elem(&1, 0))

    assert tested == declared

    for {definition, data} <- requests do
      assert {:ok, signal} = run(client, definition, data), inspect(definition)
      assert signal.type == definition.type() <> ".completed"
      assert {:ok, _} = Jido.Signal.Catalog.validate(Chat.catalog(client), signal)
    end
  end

  test "the three unsupported operations fail without a provider request" do
    for {definition, data} <- [
          {Chat.Signal.StreamText, %{"room_id" => "C"}},
          {Chat.Signal.StartTyping, %{"room_id" => "C"}},
          {Chat.Signal.CreateThread, %{"room_id" => "C", "name" => "Topic"}}
        ] do
      assert {:error, %{code: :unsupported, signal: failed}} = run(client(), definition, data)
      assert failed.data["outcome"] == "not_attempted"
      refute_receive {:send_message, _, _, _}
    end
  end

  test "ephemeral plain text disables markup and file controls fail explicitly" do
    client = Chat.Client.new!(Adapter, id: "format", credentials: %{token: "fixture"})

    assert {:ok, _} =
             run(
               client,
               Chat.Signal.PostEphemeral,
               %{"room_id" => "C", "user_id" => "U", "text" => "*literal*", "format" => "plain"},
               req: PlainEphemeralRequest
             )

    for extra <- [%{"format" => "html"}, %{"format" => "plain"}, %{"keyboard" => %{"rows" => []}}] do
      data = Map.merge(%{"room_id" => "C", "source" => %{"content_base64" => "YQ==", "filename" => "a.txt"}}, extra)
      assert {:error, %{code: :unsupported}} = run(client, Chat.Signal.SendFile, data)
    end
  end

  test "Slack cards use native Actions and can be routed from the Client catalog" do
    client = client()
    assert Chat.Slack.actions() == [Chat.Slack.SendCard]
    assert Chat.Slack.signal_definitions() == Chat.Slack.SendCard.signal_definitions()

    assert {:ok, completed} =
             run(client, Chat.Slack.Signal.SendCard, %{
               "room_id" => "C1",
               "thread_id" => "1",
               "card" => %{"title" => "Test", "components" => []}
             })

    assert completed.data["result"]["thread_id"] == "1"

    assert {:error, {:not_attempted, :missing_token}} =
             Operations.send_card(%{client | credentials: %{}}, %{data: %{}}, [])
  end

  test "unsupported content and foreign resources fail before transport calls" do
    client = client()

    for definition <- [Chat.Signal.SendMessage, Chat.Signal.EditMessage, Chat.Signal.PostEphemeral] do
      data = %{"room_id" => "C1", "text" => "hi", "format" => "html"}
      data = if definition == Chat.Signal.EditMessage, do: Map.put(data, "message_id", "1"), else: data
      data = if definition == Chat.Signal.PostEphemeral, do: Map.put(data, "user_id", "U1"), else: data
      assert {:error, %{code: :unsupported}} = run(client, definition, data)
    end

    assert {:ok, result} =
             run(client, Chat.Signal.SendMessage, %{
               "room_id" => "C1",
               "text" => "Choose",
               "format" => "plain",
               "keyboard" => %{
                 "rows" => [
                   [%{"text" => "Yes", "value" => "yes"}, %{"text" => "Link", "url" => "https://example.test"}]
                 ]
               }
             })

    assert result.data["result"]["text"] == "Choose"
    foreign = %{"id" => "ref", "client_id" => "other", "kind" => "file"}

    for {definition, data} <- [
          {Chat.Signal.DownloadFile, %{"resource_ref" => foreign}},
          {Chat.Signal.SendFile, %{"room_id" => "C1", "source" => foreign}}
        ] do
      assert {:error, _} = run(client, definition, data)
    end

    source = %{foreign | "client_id" => client.id}
    assert {:error, %{signal: signal}} = run(client, Chat.Signal.SendFile, %{"room_id" => "C1", "source" => source})
    assert signal.data["outcome"] == "not_attempted"

    assert {:ok, _} =
             run(client, Chat.Signal.SendFile, %{"room_id" => "C1", "source" => source},
               file_resolver: fn ^source -> {:ok, %{data: "bytes", filename: "test.txt"}} end
             )

    assert {:error, %{code: :provider_failure}} =
             run(client, Chat.Signal.FetchMessages, %{"room_id" => "C1", "direction" => "forward"})

    assert {:error, {:not_attempted, :missing_token}} = Adapter.invoke(%{client | credentials: %{}}, %{data: %{}}, [])
    assert {:error, {:not_attempted, :unsupported}} = Adapter.invoke(client, %{type: "other", data: %{}}, [])
  end
end
