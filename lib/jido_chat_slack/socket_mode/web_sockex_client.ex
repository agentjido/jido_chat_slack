defmodule Jido.Chat.Slack.SocketMode.WebSockexClient do
  @moduledoc """
  WebSocket client implementation for Slack Socket Mode backed by `WebSockex`.
  """

  use WebSockex

  @behaviour Jido.Chat.Slack.SocketMode.SocketClient

  @impl true
  def connect(url, owner, opts \\ [])
      when is_binary(url) and is_pid(owner) and is_list(opts) do
    ws_opts =
      opts
      |> Keyword.drop([:headers])
      |> Keyword.put_new(:async, true)
      |> Keyword.put_new(:handle_initial_conn_failure, true)
      |> maybe_put_extra_headers(normalize_headers(opts[:headers]))

    WebSockex.start(url, __MODULE__, %{owner: owner}, ws_opts)
  end

  @impl true
  def send_text(socket, payload) when is_binary(payload),
    do: WebSockex.cast(socket, {:send_text, payload})

  @impl true
  def close(socket), do: WebSockex.cast(socket, :close)

  @impl true
  def handle_connect(_conn, state) do
    send(state.owner, {:socket_mode, self(), :connected})
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    send(state.owner, {:socket_mode, self(), {:text, payload}})
    {:ok, state}
  end

  def handle_frame({:binary, payload}, state) do
    send(state.owner, {:socket_mode, self(), {:binary, payload}})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:send_text, payload}, state), do: {:reply, {:text, payload}, state}

  def handle_cast(:close, state), do: {:close, state}

  def handle_cast(_message, state), do: {:ok, state}

  @impl true
  def handle_disconnect(status, state) do
    send(state.owner, {:socket_mode, self(), {:disconnected, status.reason}})
    {:ok, state}
  end

  defp normalize_headers(nil), do: []

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp maybe_put_extra_headers(opts, []), do: opts
  defp maybe_put_extra_headers(opts, headers), do: Keyword.put(opts, :extra_headers, headers)
end
