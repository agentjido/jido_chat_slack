defmodule Jido.Chat.Slack do
  @moduledoc """
  Slack adapter package for `Jido.Chat`.

  This package uses Slack's Web API and supports webhook and Socket Mode ingress.
  """

  alias Jido.Chat.Slack.Adapter

  @doc "Returns the canonical Slack adapter module."
  @spec adapter() :: module()
  def adapter, do: Adapter
  @doc "Returns Slack extension request and Action pairs."
  def operations, do: [{Jido.Chat.Slack.Signal.SendCard, Jido.Chat.Slack.SendCard}]

  @doc "Returns native Slack extension Actions."
  def actions, do: [Jido.Chat.Slack.SendCard]

  @doc "Returns Slack extension Signal definitions."
  def signal_definitions, do: Enum.flat_map(actions(), & &1.signal_definitions())
  @doc "Returns the facts supplied by Slack."
  def event_definitions do
    [
      Jido.Chat.Signal.MessageReceived,
      Jido.Chat.Signal.MessageUpdated,
      Jido.Chat.Signal.MessageDeleted,
      Jido.Chat.Signal.ReactionAdded,
      Jido.Chat.Signal.ReactionRemoved,
      Jido.Chat.Signal.ActionReceived,
      Jido.Chat.Signal.ModalSubmitted,
      Jido.Chat.Signal.ModalClosed,
      Jido.Chat.Signal.OptionsRequested,
      Jido.Chat.Signal.SlashCommandReceived,
      Jido.Chat.Signal.AssistantThreadStarted,
      Jido.Chat.Signal.AssistantContextChanged,
      Jido.Chat.Signal.MembershipChanged,
      Jido.Chat.Signal.NormalizationFailed
    ]
  end
end
