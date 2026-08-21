defmodule Jido.Chat.Slack.CardsModalsTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Card, EventEnvelope, Modal, OptionsLoadError, OptionsLoadEvent}
  alias Jido.Chat.Adapter, as: ChatAdapter
  alias Jido.Chat.Slack.Renderer

  defmodule MockTransport do
    @behaviour Jido.Chat.Slack.Transport

    @impl true
    def send_message(channel_id, text, opts) do
      send(self(), {:send_message, channel_id, text, opts})
      {:ok, %{"channel" => channel_id, "ts" => "1706745600.000100"}}
    end

    @impl true
    def open_modal(trigger_id, payload, _opts) do
      send(self(), {:open_modal, trigger_id, payload})
      {:ok, %{"view" => %{"id" => "V123", "callback_id" => payload["callback_id"]}}}
    end

    @impl true
    def send_file(_channel_id, _upload, _opts), do: {:error, :unsupported}
    @impl true
    def edit_message(_channel_id, _message_id, _text, _opts), do: {:error, :unsupported}
    @impl true
    def delete_message(_channel_id, _message_id, _opts), do: {:error, :unsupported}
    @impl true
    def fetch_metadata(_channel_id, _opts), do: {:error, :unsupported}
    @impl true
    def fetch_thread(_channel_id, _opts), do: {:error, :unsupported}
    @impl true
    def fetch_message(_channel_id, _message_id, _opts), do: {:error, :unsupported}
    @impl true
    def download_file(_url, _opts), do: {:error, :unsupported}
    @impl true
    def fetch_messages(_channel_id, _opts), do: {:error, :unsupported}
    @impl true
    def fetch_channel_messages(_channel_id, _opts), do: {:error, :unsupported}
    @impl true
    def list_threads(_channel_id, _opts), do: {:error, :unsupported}
    @impl true
    def add_reaction(_channel_id, _message_id, _emoji, _opts), do: {:error, :unsupported}
    @impl true
    def remove_reaction(_channel_id, _message_id, _emoji, _opts), do: {:error, :unsupported}
    @impl true
    def post_ephemeral(_channel_id, _user_id, _text, _opts), do: {:error, :unsupported}
    @impl true
    def open_dm(_user_id, _opts), do: {:error, :unsupported}
  end

  test "card renderer uses Slack tables and readable chart fallbacks" do
    card =
      Card.new(%{
        title: "Service health",
        components: [
          Card.line_chart(["Mon", "Tue"], [%{name: "API", values: [10, 12]}], title: "Requests"),
          Card.table(["Service", "State"], [["api", "ok"]],
            caption: "Current health",
            page_size: 25
          )
        ]
      })

    assert {:ok, rendered} = Renderer.card(card)
    assert rendered.fallback_used == true

    assert Enum.any?(rendered.blocks, fn block ->
             block["type"] == "section" and block["text"]["text"] =~ "API"
           end)

    assert %{
             "type" => "data_table",
             "caption" => "Current health",
             "page_size" => 25,
             "rows" => [header, row]
           } = Enum.find(rendered.blocks, &(&1["type"] == "data_table"))

    assert Enum.map(header, & &1["text"]) == ["Service", "State"]
    assert Enum.map(row, & &1["text"]) == ["api", "ok"]
  end

  test "card posts preserve stable link action IDs" do
    card =
      Card.new(%{
        components: [Card.actions([Card.link_button("Runbook", "https://example.test", "runbook")])]
      })

    assert {:ok, _response} =
             ChatAdapter.post_message(
               Jido.Chat.Slack.Adapter,
               "C123",
               Jido.Chat.PostPayload.new(%{kind: :card, card: card}),
               transport: MockTransport
             )

    assert_received {:send_message, "C123", text, opts}
    assert text =~ "Runbook"

    assert [%{"type" => "actions", "elements" => [button]}] =
             Enum.filter(Keyword.fetch!(opts, :blocks), &(&1["type"] == "actions"))

    assert button["action_id"] == "runbook"
    assert button["url"] == "https://example.test"

    request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :slack,
        payload: %{
          "type" => "block_actions",
          "channel" => %{"id" => "C123"},
          "actions" => [%{"action_id" => button["action_id"], "url" => button["url"]}],
          "user" => %{"id" => "U123"}
        }
      })

    assert {:ok, %EventEnvelope{payload: action}} =
             Jido.Chat.Slack.Adapter.parse_event(request, [])

    assert action.action_id == "runbook"
  end

  test "provider table limits fail explicitly" do
    columns = Enum.map(1..21, &"column-#{&1}")
    table = Card.table(columns, [columns], caption: "Too wide")

    assert {:error, {:provider_limit, :table_columns, 20}} =
             Renderer.card(Card.new(%{components: [table]}))
  end

  test "table character limit applies across all tables in a card" do
    at_limit = [
      Card.table(["a"], [[String.duplicate("x", 9_999)]]),
      Card.table(["b"], [[String.duplicate("y", 9_999)]])
    ]

    assert {:ok, _rendered} = Renderer.card(Card.new(%{components: at_limit}))

    over_limit = [
      Card.table(["a"], [[String.duplicate("x", 9_999)]]),
      Card.table(["b"], [[String.duplicate("y", 10_000)]])
    ]

    assert {:error, {:provider_limit, :table_characters, 20_000}} =
             Renderer.card(Card.new(%{components: over_limit}))
  end

  test "modal renderer maps date, number, and external select inputs" do
    modal =
      Modal.new(%{
        callback_id: "report",
        title: "Report",
        elements: [
          Modal.date_input("day", "Day", value: ~D[2026-08-20]),
          Modal.number_input("count", "Count", value: 12.5, min_value: 0, max_value: 100),
          Modal.external_select("owner", "Owner", min_query_length: 2)
        ]
      })

    assert {:ok, result} =
             ChatAdapter.open_modal(Jido.Chat.Slack.Adapter, "C123", modal,
               transport: MockTransport,
               trigger_id: "1337.42"
             )

    assert result.id == "slack:modal:V123"
    assert_received {:open_modal, "1337.42", view}

    assert [date, number, external] = view["blocks"]
    assert date["element"]["type"] == "datepicker"
    assert date["element"]["initial_date"] == "2026-08-20"
    assert date["element"]["action_id"] == "day"
    assert number["element"]["type"] == "number_input"
    assert number["element"]["initial_value"] == "12.5"
    assert number["element"]["is_decimal_allowed"] == true
    assert external["element"]["type"] == "external_select"
    assert external["element"]["min_query_length"] == 2
  end

  test "unsupported native modal constraints return explicit errors" do
    modal =
      Modal.new(%{
        title: "Report",
        elements: [Modal.number_input("count", "Count", step: 0.5)]
      })

    assert {:error, {:unsupported_constraint, :number_input, :step}} = Renderer.modal(modal)
  end

  test "text, date, number, static select, and external select placeholders allow 150 characters" do
    placeholder = String.duplicate("p", 150)
    option = Modal.select_option("One", "one")

    modal =
      Modal.new(%{
        title: "Report",
        elements: [
          Modal.text_input("notes", "Notes", placeholder: placeholder),
          Modal.date_input("day", "Day", placeholder: placeholder),
          Modal.number_input("count", "Count", placeholder: placeholder),
          Modal.select("status", "Status", [option], placeholder: placeholder),
          Modal.external_select("owner", "Owner", placeholder: placeholder)
        ]
      })

    assert {:ok, view} = Renderer.modal(modal)

    assert Enum.all?(view["blocks"], fn block ->
             get_in(block, ["element", "placeholder", "text"]) == placeholder
           end)
  end

  test "text, date, number, static select, and external select reject longer placeholders" do
    placeholder = String.duplicate("p", 151)
    option = Modal.select_option("One", "one")

    elements = [
      Modal.text_input("notes", "Notes", placeholder: placeholder),
      Modal.date_input("day", "Day", placeholder: placeholder),
      Modal.number_input("count", "Count", placeholder: placeholder),
      Modal.select("status", "Status", [option], placeholder: placeholder),
      Modal.external_select("owner", "Owner", placeholder: placeholder)
    ]

    Enum.each(elements, fn element ->
      modal = Modal.new(%{title: "Report", elements: [element]})

      assert {:error, {:provider_limit, :input_placeholder, 150}} = Renderer.modal(modal)
    end)
  end

  test "card static and external selects use the shared placeholder limit" do
    placeholder = String.duplicate("p", 150)
    option = Card.select_option("One", "one")

    assert {:ok, _rendered} =
             Renderer.card(
               Card.new(%{
                 components: [
                   Card.select("status", [option], label: placeholder),
                   Card.external_select("owner", label: placeholder)
                 ]
               })
             )

    over_limit = String.duplicate("p", 151)

    Enum.each(
      [
        Card.select("status", [option], label: over_limit),
        Card.external_select("owner", label: over_limit)
      ],
      fn component ->
        assert {:error, {:provider_limit, :input_placeholder, 150}} =
                 Renderer.card(Card.new(%{components: [component]}))
      end
    )
  end

  test "number inputs allow decimal values when the canonical input has no integer-only flag" do
    modal =
      Modal.new(%{
        title: "Report",
        elements: [Modal.number_input("count", "Count")]
      })

    assert {:ok, %{"blocks" => [%{"element" => number_input}]}} = Renderer.modal(modal)
    assert number_input["is_decimal_allowed"] == true
  end

  test "block suggestions normalize and option loaders enforce Slack limits" do
    request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :slack,
        payload: %{
          "type" => "block_suggestion",
          "action_id" => "owner",
          "value" => "ad",
          "user" => %{"id" => "U123", "username" => "ada"},
          "view" => %{"id" => "V123"}
        }
      })

    assert {:ok, %EventEnvelope{event_type: :options_load, payload: %OptionsLoadEvent{} = event}} =
             Jido.Chat.Slack.Adapter.parse_event(request, [])

    assert event.action_id == "owner"
    assert event.query == "ad"
    assert event.view_id == "V123"
    assert event.thread_id == nil

    loader = fn %OptionsLoadEvent{query: "ad"} ->
      {:ok, %{options: [%{label: "Ada", value: "user:ada"}]}}
    end

    assert {:ok, result} = Jido.Chat.Slack.Adapter.load_options(event, options_loader: loader)
    assert result.metadata.slack_response["options"] |> hd() |> get_in(["text", "text"]) == "Ada"

    too_many = fn _event ->
      {:ok,
       %{
         options: Enum.map(1..101, fn index -> %{label: "Option #{index}", value: "#{index}"} end)
       }}
    end

    assert {:error, %OptionsLoadError{code: "provider_limit"}} =
             Jido.Chat.Slack.Adapter.load_options(event, options_loader: too_many)
  end

  test "options-load webhook replies use Slack's response shape" do
    chat = Jido.Chat.new(adapters: %{slack: Jido.Chat.Slack.Adapter})

    payload = %{
      "type" => "block_suggestion",
      "action_id" => "owner",
      "value" => "ad",
      "user" => %{"id" => "U123"}
    }

    loader = fn _event ->
      {:ok, %{options: [%{label: "Ada", value: "user:ada"}]}}
    end

    assert {:ok, ^chat, %EventEnvelope{event_type: :options_load}, response} =
             Jido.Chat.WebhookPipeline.handle_request(
               chat,
               :slack,
               payload,
               [options_loader: loader],
               &Jido.Chat.get_adapter/2,
               &Jido.Chat.process_event/4
             )

    assert response.status == 200

    assert response.body == %{
             "options" => [
               %{
                 "text" => %{"type" => "plain_text", "text" => "Ada", "emoji" => true},
                 "value" => "user:ada"
               }
             ]
           }
  end

  test "option loader timeouts stay typed at the core boundary" do
    event = OptionsLoadEvent.new(%{action_id: "owner", query: "ad", timeout_ms: 25})

    assert {:error, %OptionsLoadError{kind: :timeout, timeout_ms: 25}} =
             ChatAdapter.load_options(Jido.Chat.Slack.Adapter, event,
               options_loader: fn _event -> {:error, :timeout} end
             )

    assert {:error, %OptionsLoadError{kind: :timeout, timeout_ms: 5}} =
             ChatAdapter.load_options(Jido.Chat.Slack.Adapter, event,
               timeout_ms: 5,
               options_loader: fn _event ->
                 Process.sleep(50)
                 {:ok, %{options: []}}
               end
             )

    error = OptionsLoadError.timeout(25)
    response = Jido.Chat.Slack.Adapter.format_webhook_response({:error, error}, [])

    assert response.status == 200
    assert response.body == %{"options" => []}
    assert response.metadata.options_load_error["kind"] == :timeout
  end

  test "capabilities declare native inputs and explicit chart fallback" do
    capabilities = Jido.Chat.Slack.Adapter.capabilities()

    assert capabilities.cards == :native
    assert capabilities.card_charts == :fallback
    assert capabilities.card_tables == :native
    assert capabilities.link_action_ids == :native
    assert capabilities.modal_date_input == :native
    assert capabilities.modal_number_input == :native
    assert capabilities.external_select == :native
    assert capabilities.options_load == :native
    assert :ok = Jido.Chat.Adapter.validate_capabilities(Jido.Chat.Slack.Adapter)
  end
end
