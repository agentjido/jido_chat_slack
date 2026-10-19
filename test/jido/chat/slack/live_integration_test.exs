defmodule Jido.Chat.Slack.LiveIntegrationTest do
  use ExUnit.Case, async: false
  alias Jido.Chat
  alias Jido.Chat.Slack.Adapter
  alias Jido.Chat.Slack.LiveHelpers, as: Live
  @moduletag :live
  @moduletag capture_log: true
  @moduletag timeout: 90_000
  @enabled System.get_env("RUN_LIVE_SLACK_TESTS") in ["1", "true"]
  if not @enabled, do: @moduletag(skip: "set RUN_LIVE_SLACK_TESTS=true")

  setup_all do
    token = System.fetch_env!("SLACK_BOT_TOKEN")
    channel = System.fetch_env!("SLACK_TEST_CHANNEL_ID")
    {:ok, %{body: body} = auth} = Req.post("https://slack.com/api/auth.test", auth: {:bearer, token})
    assert body["ok"] == true
    expected_workspace = System.get_env("SLACK_TEST_WORKSPACE", "epicfirm")
    assert URI.parse(body["url"]).host == expected_workspace <> ".slack.com"

    client =
      Chat.Client.new!(Adapter,
        id: "slack/live",
        credentials: %{
          token: token,
          app_token: System.fetch_env!("SLACK_APP_TOKEN")
        },
        config: [bot_user_id: body["user_id"]]
      )

    scopes =
      auth
      |> Req.Response.get_header("x-oauth-scopes")
      |> Enum.join(",")
      |> String.split(",", trim: true)

    {:ok, client: client, room: channel, scopes: scopes, bot_user: body["user_id"]}
  end

  defp request(client, definition, data), do: Live.request(client, definition, data)
  defp execute(client, definition, data), do: Live.execute(client, definition, data)
  defp delete(client, room, id), do: Live.facade(client, :delete_message, [room, id])

  test "public Chat message lifecycle and thread continuity", ctx do
    root = Live.facade(ctx.client, :send_text, [ctx.room, "Jido SDK live test"])
    on_exit(fn -> delete(ctx.client, ctx.room, root["id"]) end)
    fetched = execute(ctx.client, Chat.Signal.FetchMessage, %{"room_id" => ctx.room, "message_id" => root["id"]})
    assert fetched["text"] == "Jido SDK live test"

    edited =
      execute(ctx.client, Chat.Signal.EditMessage, %{
        "room_id" => ctx.room,
        "message_id" => root["id"],
        "text" => "Jido SDK live test edited"
      })

    assert edited["id"] == root["id"]

    assert execute(ctx.client, Chat.Signal.FetchMessage, %{"room_id" => ctx.room, "message_id" => root["id"]})["text"] ==
             "Jido SDK live test edited"

    reply =
      execute(ctx.client, Chat.Signal.SendMessage, %{
        "room_id" => ctx.room,
        "reply_to_id" => root["id"],
        "text" => "Jido SDK thread test"
      })

    on_exit(fn -> delete(ctx.client, ctx.room, reply["id"]) end)
    assert reply["thread_id"] == root["id"]
    page = execute(ctx.client, Chat.Signal.FetchMessages, %{"room_id" => ctx.room, "thread_id" => root["id"]})
    assert Enum.any?(page["messages"], &(&1["id"] == reply["id"] and &1["thread_id"] == root["id"]))

    for definition <- [Chat.Signal.AddReaction, Chat.Signal.RemoveReaction] do
      assert execute(ctx.client, definition, %{"room_id" => ctx.room, "message_id" => root["id"], "reaction" => "wave"})[
               "acknowledged"
             ]
    end

    assert Live.facade(ctx.client, :fetch_metadata, [ctx.room])["id"] == ctx.room
    disposable = Live.facade(ctx.client, :send_text, [ctx.room, "Jido delete identity proof"])
    assert Live.facade(ctx.client, :delete_message, [ctx.room, disposable["id"]])["acknowledged"]

    assert {:error, %{code: :not_found}} =
             Chat.execute(
               ctx.client,
               request(ctx.client, Chat.Signal.FetchMessage, %{"room_id" => ctx.room, "message_id" => disposable["id"]})
             )
  end

  test "thread queries and channel history return canonical results", ctx do
    root = execute(ctx.client, Chat.Signal.SendMessage, %{"room_id" => ctx.room, "text" => "Jido query proof"})
    on_exit(fn -> delete(ctx.client, ctx.room, root["id"]) end)

    reply =
      execute(ctx.client, Chat.Signal.SendMessage, %{
        "room_id" => ctx.room,
        "thread_id" => root["id"],
        "text" => "Jido query reply"
      })

    on_exit(fn -> delete(ctx.client, ctx.room, reply["id"]) end)
    thread_data = %{"room_id" => ctx.room, "thread_id" => root["id"]}
    assert execute(ctx.client, Chat.Signal.FetchThread, thread_data)["id"] == root["id"]
    assert execute(ctx.client, Chat.Signal.FetchSubject, thread_data)["kind"] == "thread"
    assert execute(ctx.client, Chat.Signal.FetchSubject, %{"room_id" => ctx.room})["id"] == ctx.room
    newer = Live.facade(ctx.client, :send_text, [ctx.room, "Jido cursor identity proof"])
    on_exit(fn -> delete(ctx.client, ctx.room, newer["id"]) end)
    page = execute(ctx.client, Chat.Signal.FetchMessages, %{"room_id" => ctx.room, "limit" => 1})
    assert [first] = page["messages"]
    assert first["id"] == newer["id"]
    assert is_binary(page["next_cursor"]) and page["next_cursor"] != ""

    next =
      execute(ctx.client, Chat.Signal.FetchMessages, %{
        "room_id" => ctx.room,
        "limit" => 1,
        "cursor" => page["next_cursor"]
      })

    assert [second] = next["messages"]
    assert second["id"] == root["id"]

    threads = execute(ctx.client, Chat.Signal.ListThreads, %{"room_id" => ctx.room})
    assert Enum.any?(threads["threads"], &(&1["id"] == root["id"]))
    # A reply does not appear in channel history. It must never return a different message.
    assert {:error, %{code: :not_found}} =
             Chat.execute(
               ctx.client,
               request(ctx.client, Chat.Signal.FetchMessage, %{
                 "room_id" => ctx.room,
                 "message_id" => reply["id"]
               })
             )
  end

  test "user lookup and read cursor enforce installed permissions", ctx do
    user_data = %{"user_id" => ctx.bot_user}

    if "users:read" in ctx.scopes do
      assert execute(ctx.client, Chat.Signal.GetUser, user_data)["id"] == ctx.bot_user
    else
      assert {:error, %{code: :forbidden}} =
               Chat.execute(ctx.client, request(ctx.client, Chat.Signal.GetUser, user_data))
    end

    root = execute(ctx.client, Chat.Signal.SendMessage, %{"room_id" => ctx.room, "text" => "Jido read cursor proof"})
    on_exit(fn -> delete(ctx.client, ctx.room, root["id"]) end)
    data = %{"room_id" => ctx.room, "message_id" => root["id"]}

    if Enum.any?(["channels:manage", "channels:write"], &(&1 in ctx.scopes)) do
      assert execute(ctx.client, Chat.Signal.MarkAsRead, data)["acknowledged"]
    else
      assert {:error, %{code: :forbidden}} =
               Chat.execute(ctx.client, request(ctx.client, Chat.Signal.MarkAsRead, data))
    end

    participants = %{"room_id" => ctx.room, "thread_id" => root["id"]}

    if "users:read" in ctx.scopes do
      observed = execute(ctx.client, Chat.Signal.GetThreadParticipants, participants)
      assert observed["scope"] == "observed"
      refute observed["complete"]
      assert Enum.any?(observed["participants"], &(&1["id"] == ctx.bot_user))
    else
      assert {:error, %{code: :forbidden}} =
               Chat.execute(
                 ctx.client,
                 request(ctx.client, Chat.Signal.GetThreadParticipants, participants)
               )
    end
  end

  @tag skip: System.get_env("SLACK_TEST_USER_ID") in [nil, ""]
  test "DM opening and ephemeral delivery use the configured test user", ctx do
    user = System.fetch_env!("SLACK_TEST_USER_ID")
    dm = execute(ctx.client, Chat.Signal.OpenDm, %{"user_id" => user})
    assert dm["kind"] == "direct"
    assert String.starts_with?(dm["id"], "D")

    ephemeral =
      execute(ctx.client, Chat.Signal.PostEphemeral, %{
        "room_id" => ctx.room,
        "user_id" => user,
        "text" => "Jido ephemeral API proof",
        "format" => "plain"
      })

    assert is_binary(ephemeral["id"])
    # Slack accepts this request but does not guarantee that the user sees the message.
  end

  test "file upload succeeds or reports the installed permission limit", ctx do
    if "files:write" in ctx.scopes do
      filename = "jido-proof-" <> Jido.Signal.ID.generate!() <> ".txt"
      # File deletion is separate from message deletion in Slack.
      on_exit(fn ->
        {:ok, response} =
          Req.post("https://slack.com/api/conversations.history",
            auth: {:bearer, ctx.client.credentials.token},
            form: [channel: ctx.room, limit: 50]
          )

        assert response.body["ok"]

        for message <- response.body["messages"], file <- message["files"] || [], file["name"] == filename do
          {:ok, removed} =
            Req.post("https://slack.com/api/files.delete",
              auth: {:bearer, ctx.client.credentials.token},
              form: [file: file["id"]]
            )

          assert removed.body["ok"]
        end
      end)

      uploaded =
        execute(ctx.client, Chat.Signal.SendFile, %{
          "room_id" => ctx.room,
          "source" => %{"content_base64" => Base.encode64("Jido file proof"), "filename" => filename}
        })

      assert is_binary(uploaded["id"])

      raw =
        Live.api(ctx.client, "conversations.history",
          channel: ctx.room,
          latest: uploaded["id"],
          inclusive: true,
          limit: 1
        )

      [shared] = raw["messages"]
      assert shared["ts"] == uploaded["id"]
      assert Enum.any?(shared["files"], &(&1["name"] == filename))
      event = %{"event_id" => "file-proof", "event" => Map.put(shared, "channel", ctx.room)}
      assert {:ok, delivery} = Chat.normalize(ctx.client, event)
      [received] = delivery.signals
      assert received.data["message_id"] == uploaded["id"]
      [media] = received.data["media"]
      assert media["name"] == filename

      if "files:read" in ctx.scopes do
        downloaded = Live.facade(ctx.client, :download_file, [media["resource_ref"]])
        assert Base.decode64!(downloaded["content_base64"]) == "Jido file proof"
      end
    else
      data = %{
        "room_id" => ctx.room,
        "source" => %{
          "content_base64" => Base.encode64("Jido file proof"),
          "filename" => "jido-proof.txt"
        }
      }

      assert {:error, %{code: :forbidden}} =
               Chat.execute(ctx.client, request(ctx.client, Chat.Signal.SendFile, data))
    end
  end

  @tag skip: System.get_env("SLACK_TEST_FILE_URL") in [nil, ""]
  test "file download returns the expected bytes from a private Slack URL", ctx do
    downloaded =
      execute(ctx.client, Chat.Signal.DownloadFile, %{
        "resource_ref" => %{
          "id" => System.fetch_env!("SLACK_TEST_FILE_URL"),
          "client_id" => ctx.client.id,
          "kind" => "file"
        }
      })

    assert Base.decode64!(downloaded["content_base64"]) == System.fetch_env!("SLACK_TEST_FILE_CONTENT")
  end

  test "public Slack card Action", ctx do
    card =
      execute(ctx.client, Jido.Chat.Slack.Signal.SendCard, %{
        "room_id" => ctx.room,
        "card" => %{"title" => "Jido live card", "components" => []}
      })

    on_exit(fn -> delete(ctx.client, ctx.room, card["id"]) end)
    assert is_binary(card["id"])
  end

  test "Socket Mode input reaches shared Sensor and produces a public Chat reply", ctx do
    sensor =
      start_supervised!(
        {Chat.Sensor,
         client: ctx.client,
         source: Jido.Chat.Slack.Source,
         rooms: [ctx.room],
         emit: "jido.chat.message.received",
         dispatch: {:pid, target: self()}}
      )

    # Wait for the connection to finish before the test message is sent.
    worker = :sys.get_state(sensor).worker
    await_socket(worker, 100)
    marker = "Jido Socket Mode proof " <> Jido.Signal.ID.generate!()
    root = execute(ctx.client, Chat.Signal.SendMessage, %{"room_id" => ctx.room, "text" => marker})
    on_exit(fn -> delete(ctx.client, ctx.room, root["id"]) end)
    incoming = await_text(marker)
    assert incoming.source == ctx.client.source
    assert incoming.data["message_id"] == root["id"]

    reply =
      execute(ctx.client, Chat.Signal.SendMessage, %{
        "room_id" => incoming.data["room_id"],
        "reply_to_id" => incoming.data["message_id"],
        "text" => "Jido received Socket Mode input."
      })

    on_exit(fn -> delete(ctx.client, ctx.room, reply["id"]) end)
    assert reply["thread_id"] == root["id"]
    assert await_text("Jido received Socket Mode input.").data["message_id"] == reply["id"]
  end

  test "Socket Mode input reaches the Agent Plugin and sends a Chat reply", ctx do
    {:ok, _} = Application.ensure_all_started(:jido)
    start_supervised!({Jido, name: Jido.Chat.Slack.LiveTestJido})
    definition = Jido.Chat.Slack.LiveAgent.definition()
    [entry] = definition.extensions
    [connection] = entry.data.connections
    client = %{ctx.client | id: "slack/live-agent"}

    connection = %{
      connection
      | rooms: [ctx.room],
        client: Map.take(client, [:adapter, :id, :credentials, :config, :transport])
    }

    definition = %{definition | extensions: [%{entry | data: %{entry.data | connections: [connection]}}]}
    {:ok, server} = Jido.start_agent(Jido.Chat.Slack.LiveTestJido, definition, id: "slack-live-proof")
    :ok = Jido.AgentServer.await_ready(server)
    Process.sleep(1_500)
    marker = "Jido Agent proof " <> Jido.Signal.ID.generate!()
    root = execute(ctx.client, Chat.Signal.SendMessage, %{"room_id" => ctx.room, "text" => marker})
    on_exit(fn -> delete(ctx.client, ctx.room, root["id"]) end)
    result = await_agent_reply(server, 200)
    assert result.type == "jido.chat.command.send_message.completed"
    reply = result.data["result"]
    on_exit(fn -> delete(ctx.client, ctx.room, reply["id"]) end)
    assert reply["thread_id"] == root["id"]
    page = execute(ctx.client, Chat.Signal.FetchMessages, %{"room_id" => ctx.room, "thread_id" => root["id"]})

    assert Enum.any?(
             page["messages"],
             &(&1["id"] == reply["id"] and &1["text"] == "Jido Agent received Socket Mode input.")
           )
  end

  @tag live_ui: true
  @tag timeout: 180_000
  @tag skip: System.get_env("RUN_LIVE_SLACK_UI_TESTS") not in ["1", "true"]
  test "a real button opens a modal and submission reaches the shared Sensor", ctx do
    start_supervised!(
      {Chat.Sensor,
       client: ctx.client,
       source: Jido.Chat.Slack.Source,
       options: [socket_client: Jido.Chat.Slack.LiveUISocket, socket_options: [observer: self()]],
       rooms: [ctx.room],
       emit: "jido.chat.**",
       dispatch: {:pid, target: self()}}
    )

    Process.sleep(1_500)

    root =
      Live.facade(ctx.client, :send_text, [ctx.room, "Jido interactive proof"],
        keyboard: %{"rows" => [[%{"text" => "Open test form", "value" => "jido-modal-proof"}]]}
      )

    on_exit(fn -> delete(ctx.client, ctx.room, root["id"]) end)
    IO.puts("UI_READY: Click Open test form in the test channel.")

    trigger =
      receive do
        {:private_trigger, value} -> value
      after
        90_000 -> flunk("No real button trigger received")
      end

    modal = %{
      "title" => "Jido test form",
      "callback_id" => "jido-live-proof",
      "private_metadata" => Jason.encode!(%{"channel_id" => ctx.room}),
      "elements" => [%{"kind" => "text_input", "id" => "proof", "label" => "Test value", "required" => true}]
    }

    opened =
      Live.execute(ctx.client, Chat.Signal.OpenModal, %{"room_id" => ctx.room, "modal" => modal}, trigger_id: trigger)

    assert opened["opened"]
    action = await_fact("jido.chat.action.received", 30_000)
    assert action.data["room_id"] == ctx.room
    assert action.data["message_id"] == root["id"]
    assert action.data["value"] == "jido-modal-proof"
    IO.puts("MODAL_READY: Enter Jido UI proof and submit.")
    submitted = await_fact("jido.chat.modal.submitted", 90_000)
    assert submitted.data["view_id"] == opened["id"]
    assert submitted.data["callback_id"] == "jido-live-proof"
    assert submitted.data["room_id"] == ctx.room
    assert submitted.data["values"]["proof"] == "Jido UI proof"

    for fact <- [action, submitted] do
      assert {:ok, json} = Jido.Signal.Serialization.serialize(fact)
      refute json =~ trigger
      refute json =~ "response_url"
      assert {:ok, decoded} = Jido.Signal.Catalog.decode(Chat.catalog(ctx.client), json)
      assert decoded == fact
    end
  end

  defp await_fact(type, timeout), do: await_fact_until(type, System.monotonic_time(:millisecond) + timeout)

  defp await_fact_until(type, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:signal, %{type: ^type} = fact} -> fact
      %{type: ^type} = fact -> fact
      {:signal, %{type: "jido.chat.normalization.failed"}} -> flunk("Live input could not be normalized")
      _ -> await_fact_until(type, deadline)
    after
      remaining -> flunk("Expected live fact was not received: #{type}")
    end
  end

  defp await_agent_reply(_, 0), do: flunk("Agent did not send a reply")

  defp await_agent_reply(server, tries) do
    case Jido.AgentServer.agent(server).state.result do
      nil ->
        Process.sleep(100)
        await_agent_reply(server, tries - 1)

      result ->
        result
    end
  end

  defp await_socket(_, 0), do: flunk("Socket Mode did not connect")

  defp await_socket(worker, tries) do
    case :sys.get_state(worker).socket do
      nil ->
        Process.sleep(100)
        await_socket(worker, tries - 1)

      socket ->
        # WebSockex has a PID before the network handshake completes.
        if Process.alive?(socket), do: Process.sleep(1_500), else: flunk("Socket Mode connection stopped")
    end
  end

  defp await_text(text) do
    receive do
      {:signal, %{data: %{"text" => ^text}} = signal} -> signal
      {:signal, _} -> await_text(text)
    after
      20_000 -> flunk("Slack did not deliver the test message through Socket Mode")
    end
  end
end
