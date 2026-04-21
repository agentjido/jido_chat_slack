defmodule Jido.Chat.Slack.Transport.ReqClient do
  @moduledoc """
  Default Slack transport backed by `Req`.
  """

  @behaviour Jido.Chat.Slack.Transport

  alias Jido.Chat.FileUpload

  @base_url "https://slack.com/api"

  @impl true
  def send_message(channel_id, text, opts) do
    payload =
      %{"channel" => stringify(channel_id), "text" => text}
      |> Map.merge(keyword_payload(opts, [:blocks, :attachments, :thread_ts, :reply_broadcast]))
      |> Map.merge(
        keyword_payload(opts, [:unfurl_links, :unfurl_media, :username, :icon_emoji, :icon_url])
      )

    api_post("chat.postMessage", payload, opts)
  end

  @impl true
  def send_file(channel_id, %FileUpload{} = upload, opts) do
    with {:ok, filename, bytes} <- upload_bytes(upload),
         {:ok, upload_url_result} <-
           api_post(
             "files.getUploadURLExternal",
             upload_url_payload(upload, filename, byte_size(bytes)),
             opts
           ),
         upload_url when is_binary(upload_url) <- upload_url_result["upload_url"],
         file_id when is_binary(file_id) <- upload_url_result["file_id"],
         :ok <- upload_external_file(upload_url, bytes, opts),
         {:ok, complete_result} <-
           api_post(
             "files.completeUploadExternal",
             complete_upload_payload(channel_id, file_id, filename, upload, opts),
             opts
           ) do
      {:ok, complete_result}
    else
      nil -> {:error, :invalid_upload_response}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def edit_message(channel_id, message_id, text, opts) do
    payload =
      %{"channel" => stringify(channel_id), "ts" => stringify(message_id), "text" => text}
      |> Map.merge(keyword_payload(opts, [:blocks, :attachments]))

    api_post("chat.update", payload, opts)
  end

  @impl true
  def delete_message(channel_id, message_id, opts) do
    payload = %{"channel" => stringify(channel_id), "ts" => stringify(message_id)}

    case api_post("chat.delete", payload, opts) do
      {:ok, _result} -> {:ok, true}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def fetch_metadata(channel_id, opts) do
    payload =
      %{"channel" => stringify(channel_id)}
      |> maybe_put("include_num_members", Keyword.get(opts, :include_num_members, true))

    with {:ok, result} <- api_post("conversations.info", payload, opts),
         channel when is_map(channel) <- result["channel"] do
      {:ok, channel}
    else
      nil -> {:error, :missing_channel}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def fetch_thread(channel_id, opts) do
    thread_ts = opts[:thread_ts] || opts[:external_thread_id] || opts[:message_id]

    if is_nil(thread_ts) do
      {:error, :missing_thread_ts}
    else
      fetch_messages(channel_id, Keyword.put(opts, :thread_ts, thread_ts))
    end
  end

  @impl true
  def fetch_message(channel_id, message_id, opts) do
    thread_ts = opts[:thread_ts] || opts[:external_thread_id]

    cond do
      not is_nil(thread_ts) ->
        with {:ok, result} <- fetch_messages(channel_id, Keyword.put(opts, :thread_ts, thread_ts)),
             messages when is_list(messages) <- result["messages"],
             message when is_map(message) <-
               Enum.find(messages, &(map_get(&1, ["ts"]) == stringify(message_id))) do
          {:ok, message}
        else
          nil -> {:error, :not_found}
          {:error, _reason} = error -> error
        end

      true ->
        payload = %{
          "channel" => stringify(channel_id),
          "latest" => stringify(message_id),
          "inclusive" => true,
          "limit" => 1
        }

        with {:ok, result} <- api_post("conversations.history", payload, opts),
             [message | _] <- result["messages"] || [] do
          {:ok, message}
        else
          [] -> {:error, :not_found}
          {:error, _reason} = error -> error
        end
    end
  end

  @impl true
  def fetch_messages(channel_id, opts) do
    payload =
      %{"channel" => stringify(channel_id), "limit" => Keyword.get(opts, :limit, 50)}
      |> maybe_put("cursor", opts[:cursor])
      |> maybe_put("inclusive", opts[:inclusive])

    method =
      if opts[:thread_ts] || opts[:external_thread_id] do
        "conversations.replies"
      else
        "conversations.history"
      end

    payload =
      case opts[:thread_ts] || opts[:external_thread_id] do
        nil -> payload
        thread_ts -> Map.put(payload, "ts", stringify(thread_ts))
      end

    api_post(method, payload, opts)
  end

  @impl true
  def fetch_channel_messages(channel_id, opts) do
    fetch_messages(channel_id, Keyword.drop(opts, [:thread_ts, :external_thread_id]))
  end

  @impl true
  def list_threads(channel_id, opts) do
    with {:ok, result} <- fetch_channel_messages(channel_id, opts) do
      messages = result["messages"] || []

      {:ok,
       %{
         "threads" => Enum.filter(messages, &thread_root?/1),
         "response_metadata" => result["response_metadata"] || %{}
       }}
    end
  end

  @impl true
  def add_reaction(channel_id, message_id, emoji, opts) do
    payload = %{
      "channel" => stringify(channel_id),
      "timestamp" => stringify(message_id),
      "name" => normalize_emoji_name(emoji)
    }

    case api_post("reactions.add", payload, opts) do
      {:ok, _result} -> {:ok, true}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def remove_reaction(channel_id, message_id, emoji, opts) do
    payload = %{
      "channel" => stringify(channel_id),
      "timestamp" => stringify(message_id),
      "name" => normalize_emoji_name(emoji)
    }

    case api_post("reactions.remove", payload, opts) do
      {:ok, _result} -> {:ok, true}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def post_ephemeral(channel_id, user_id, text, opts) do
    payload =
      %{
        "channel" => stringify(channel_id),
        "user" => stringify(user_id),
        "text" => text
      }
      |> Map.merge(keyword_payload(opts, [:blocks, :attachments, :thread_ts]))

    api_post("chat.postEphemeral", payload, opts)
  end

  @impl true
  def open_dm(user_id, opts) do
    with {:ok, result} <- api_post("conversations.open", %{"users" => stringify(user_id)}, opts),
         channel when is_map(channel) <- result["channel"],
         id when is_binary(id) <- channel["id"] do
      {:ok, id}
    else
      nil -> {:error, :missing_channel}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def open_modal(trigger_id, payload, opts) when is_binary(trigger_id) and is_map(payload) do
    api_post("views.open", %{"trigger_id" => trigger_id, "view" => payload}, opts)
  end

  defp api_post(method_name, payload, opts) when is_binary(method_name) and is_map(payload) do
    token = resolve_token(opts)
    req_module = Keyword.get(opts, :req, Req)
    url = api_url(method_name, opts)

    request_opts = [
      method: :post,
      url: url,
      headers: [{"authorization", "Bearer #{token}"}] ++ normalize_headers(opts[:headers]),
      form: encode_form(payload)
    ]

    case req_module.request(request_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        normalize_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_response(%{"ok" => true} = body), do: {:ok, body}

  defp normalize_response(%{"ok" => false, "error" => error} = body),
    do: {:error, {:slack_api_error, error, body}}

  defp normalize_response(body) when is_map(body), do: {:ok, body}
  defp normalize_response(other), do: {:error, {:invalid_response, other}}

  defp api_url(method_name, opts) do
    base_url = Keyword.get(opts, :base_url, @base_url)
    String.trim_trailing(base_url, "/") <> "/" <> method_name
  end

  defp resolve_token(opts) do
    Keyword.get(opts, :token) ||
      Application.get_env(:jido_chat_slack, :slack_bot_token) ||
      raise ArgumentError,
            "missing Slack bot token; pass :token option or configure :jido_chat_slack, :slack_bot_token"
  end

  defp upload_bytes(%FileUpload{path: path, filename: filename})
       when is_binary(path) and path != "" do
    resolved_filename = filename || Path.basename(path)

    case File.read(path) do
      {:ok, bytes} when is_binary(bytes) and bytes != "" ->
        {:ok, resolved_filename, bytes}

      {:ok, _bytes} ->
        {:error, :missing_file_source}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_bytes(%FileUpload{data: data, filename: filename})
       when is_binary(data) and data != "" and is_binary(filename) and filename != "" do
    {:ok, filename, data}
  end

  defp upload_bytes(%FileUpload{data: data}) when is_binary(data) and data != "" do
    {:error, :missing_filename}
  end

  defp upload_bytes(%FileUpload{url: url}) when is_binary(url) and url != "" do
    {:error, :unsupported_remote_url}
  end

  defp upload_bytes(_upload), do: {:error, :missing_file_source}

  defp upload_url_payload(upload, filename, length) do
    %{
      "filename" => filename,
      "length" => length
    }
    |> maybe_put("alt_txt", upload_alt_text(upload))
  end

  defp complete_upload_payload(channel_id, file_id, filename, upload, opts) do
    %{
      "files" => [%{"id" => file_id, "title" => upload_title(upload, filename)}],
      "channel_id" => stringify(channel_id)
    }
    |> maybe_put("initial_comment", upload_comment(upload, opts))
    |> maybe_put("thread_ts", opts[:thread_ts] && stringify(opts[:thread_ts]))
  end

  defp upload_external_file(upload_url, bytes, opts) do
    req_module = Keyword.get(opts, :req, Req)

    case req_module.request(
           method: :post,
           url: upload_url,
           headers: [{"content-type", "application/octet-stream"}],
           body: bytes
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_alt_text(%FileUpload{} = upload) do
    metadata = upload.metadata || %{}
    map_get(metadata, [:alt_text, "alt_text"])
  end

  defp upload_title(%FileUpload{} = upload, fallback) do
    metadata = upload.metadata || %{}
    map_get(metadata, [:title, "title"]) || upload.filename || fallback
  end

  defp upload_comment(%FileUpload{} = upload, opts) do
    metadata = upload.metadata || %{}

    Keyword.get(opts, :initial_comment) ||
      Keyword.get(opts, :caption) ||
      Keyword.get(opts, :text) ||
      map_get(metadata, [:caption, "caption"]) ||
      map_get(metadata, [:transcript, "transcript"])
  end

  defp encode_form(payload) do
    Enum.into(payload, %{}, fn {key, value} -> {key, encode_form_value(value)} end)
  end

  defp encode_form_value(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp encode_form_value(true), do: "true"
  defp encode_form_value(false), do: "false"
  defp encode_form_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp encode_form_value(value), do: value

  defp keyword_payload(opts, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Keyword.get(opts, key) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), value)
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_headers(nil), do: []

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp thread_root?(message) when is_map(message) do
    reply_count = map_get(message, ["reply_count"]) || 0
    thread_ts = map_get(message, ["thread_ts"])
    ts = map_get(message, ["ts"])

    reply_count > 0 or (is_binary(thread_ts) and thread_ts == ts)
  end

  defp normalize_emoji_name(":" <> rest) do
    rest
    |> String.trim_trailing(":")
  end

  defp normalize_emoji_name(emoji), do: emoji

  defp map_get(nil, _keys), do: nil

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

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
