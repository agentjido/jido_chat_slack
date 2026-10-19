defmodule Jido.Chat.Slack.LiveAgent.Reply do
  @moduledoc "Test Action that replies to a marked Socket Mode message."
  use Jido.Action, name: "slack_live_reply", schema: Zoi.map()

  def run(params, context) do
    if String.starts_with?(params["text"] || "", "Jido Agent proof ") do
      request =
        Jido.Chat.Signal.SendMessage.new!(%{
          "client_id" => context.chat.client_id,
          "request_id" => params["item_id"] <> ":reply",
          "room_id" => params["room_id"],
          "reply_to_id" => params["message_id"],
          "text" => "Jido Agent received Socket Mode input."
        })

      {:ok, context.agent_state, [Jido.Agent.Directive.emit(request)]}
    else
      {:ok, context.agent_state}
    end
  end
end

defmodule Jido.Chat.Slack.LiveAgent.Record do
  @moduledoc "Test Action that records a completed shared Chat reply."
  use Jido.Action, name: "slack_live_record", schema: Zoi.map()

  def run(_, context) do
    {:ok, Map.put(context.agent_state, :result, context.signal)}
  end
end

defmodule Jido.Chat.Slack.LiveAgent do
  use Jido.Agent, name: "slack_live_agent"

  agent do
    plugin(Jido.Chat.Plugin)
    schema(Zoi.object(%{result: Zoi.any() |> Zoi.default(nil)}))
  end

  chat do
    connection :slack do
      client(Jido.Chat.Slack.Adapter, id: "slack/live-agent")
      rooms(["test-room"])
      commands([Jido.Chat.SendMessage])
      source(Jido.Chat.Slack.Source, emit: "jido.chat.message.received")
    end
  end

  routes do
    route("jido.chat.message.received", Jido.Chat.Slack.LiveAgent.Reply, emits: ["jido.chat.command.send_message"])
    route("jido.chat.command.send_message", Jido.Chat.Plugin.Execute, emits: [])
    route("jido.chat.command.send_message.completed", Jido.Chat.Slack.LiveAgent.Record, emits: [])
    route("jido.chat.command.send_message.failed", Jido.Chat.Slack.LiveAgent.Record, emits: [])
  end
end
