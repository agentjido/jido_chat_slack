defmodule Jido.Chat.Slack.RenderingMatrixTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.{Card, Modal}
  alias Jido.Chat.Slack.{InteractionResponse, Renderer}

  test "cards render text, sections, fields, images, links, and action controls" do
    options = [Card.select_option("A", "a"), Card.select_option("B", "b")]

    card =
      Card.new(%{
        title: "All controls",
        markdown: "**Body**",
        components: [
          Card.text("Text"),
          Card.section(title: "Section", text: "Body", items: [Card.text("Child")]),
          Card.field("Name", "Value"),
          Card.fields([Card.field("A", "B")], title: "Details"),
          Card.button("Go", "go", value: "go", style: :primary),
          Card.link("Site", "https://example.test"),
          Card.actions(
            [
              Card.button("Stop", "stop", style: :danger),
              Card.link_button("Site", "https://example.test", "site"),
              Card.radio_select("radio", options, value: "b"),
              Card.select("select", options, value: "a")
            ],
            title: "Actions"
          ),
          Card.image("https://example.test/image.png", title: "Image", alt_text: "Image"),
          Card.divider()
        ]
      })

    assert {:ok, result} = Renderer.card(card)
    assert Enum.any?(result.blocks, &(&1["type"] == "image"))
    assert Enum.any?(result.blocks, &(&1["type"] == "divider"))
    assert result.fallback_used == false
    assert Renderer.option_limit() == 100

    for component <- [Card.select_option("A", "a"), Card.select_option_group("Group", options)] do
      assert {:error, {:unsupported_component_position, _}} = Renderer.card(%{components: [component]})
    end

    assert {:error, {:unsupported_action_component, :text}} =
             Renderer.card(%{components: [Card.actions([Card.text("bad")])]})
  end

  test "modal radio and external select values retain their initial options" do
    option = Modal.select_option("A", "a")

    elements = [
      Modal.radio_select("radio", "Radio", [option], value: "a"),
      Modal.external_select("external", "External", value: "a", options: [option]),
      Modal.number_input("number", "Number", min_value: 1, max_value: 3)
    ]

    assert {:ok, result} = Renderer.modal(%{title: "Form", elements: elements})
    [radio, external, number] = result["blocks"]
    assert radio["element"]["initial_option"]["value"] == "a"
    assert external["element"]["initial_option"]["value"] == "a"
    assert number["element"]["min_value"] == "1"
    assert {:ok, %{"blocks" => []}} = Renderer.modal(%{"type" => "modal", "blocks" => []})
  end

  test "option groups and control limits reject invalid provider payloads" do
    assert {:ok, %{"option_groups" => [_]}} =
             Renderer.options_response(%{option_groups: [%{label: "Group", options: [%{label: "A", value: "a"}]}]})

    for {payload, reason} <- [
          {%{option_groups: Enum.map(1..101, fn _ -> %{label: "Group", options: []} end)},
           {:provider_limit, :option_groups, 100}},
          {%{option_groups: [%{label: "Group", options: Enum.map(1..101, &%{label: "A", value: to_string(&1)})}]},
           {:provider_limit, :group_options, 100}},
          {%{options: [%{label: String.duplicate("a", 76), value: "a"}]}, {:provider_limit, :option_label, 75}}
        ] do
      assert {:error, ^reason} = Renderer.options_response(payload)
    end

    options = Enum.map(1..101, &Card.select_option("A", to_string(&1)))
    assert {:error, {:provider_limit, :options, 100}} = Renderer.card(%{components: [Card.select("select", options)]})

    assert {:error, {:provider_limit, :table_rows, 200}} =
             Renderer.card(%{components: [Card.table(["a"], Enum.map(1..201, &[&1]))]})

    assert {:error, {:provider_limit, :table_page_size, 100}} =
             Renderer.card(%{components: [Card.table(["a"], [[1]], page_size: 101)]})

    assert {:ok, _} = Renderer.card(%{components: [Card.table(["a"], [[1]])]})

    for {kind, component} <- [
          pie: Card.pie_chart([%{label: "A", value: 1}]),
          bar: Card.bar_chart([%{label: "A", value: 1}]),
          area: Card.area_chart([%{label: "A", value: 1}])
        ] do
      assert {:ok, %{fallback_used: true}} = Renderer.card(%{title: to_string(kind), components: [component]})
    end
  end

  def build_response(prefix, _context), do: %{"text" => prefix}

  test "host webhook responses and Socket Mode payload helpers preserve response shape" do
    envelope = %{"envelope_id" => "E", "accepts_response_payload" => true, "payload" => %{}}
    assert InteractionResponse.webhook_response(:ok) == nil
    assert InteractionResponse.webhook_response({:reply, "hello"}) == %{status: 200, body: "hello"}
    assert InteractionResponse.webhook_response({:ok, {:reply, %{status: 201, body: "a"}}}) == %{status: 201, body: "a"}

    for response <- [%{"text" => "hello"}, %{body: "hello"}, "hello"] do
      ack = InteractionResponse.socket_ack_payload(envelope, :ok, response_payload: response)
      assert ack == %{"envelope_id" => "E", "payload" => %{"text" => "hello"}}
    end

    for opts <- [[], [response_builder: :bad], [response_payload: 42]] do
      assert InteractionResponse.socket_ack_payload(envelope, :ok, opts) == %{"envelope_id" => "E"}
    end

    assert InteractionResponse.socket_ack_payload(%{"envelope_id" => "E"}, :ok, response_payload: "ignored") == %{
             "envelope_id" => "E"
           }

    for builder <- [fn _, _ -> %{"text" => "hello"} end, {__MODULE__, :build_response, ["hello"]}] do
      assert InteractionResponse.socket_ack_payload(envelope, :ok, response_builder: builder)["payload"] == %{
               "text" => "hello"
             }
    end

    failed = %Jido.Signal{
      id: "failed",
      source: "test",
      type: "jido.chat.query.load_options.failed",
      data: %{"operation" => "jido.chat.query.load_options"}
    }

    assert InteractionResponse.socket_ack_payload(envelope, {:ok, failed})["payload"] == %{"options" => []}

    completed = %{
      failed
      | type: "jido.chat.query.load_options.completed",
        data: %{
          "operation" => "jido.chat.query.load_options",
          "result" => %{options: Enum.map(1..101, &%{label: "A", value: to_string(&1)})}
        }
    }

    assert InteractionResponse.socket_ack_payload(envelope, {:ok, completed})["payload"] == %{"options" => []}
  end
end
