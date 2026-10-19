defmodule Jido.Chat.Slack.SocketMode.WebSockexClient do
  @moduledoc """
  WebSocket client implementation for Slack Socket Mode backed by `WebSockex`.
  """

  use WebSockex

  @behaviour Jido.Chat.Slack.SocketMode.SocketClient

  @impl true
  def connect(url, owner, opts \\ [])
      when is_binary(url) and is_pid(owner) and is_list(opts) do
    WebSockex.start_link(url, __MODULE__, %{owner: owner}, connection_options(url, opts))
  end

  @doc false
  def connection_options(url, opts) do
    opts
    |> Keyword.drop([:headers])
    |> Keyword.put_new(:insecure, false)
    |> Keyword.put_new(:ssl_options,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: url |> URI.parse() |> Map.fetch!(:host) |> String.to_charlist(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    )
    |> Keyword.put_new(:async, true)
    |> Keyword.put_new(:handle_initial_conn_failure, true)
    |> maybe_put_extra_headers(normalize_headers(opts[:headers]))
  end

  @impl true
  def send_text(socket, payload) when is_binary(payload),
    do: WebSockex.cast(socket, {:send_text, payload})

  @impl true
  def close(socket), do: WebSockex.cast(socket, :close)

  @impl true
  def handle_connect(_conn, state) do
    Process.flag(:sensitive, true)
    send(state.owner, {:socket_mode, self(), :connected})
    {:ok, Map.put(state, :owner_monitor, Process.monitor(state.owner))}
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
    Process.flag(:sensitive, true)
    reason = if is_atom(status.reason), do: status.reason, else: :connection_failure
    send(state.owner, {:socket_mode, self(), {:disconnected, reason}})
    {:ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{owner_monitor: ref} = state), do: {:close, state}
  def handle_info(_, state), do: {:ok, state}

  @impl true
  def format_status(_reason, [_dictionary, _state]), do: [data: [{"State", :redacted}]]

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
