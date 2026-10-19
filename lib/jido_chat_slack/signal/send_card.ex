defmodule Jido.Chat.Slack.Signal.SendCard do
  @moduledoc "Typed Slack Block Kit card command."
  use Jido.Signal,
    type: "jido.chat.slack.command.send_card",
    dataschema: "urn:jido:chat:slack:send_card:2",
    default_source: "urn:jido:chat:producer:local",
    schema:
      Zoi.map(
        %{
          "client_id" => Jido.Chat.Signal.Schemas.id(),
          "request_id" => Jido.Chat.Signal.Schemas.id(),
          "room_id" => Jido.Chat.Signal.Schemas.id(),
          "card" => Jido.Chat.Signal.Schemas.card(),
          "thread_id" => Jido.Chat.Signal.Schemas.id() |> Zoi.optional()
        },
        unrecognized_keys: :error
      )
end
