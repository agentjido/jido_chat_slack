defmodule Jido.Chat.Slack.SendCard do
  @moduledoc "Sends one Slack card with a Client and a request Signal."
  use Jido.ChatAction,
    name: "slack_send_card",
    signal: Jido.Chat.Slack.Signal.SendCard,
    result_schema: Jido.Chat.Signal.Schemas.result(:message)

  @impl Jido.ChatAction
  def invoke(client, signal, options), do: Jido.Chat.Slack.Operations.send_card(client, signal, options)
end
