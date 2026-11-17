defmodule Jido.Chat.Slack.RendererTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{Card, Modal}
  alias Jido.Chat.Slack.Renderer

  test "cards retain readable text and Slack block limits" do
    card =
      Card.new(%{
        title: "Service health",
        components: [
          Card.line_chart(["Mon", "Tue"], [%{name: "API", values: [10, 12]}], title: "Requests"),
          Card.table(["Service", "State"], [["api", "ok"]], caption: "Current health")
        ]
      })

    assert {:ok, rendered} = Renderer.card(card)
    assert rendered.fallback_used
    assert rendered.text =~ "Service health"
    assert Enum.any?(rendered.blocks, &(&1["type"] == "data_table"))
  end

  test "canonical and provider modal maps render as Slack views" do
    modal = Modal.new(%{title: "Survey", callback_id: "survey", private_metadata: ~s({"room_id":"C1"})})
    assert {:ok, %{"type" => "modal", "callback_id" => "survey"}} = Renderer.modal(modal)

    provider = %{"type" => "modal", "title" => %{"type" => "plain_text", "text" => "Native"}, "blocks" => []}
    assert {:ok, ^provider} = Renderer.modal(provider)
  end

  test "canonical option maps render and enforce mutual exclusion" do
    assert {:ok, %{"options" => [%{"text" => %{"text" => "One"}, "value" => "1"}]}} =
             Renderer.options_response(%{"options" => [%{"label" => "One", "value" => "1"}]})

    assert {:error, {:provider_validation, :options_and_groups_are_mutually_exclusive}} =
             Renderer.options_response(%{
               "options" => [%{"label" => "One", "value" => "1"}],
               "option_groups" => [%{"label" => "Group", "options" => []}]
             })
  end
end
