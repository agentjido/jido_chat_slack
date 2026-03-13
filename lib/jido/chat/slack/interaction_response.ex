defmodule Jido.Chat.Slack.InteractionResponse do
  @moduledoc false

  alias Jido.Chat.{EventEnvelope, WebhookResponse}

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

  defp default_response_value(%{mode: :webhook, result: {:ok, chat, event}}) do
    response_from_chat(chat) || response_from_event(event)
  end

  defp default_response_value(%{mode: :socket_mode, sink_result: sink_result}) do
    response_from_sink_result(sink_result)
  end

  defp default_response_value(_context), do: nil

  defp response_from_sink_result({:reply, response}), do: response
  defp response_from_sink_result({:ok, {:reply, response}}), do: response

  defp response_from_sink_result({:ok, {:event, %EventEnvelope{} = event}}),
    do: response_from_event(event)

  defp response_from_sink_result({:ok, {:duplicate, %EventEnvelope{} = event}}),
    do: response_from_event(event)

  defp response_from_sink_result({:ok, {:message, _message, _context, %EventEnvelope{} = event}}),
    do: response_from_event(event)

  defp response_from_sink_result(_result), do: nil

  defp response_from_chat(%{metadata: metadata}) when is_map(metadata) do
    map_get(metadata, [:slack_response, "slack_response", :response_payload, "response_payload"])
  end

  defp response_from_chat(_chat), do: nil

  defp response_from_event(%EventEnvelope{} = event) do
    response_from_metadata(event.metadata) ||
      response_from_payload(event.payload)
  end

  defp response_from_event(_event), do: nil

  defp response_from_payload(%{metadata: metadata}) when is_map(metadata),
    do: response_from_metadata(metadata)

  defp response_from_payload(payload) when is_map(payload), do: response_from_metadata(payload)
  defp response_from_payload(_payload), do: nil

  defp response_from_metadata(metadata) when is_map(metadata) do
    map_get(metadata, [:slack_response, "slack_response", :response_payload, "response_payload"])
  end

  defp response_from_metadata(_metadata), do: nil

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

  defp webhook_response_shape?(_response), do: false

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
