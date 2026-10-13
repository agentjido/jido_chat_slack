defmodule Jido.Chat.Slack.OperationMatrixTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.AdapterTestKit.Factories
  alias Jido.Chat.Slack.Adapter

  @operations ~w(send_message send_file post_message edit_message delete_message start_typing fetch_metadata fetch_thread fetch_message get_user fetch_subject get_thread_participants mark_as_read fetch_media add_reaction remove_reaction post_ephemeral post_channel_message stream open_modal load_options fetch_messages fetch_channel_messages list_threads open_thread open_dm)a
  @methods %{
    send_message: [:send_message],
    send_file: [:send_file],
    post_message: [:send_message],
    edit_message: [:edit_message],
    delete_message: [:delete_message],
    fetch_metadata: [:fetch_metadata],
    fetch_thread: [:fetch_metadata, :fetch_message],
    fetch_message: [:fetch_message],
    get_user: [:get_user],
    fetch_subject: [:fetch_metadata, :fetch_message, :get_permalink],
    get_thread_participants: [:fetch_messages, :get_user],
    mark_as_read: [:mark_as_read],
    fetch_media: [:download_file],
    add_reaction: [:add_reaction],
    remove_reaction: [:remove_reaction],
    post_ephemeral: [:post_ephemeral],
    post_channel_message: [:send_message],
    stream: [:send_message, :edit_message, :edit_message],
    open_modal: [:open_modal],
    load_options: [:load_options],
    fetch_messages: [:fetch_messages],
    fetch_channel_messages: [:fetch_messages],
    list_threads: [:list_threads],
    open_thread: [],
    open_dm: [:open_dm]
  }

  defmodule Transport do
    @behaviour Jido.Chat.Slack.Transport
    @calls [
      send_message: 3,
      send_file: 3,
      edit_message: 4,
      delete_message: 3,
      fetch_metadata: 2,
      fetch_thread: 2,
      fetch_message: 3,
      get_user: 2,
      get_permalink: 3,
      mark_as_read: 3,
      download_file: 2,
      fetch_messages: 2,
      fetch_channel_messages: 2,
      list_threads: 2,
      add_reaction: 4,
      remove_reaction: 4,
      post_ephemeral: 4,
      open_dm: 2,
      open_modal: 3
    ]
    for {method, arity} <- @calls do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(method)(unquote_splicing(args)) do
        args = [unquote_splicing(args)]
        send(self(), {:provider, unquote(method), args})
        if Process.get(:matrix_failure), do: {:error, :timeout}, else: response(unquote(method), args)
      end
    end

    defp response(:get_user, [user, _]),
      do: {:ok, %{"id" => user, "name" => "user", "profile" => %{"display_name" => "Name"}}}

    defp response(:fetch_metadata, [room, _]), do: {:ok, %{"id" => room, "name" => "Room", "is_im" => false}}
    defp response(:get_permalink, _), do: {:ok, "https://example.test/message"}
    defp response(:download_file, _), do: {:ok, "private-bytes"}
    defp response(:open_dm, _), do: {:ok, "DU1"}
    defp response(:open_modal, _), do: {:ok, %{"view" => %{"id" => "V1"}}}
    defp response(:post_ephemeral, _), do: {:ok, %{"message_ts" => "1.03"}}

    defp response(:send_file, [room, upload, _]),
      do:
        {:ok,
         %{
           "files" => [
             %{"id" => "F1", "name" => upload.filename, "shares" => %{"public" => %{room => [%{"ts" => "1.01"}]}}}
           ]
         }}

    defp response(:fetch_message, [room, id, _]),
      do: {:ok, %{"channel" => room, "ts" => id, "text" => "root", "user" => "U1", "thread_ts" => "1.01"}}

    defp response(method, [room, _]) when method in [:fetch_messages, :fetch_channel_messages, :fetch_thread],
      do:
        {:ok,
         %{"messages" => [%{"channel" => room, "ts" => "1.01", "text" => "hello", "user" => "U1"}], "has_more" => false}}

    defp response(:list_threads, [room, _]),
      do: {:ok, %{"threads" => [%{"channel" => room, "ts" => "1.01", "text" => "root"}], "has_more" => false}}

    defp response(:send_message, [room, _, _]), do: {:ok, %{"channel" => room, "ts" => "1.01"}}
    defp response(:edit_message, [room, id, _, _]), do: {:ok, %{"channel" => room, "ts" => id}}
    defp response(_, _), do: {:ok, true}
  end

  defmodule MalformedPages do
    def list_threads(_room, _opts),
      do: {:ok, %{"threads" => [%{"ts" => "1.01"}, "invalid", %{"ts" => "1.02"}], "has_more" => false}}

    def fetch_messages(_room, _opts),
      do: {:ok, %{"messages" => [%{"ts" => "1.01"}, "invalid", %{"ts" => "1.02"}], "has_more" => false}}
  end

  setup do
    caller = self()

    loader = fn _ ->
      send(caller, {:provider, :load_options, []})
      {:ok, %{options: [%{label: "One", value: "1"}], option_groups: []}}
    end

    {:ok, binding} =
      Jido.Chat.bind(Adapter,
        id: "matrix",
        token: "fixture-token",
        transport: Transport,
        trigger_id: "private-trigger",
        options_loader: loader,
        update_every: 1
      )

    %{binding: binding}
  end

  defp request(binding, operation) do
    overrides = %{"request_id" => "matrix:" <> Atom.to_string(operation)}

    fields =
      Jido.Chat.Operations.Definitions.all()
      |> Enum.find(fn {_, {_, op, _, _, _}} -> op == operation end)
      |> elem(1)
      |> elem(2)

    overrides = if "room_id" in fields, do: Map.put(overrides, "room_id", "C1"), else: overrides

    overrides =
      if operation == :fetch_media do
        {:ok, ref} = Jido.Chat.put_resource(binding, "media", %{url: "https://example.test/private-file"})
        Map.put(overrides, "media_ref", ref)
      else
        overrides
      end

    overrides =
      if operation in [:fetch_thread, :fetch_subject, :get_thread_participants],
        do: Map.put(overrides, "thread_id", "1.01"),
        else: overrides

    Factories.operation_request(binding, operation, overrides)
  end

  defp calls(acc \\ []) do
    receive do
      {:provider, method, _args} -> calls([method | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "the finite operation inventory is complete" do
    actual = Enum.map(Jido.Chat.Operations.Definitions.all(), fn {_, {_, operation, _, _, _}} -> operation end)
    assert MapSet.new(actual) == MapSet.new(@operations)
    assert length(actual) == 26
  end

  for operation <- @operations do
    methods = Map.get(@methods, operation, [])

    test "#{operation} matches its declared native/fallback/unsupported result and exact calls", %{binding: binding} do
      operation = unquote(operation)
      status = Jido.Chat.Adapter.capabilities(Adapter)[operation]
      parent = request(binding, operation)
      assert {:ok, result} = Jido.Chat.execute(binding, parent)

      if status == :unsupported do
        assert result.type == "jido.chat.operation.failed"
        assert result.data["code"] == "unsupported"
      else
        assert result.type == "jido.chat.operation.completed"
      end

      assert calls() == unquote(methods)
      assert calls() == []
      assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
      assert calls() == []
      assert Jido.Signal.Context.get(result, "causationid") == parent.id
      assert Jido.Signal.Trace.get(result).trace_id == Jido.Signal.Trace.get(parent).trace_id
      catalog = Jido.Signal.Catalog.new!(Jido.Chat.signal_definitions())
      assert {:ok, json} = Jido.Signal.Serialization.serialize(result)
      assert {:ok, ^result} = Jido.Signal.Catalog.decode(catalog, json)
      refute json =~ "fixture-token"
      refute json =~ "private-bytes"
    end
  end

  test "provider failure is typed and cached without repeat calls", %{binding: binding} do
    Process.put(:matrix_failure, true)
    parent = request(binding, :send_message)
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.data["code"] == "provider_failure"
    assert result.data["retryable"]
    assert calls() == [:send_message]
    assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
    assert calls() == []
  end

  test "channel and thread subjects have different native kinds", %{binding: binding} do
    for {thread, kind, methods} <- [
          {nil, "conversation", [:fetch_metadata]},
          {"1.01", "thread", [:fetch_metadata, :fetch_message, :get_permalink]}
        ] do
      data = %{"request_id" => "subject:" <> kind, "room_id" => "C1"}
      data = if thread, do: Map.put(data, "thread_id", thread), else: data
      parent = Jido.Chat.Signal.FetchSubject.new!(data)
      assert {:ok, result} = Jido.Chat.execute(binding, parent)
      assert result.type == "jido.chat.operation.completed"
      assert result.data["result"]["kind"] == kind
      assert result.data["result"]["id"] == (thread || "C1")
      assert calls() == methods
    end
  end

  test "malformed page items fail the whole query without dropping an item" do
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "malformed-pages", token: "fixture-token", transport: MalformedPages)

    for operation <- [:fetch_messages, :fetch_channel_messages, :list_threads] do
      parent = request(binding, operation)
      assert {:ok, failed} = Jido.Chat.execute(binding, parent)
      assert failed.type == "jido.chat.operation.failed"
      assert failed.data["code"] == "invalid_provider_result"
      assert {:ok, ^failed} = Jido.Chat.execute(binding, parent)
    end
  end

  test "a stream stays lazy before execution and is consumed once", %{binding: binding} do
    stream =
      Stream.map(["hello", " world"], fn chunk ->
        send(self(), {:stream_chunk, chunk})
        chunk
      end)

    {:ok, ref} = Jido.Chat.put_resource(binding, "stream", stream)
    parent = Jido.Chat.Signal.Stream.new!(%{"request_id" => "lazy", "room_id" => "C1", "resource_ref" => ref})
    refute_received {:stream_chunk, _}
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.type == "jido.chat.operation.completed"
    assert_receive {:stream_chunk, "hello"}
    assert_receive {:stream_chunk, " world"}
    assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
    refute_received {:stream_chunk, _}
  end

  test "a cancelled stream is never enumerated and invokes no provider", %{binding: binding} do
    stream =
      Stream.map(["private"], fn chunk ->
        send(self(), :stream_enumerated)
        chunk
      end)

    {:ok, ref} = Jido.Chat.put_resource(binding, "stream", stream)
    :ok = Jido.Chat.cancel_resource(binding, ref)
    parent = Jido.Chat.Signal.Stream.new!(%{"request_id" => "cancelled", "room_id" => "C1", "resource_ref" => ref})
    assert {:ok, failed} = Jido.Chat.execute(binding, parent)
    assert failed.data["code"] == "resource_cancelled"
    refute_received :stream_enumerated
    assert calls() == []
  end
end
