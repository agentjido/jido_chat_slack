defmodule Jido.Chat.SlackTest do
  use ExUnit.Case, async: true

  test "channel/0 returns the slack channel module" do
    assert Jido.Chat.Slack.channel() == Jido.Chat.Slack.Channel
  end
end
