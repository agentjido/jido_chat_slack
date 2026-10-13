defmodule Jido.Chat.Slack.InteractionResponse do
  @moduledoc """
  Normalizes Slack webhook responses and Socket Mode acknowledgements.
  """

  alias Jido.Chat.WebhookResponse

  @doc "Builds an optional webhook response from adapter or runtime results."
  @spec webhook_response(term(), keyword()) :: WebhookResponse.t() | nil
  def webhook_response(result, opts \\ []) when is_list(opts) do
    context = %{
      adapter_name: :slack,
      mode: :webhook,
      request: opts[:request],
      result: result
    }

    case response_value(context, opts) do
      nil ->
        nil

      %WebhookResponse{} = response ->
        response

      response ->
        if is_map(response) and webhook_response_shape?(response) do
          WebhookResponse.new(response)
        else
          WebhookResponse.new(%{status: 200, body: response})
        end
    end
  end

  @doc "Builds the Socket Mode acknowledgement payload for a Slack envelope."
  @spec socket_ack_payload(map(), term(), keyword()) :: map()
  def socket_ack_payload(envelope, sink_result, opts \\ [])
      when is_map(envelope) and is_list(opts) do
    ack = %{"envelope_id" => envelope_id(envelope)}

    if accepts_response_payload?(envelope) do
      context = %{
        adapter_name: :slack,
        mode: :socket_mode,
        envelope: envelope,
        payload: payload(envelope),
        sink_result: sink_result
      }

      case normalize_socket_payload(response_value(context, opts)) do
        nil -> ack
        payload -> Map.put(ack, "payload", payload)
      end
    else
      ack
    end
  end

  defp response_value(context, opts) do
    opts[:slack_response] ||
      opts[:response_payload] ||
      call_builder(
        Keyword.get(opts, :response_builder) || Keyword.get(opts, :slack_response_builder),
        context,
        opts
      ) ||
      default_response_value(context)
  end

  defp call_builder(nil, _context, _opts), do: nil

  defp call_builder(builder, context, _opts) when is_function(builder, 1), do: builder.(context)

  defp call_builder(builder, context, opts) when is_function(builder, 2),
    do: builder.(context, opts)

  defp call_builder({module, function, args}, context, _opts)
       when is_atom(module) and is_atom(function) and is_list(args) do
    apply(module, function, args ++ [context])
  end

  defp call_builder(_builder, _context, _opts), do: nil

  defp default_response_value(%{mode: :webhook, result: result}), do: response_from_result(result)
  defp default_response_value(%{mode: :socket_mode, sink_result: result}), do: response_from_result(result)
  defp default_response_value(_context), do: nil

  defp response_from_result({:reply, response}), do: response
  defp response_from_result({:ok, {:reply, response}}), do: response

  defp response_from_result({:ok, %Jido.Signal{type: "jido.chat.operation.completed", data: data}}) do
    if data["operation"] == "load_options" do
      case Jido.Chat.Slack.Renderer.options_response(data["result"]) do
        {:ok, response} -> response
        _ -> %{"options" => []}
      end
    end
  end

  defp response_from_result(
         {:ok, %Jido.Signal{type: "jido.chat.operation.failed", data: %{"operation" => "load_options"}}}
       ),
       do: %{"options" => []}

  defp response_from_result(_result), do: nil

  defp normalize_socket_payload(nil), do: nil

  defp normalize_socket_payload(%WebhookResponse{body: body}), do: normalize_socket_payload(body)

  defp normalize_socket_payload(response) when is_map(response) do
    if webhook_response_shape?(response) do
      response
      |> map_get([:body, "body"])
      |> normalize_socket_payload()
    else
      response
    end
  end

  defp normalize_socket_payload(response) when is_binary(response), do: %{"text" => response}
  defp normalize_socket_payload(_response), do: nil

  defp webhook_response_shape?(response) when is_map(response) do
    Enum.any?(
      [:status, "status", :headers, "headers", :body, "body", :metadata, "metadata"],
      fn key ->
        Map.has_key?(response, key)
      end
    )
  end

  defp accepts_response_payload?(envelope) do
    map_get(envelope, [:accepts_response_payload, "accepts_response_payload"]) == true
  end

  defp payload(envelope), do: map_get(envelope, [:payload, "payload"])

  defp envelope_id(envelope), do: map_get(envelope, [:envelope_id, "envelope_id"])

  defp map_get(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn
      key when is_binary(key) ->
        Map.get(map, key) ||
          try do
            Map.get(map, String.to_existing_atom(key))
          rescue
            ArgumentError -> nil
          end

      key when is_atom(key) ->
        Map.get(map, key) || Map.get(map, Atom.to_string(key))

      key ->
        Map.get(map, key)
    end)
  end
end
