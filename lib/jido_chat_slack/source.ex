defmodule Jido.Chat.Slack.Source do
  @moduledoc """
  Receive-only Socket Mode input for the shared Chat Sensor.

  The host starts the Sensor. Credentials use `token` for Web API requests and
  `app_token` for Socket Mode. One Sensor can run per app token. The worker opens
  a fresh URL after disconnect and closes its socket on shutdown. An ACK means
  Sensor admission. It does not mean durable storage or chat delivery.

  Private options are `:connection_client`, `:socket_client`, `:connection_options`,
  `:socket_options`, `:reconnect_interval` (default 1,000 ms),
  `:max_reconnect_interval` (default 30,000 ms), and `:push_timeout` (default 2,000 ms).
  """
  @behaviour Jido.Chat.Sensor.Source

  @impl true
  def mode, do: :push

  @impl true
  def signal_types, do: Enum.map(Jido.Chat.Slack.event_definitions(), & &1.type())

  @impl true
  def key(client, _options) do
    case client.credentials[:app_token] do
      token when is_binary(token) and token != "" -> :crypto.hash(:sha256, token)
      _ -> nil
    end
  end

  @impl true
  def start_link(client, sensor, options) do
    case client.credentials[:app_token] do
      token when is_binary(token) and token != "" ->
        Jido.Chat.Slack.Source.Worker.start_link(client, sensor, options)

      _ ->
        {:error, :missing_app_token}
    end
  end
end

defmodule Jido.Chat.Slack.Source.Worker do
  @moduledoc false
  use GenServer

  def start_link(client, sensor, options), do: GenServer.start_link(__MODULE__, {client, sensor, options})

  @impl true
  def init({client, sensor, options}) do
    Process.flag(:trap_exit, true)
    Process.flag(:sensitive, true)
    Process.monitor(sensor)

    state = %{
      client: client,
      sensor: sensor,
      options: options,
      socket: nil,
      monitor: nil,
      timer: nil,
      attempts: 0,
      connection_client: Keyword.get(options, :connection_client, Jido.Chat.Slack.SocketMode.ReqClient),
      socket_client: Keyword.get(options, :socket_client, Jido.Chat.Slack.SocketMode.WebSockexClient)
    }

    {:ok, state, {:continue, :connect}}
  end

  # OTP reports include the current frame and private connection options by default.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} -> {:state, %{status: :slack_source, attempts: state.attempts, connected: is_pid(state.socket)}}
      {:reason, reason} when is_atom(reason) -> {:reason, reason}
      {:reason, _} -> {:reason, :source_failure}
      {:message, _} -> {:message, :redacted}
      {:log, _} -> {:log, []}
      {:dictionary, _} -> {:dictionary, []}
      entry -> entry
    end)
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, connect(state)}
  rescue
    _ -> {:stop, :source_failure, state}
  catch
    _, _ -> {:stop, :source_failure, state}
  end

  @impl true
  def handle_info(message, state) do
    handle_event(message, state)
  rescue
    _ -> {:stop, :source_failure, state}
  catch
    _, _ -> {:stop, :source_failure, state}
  end

  defp handle_event(:reconnect, state), do: {:noreply, connect(%{state | timer: nil})}

  defp handle_event({:socket_mode, socket, :connected}, %{socket: socket} = state),
    do: {:noreply, %{state | attempts: 0}}

  defp handle_event({:socket_mode, socket, {:text, text}}, %{socket: socket} = state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "disconnect"}} ->
        {:noreply, reconnect(state)}

      {:ok, %{"envelope_id" => id} = envelope} when is_binary(id) and id != "" ->
        case admit(envelope, state) do
          :ok ->
            case state.socket_client.send_text(socket, Jason.encode!(%{"envelope_id" => id})) do
              :ok -> {:noreply, state}
              _ -> {:noreply, reconnect(state)}
            end

          _ ->
            {:noreply, reconnect(state)}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp handle_event({:socket_mode, socket, {:disconnected, _}}, %{socket: socket} = state),
    do: {:noreply, reconnect(state)}

  defp handle_event({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:noreply, reconnect(state)}

  defp handle_event({:DOWN, _, :process, sensor, _}, %{sensor: sensor} = state), do: {:stop, :normal, state}
  defp handle_event({:EXIT, sensor, _}, %{sensor: sensor} = state), do: {:stop, :normal, state}
  defp handle_event(_, state), do: {:noreply, state}

  defp admit(envelope, state) do
    with {:ok, delivery} <- Jido.Chat.normalize(state.client, envelope) do
      Jido.Chat.Sensor.push(state.sensor, delivery.signals, Keyword.get(state.options, :push_timeout, 2_000))
    end
  catch
    :exit, _ -> {:error, :input_rejected}
  end

  defp connect(state) do
    with {:ok, url} <-
           state.connection_client.open_socket(
             state.client.credentials.app_token,
             Keyword.get(state.options, :connection_options, [])
           ),
         {:ok, socket} when is_pid(socket) <-
           state.socket_client.connect(url, self(), Keyword.get(state.options, :socket_options, [])) do
      %{state | socket: socket, monitor: Process.monitor(socket)}
    else
      _ -> schedule(state)
    end
  end

  defp reconnect(state), do: state |> close() |> schedule()

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    base = Keyword.get(state.options, :reconnect_interval, 1_000)
    maximum = Keyword.get(state.options, :max_reconnect_interval, 30_000)
    delay = min(base * Integer.pow(2, min(state.attempts, 10)), maximum)
    %{state | timer: Process.send_after(self(), :reconnect, delay), attempts: state.attempts + 1}
  end

  defp close(state) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    if state.socket, do: state.socket_client.close(state.socket)
    %{state | socket: nil, monitor: nil}
  end

  @impl true
  def terminate(_, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    close(state)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
