defmodule Jido.Chat.Slack.LiveUISocket do
  @moduledoc false
  alias Jido.Chat.Slack.SocketMode.WebSockexClient, as: Socket

  @doc "Starts a test relay that keeps fresh modal triggers private."
  def connect(url, owner, options) do
    observer = Keyword.fetch!(options, :observer)

    pid =
      spawn_link(fn ->
        Process.flag(:sensitive, true)
        {:ok, socket} = Socket.connect(url, self(), [])
        loop(socket, owner, observer)
      end)

    {:ok, pid}
  end

  @doc "Forwards the Source ACK to the real socket."
  def send_text(pid, payload) do
    send(pid, {:ack, payload})
    :ok
  end

  @doc "Closes the test relay and its owned socket."
  def close(pid) do
    send(pid, :close)
    :ok
  end

  defp loop(socket, owner, observer) do
    receive do
      {:socket_mode, ^socket, {:text, text}} ->
        case Jason.decode(text) do
          {:ok, %{"payload" => %{"trigger_id" => trigger, "type" => "block_actions"}}} ->
            send(observer, {:private_trigger, trigger})

          _ ->
            :ok
        end

        send(owner, {:socket_mode, self(), {:text, text}})
        loop(socket, owner, observer)

      {:socket_mode, ^socket, status} ->
        send(owner, {:socket_mode, self(), status})
        loop(socket, owner, observer)

      {:ack, text} ->
        Socket.send_text(socket, text)
        loop(socket, owner, observer)

      :close ->
        Socket.close(socket)
    end
  end
end
