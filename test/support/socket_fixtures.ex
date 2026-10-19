defmodule Jido.Chat.Slack.SocketFixtures do
  @moduledoc false
  defmodule Connection do
    @moduledoc "Recording socket fixture for Source lifecycle tests."
    @doc "Consumes a planned connection result and records the attempt."
    def open_socket(_token, opts) do
      send(opts[:test], :open_socket)

      Agent.get_and_update(opts[:control], fn
        [result | rest] -> {result, rest}
        [] -> {{:ok, "wss://test"}, []}
      end)
    end
  end

  defmodule Socket do
    @moduledoc "Recording socket fixture for Source lifecycle tests."
    @doc "Starts a recording test socket for the Source worker."
    def connect(_url, owner, opts) do
      test = opts[:test]
      pid = spawn(fn -> loop(owner, test) end)
      send(test, {:socket, pid, owner})
      {:ok, pid}
    end

    defp loop(owner, test) do
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, _, _, _} -> send(test, :owner_down)
        :close -> send(test, :closed)
      end
    end

    @doc "Records the envelope acknowledgement for the test process."
    def send_text(socket, text) do
      send(Process.get(:test), {:ack, socket, Jason.decode!(text)})
      :ok
    end

    @doc "Requests termination of the recording socket."
    def close(socket), do: send(socket, :close)
  end

  # Socket calls run in the worker. Store the test PID in that process.
  defmodule TestSocket do
    @moduledoc "Recording socket fixture for Source lifecycle tests."
    @doc "Starts a recording test socket for the Source worker."
    def connect(url, owner, opts) do
      Process.put(:test, opts[:test])
      Socket.connect(url, owner, opts)
    end

    defdelegate send_text(socket, text), to: Socket
    defdelegate close(socket), to: Socket
  end
end
