defmodule Jido.Chat.Slack do
  @moduledoc """
  Slack adapter package for `Jido.Chat`.

  This package uses Slack's Web API and supports webhook and Socket Mode ingress.
  """

  alias Jido.Chat.Slack.Adapter

  @spec adapter() :: module()
  def adapter, do: Adapter
end
