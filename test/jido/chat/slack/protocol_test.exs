defmodule Jido.Chat.Slack.ProtocolTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.Slack.{Adapter, Normalizer}

  defmodule Transport do
    def send_message(room, text, opts) do
      send(self(), {:provider, :send_message, room, text, opts})
      {:ok, %{"ts" => "1.01", "channel" => room, "token" => opts[:token]}}
    end

    def fetch_metadata(room, opts) do
      send(self(), {:provider, :metadata, room, opts})
      {:ok, %{"id" => room, "name" => "Room", "is_im" => false}}
    end

    def fetch_message(room, id, opts) do
      send(self(), {:provider, :message, room, id, opts})
      {:ok, %{"ts" => id, "user" => "U1", "text" => "root", "thread_ts" => id}}
    end

    def fetch_messages(room, opts) do
      send(self(), {:provider, :page, room, opts})

      {:ok,
       %{
         "messages" => [
           %{"ts" => "1.01", "text" => "first", "user" => "U1"},
           %{"ts" => "1.02", "text" => "second", "user" => "U2"}
         ],
         "has_more" => true,
         "response_metadata" => %{"next_cursor" => "next-page"}
       }}
    end

    def get_user(id, opts) do
      send(self(), {:provider, :user, id, opts})
      {:ok, %{"id" => id, "name" => "user", "profile" => %{"display_name" => "Name"}}}
    end

    def list_threads(room, opts) do
      send(self(), {:provider, :threads, room, opts})

      {:ok,
       %{
         "threads" => [%{"ts" => "1.01", "text" => "first"}, %{"ts" => "1.02", "text" => "second"}],
         "has_more" => true,
         "response_metadata" => %{"next_cursor" => "next-thread"}
       }}
    end

    def post_ephemeral(room, user, text, opts) do
      send(self(), {:provider, :ephemeral, room, user, text, opts})
      {:ok, %{"message_ts" => "1.03"}}
    end

    def open_modal(trigger, payload, opts) do
      send(self(), {:provider, :modal, trigger, payload, opts})
      {:ok, %{"view" => %{"id" => "V1"}}}
    end
  end

  setup do
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "protocol", token: "captured-token", transport: Transport)
    %{binding: binding}
  end

  defp execute(binding, definition, data) do
    parent = definition.new!(Map.put(data, "request_id", Atom.to_string(definition)))
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.type == "jido.chat.operation.completed"
    assert Jido.Signal.Context.get(result, "causationid") == parent.id
    assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
    catalog = Jido.Signal.Catalog.new!(Jido.Chat.signal_definitions())
    assert {:ok, json} = Jido.Signal.Serialization.serialize(result)
    assert {:ok, ^result} = Jido.Signal.Catalog.decode(catalog, json)
    refute json =~ "captured-token"
    result
  end

  test "native send selects portable data and retains one cached provider call", %{binding: binding} do
    result = execute(binding, Jido.Chat.Signal.SendMessage, %{"room_id" => "C1", "text" => "hello"})
    assert result.data["result"]["id"] == "1.01"
    assert_receive {:provider, :send_message, "C1", "hello", opts}
    assert opts[:token] == "captured-token"
    refute_received {:provider, _, _, _, _}
  end

  test "history and thread pages retain every item and cursor", %{binding: binding} do
    for definition <- [Jido.Chat.Signal.FetchMessages, Jido.Chat.Signal.FetchChannelMessages] do
      result = execute(binding, definition, %{"room_id" => "C1", "cursor" => "prior", "limit" => 2})
      assert Enum.map(result.data["result"]["messages"], & &1["id"]) == ["1.01", "1.02"]
      assert result.data["result"]["next_cursor"] == "next-page"
      assert result.data["result"]["complete"] == false
      assert_receive {:provider, :page, "C1", opts}
      assert opts[:cursor] == "prior"
      assert opts[:limit] == 2
    end

    result = execute(binding, Jido.Chat.Signal.ListThreads, %{"room_id" => "C1", "limit" => 2})
    assert Enum.map(result.data["result"]["threads"], & &1["id"]) == ["1.01", "1.02"]
    assert result.data["result"]["next_cursor"] == "next-thread"
  end

  test "native user and thread queries use selected domain fields", %{binding: binding} do
    user = execute(binding, Jido.Chat.Signal.GetUser, %{"user_id" => "U1"})
    assert user.data["result"]["id"] == "U1"
    assert user.data["result"]["display_name"] == "Name"
    thread = execute(binding, Jido.Chat.Signal.FetchThread, %{"room_id" => "C1", "thread_id" => "1.01"})
    assert thread.data["result"]["id"] == "1.01"
    assert thread.data["result"]["room_id"] == "C1"
  end

  test "ephemeral operation retains native conversation and message IDs", %{binding: binding} do
    result =
      execute(binding, Jido.Chat.Signal.PostEphemeral, %{"room_id" => "C1", "user_id" => "U1", "text" => "private"})

    assert result.data["result"]["id"] == "1.03"
    assert_receive {:provider, :ephemeral, "C1", "U1", "private", _}
  end

  test "private interaction controls open a modal and retain its later conversation scope", %{binding: binding} do
    payload = %{
      "type" => "block_actions",
      "channel" => %{"id" => "C1"},
      "trigger_id" => "private-trigger",
      "actions" => [%{"action_id" => "open"}]
    }

    assert {:ok, %{signals: [action]}} = Jido.Chat.normalize_event(binding, payload)

    assert {:ok, modal} =
             Adapter.prepare_modal(binding, action.data["interaction_id"], Jido.Chat.Modal.new(%{title: "Modal"}))

    result = execute(binding, Jido.Chat.Signal.OpenModal, %{"room_id" => "C1", "modal" => modal})
    assert result.data["result"]["opened"]
    assert_receive {:provider, :modal, "private-trigger", _, _}

    assert {:ok, %{signals: [submitted]}} =
             Jido.Chat.normalize_event(binding, %{
               "type" => "view_submission",
               "view" => %{"id" => "V1", "state" => %{"values" => %{}}}
             })

    assert submitted.type == "jido.chat.modal.submitted"
    assert submitted.data["room_id"] == "C1"
    assert {:ok, _} = Normalizer.interaction(binding, submitted.data["interaction_id"])
  end

  test "options loader receives a native request and returns portable options" do
    loader = fn %Jido.Signal{} = request ->
      send(self(), {:native_loader, request.type})
      {:ok, %{options: [%{label: "One", value: "1"}], option_groups: []}}
    end

    {:ok, binding} =
      Jido.Chat.bind(Adapter, id: "loader", token: "captured-token", transport: Transport, options_loader: loader)

    result =
      execute(binding, Jido.Chat.Signal.LoadOptions, %{"interaction_id" => "opaque", "query" => "o", "limit" => 2})

    assert result.data["result"]["options"] == [%{"label" => "One", "value" => "1"}]
  end
end
