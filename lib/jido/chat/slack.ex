defmodule Jido.Chat.Slack do
  @moduledoc """
  Slack adapter package for `Jido.Chat`.

  This package uses Slack's Web API and webhook-style ingress.
  """

  alias Jido.Chat.Slack.Adapter
  alias Jido.Chat.Slack.Channel

  @spec adapter() :: module()
  def adapter, do: Adapter

  @spec channel() :: module()
  def channel, do: Channel
end
