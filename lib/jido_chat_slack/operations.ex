defmodule Jido.Chat.Slack.Operations do
  @moduledoc false
  alias Jido.Chat.{Client, Modal}

  alias Jido.Chat.Slack.{
    DeleteOptions,
    EditOptions,
    EphemeralOptions,
    FetchOptions,
    InteractionResponse,
    MetadataOptions,
    ModalOptions,
    ReactionOptions,
    Renderer,
    SendOptions
  }

  alias Jido.Chat.Slack.Transport.ReqClient
  @signature_prefix "v0="

  @doc false
  def send_card(%Client{credentials: %{token: token}} = client, %{data: data}, options)
      when is_binary(token) and token != "" do
    opts = Keyword.merge(Client.options(client), options)
    opts = if data["thread_id"], do: Keyword.put(opts, :thread_ts, data["thread_id"]), else: opts

    with {:ok, rendered} <- Renderer.card(Jido.Chat.Card.new(data["card"])) do
      send_message(data["room_id"], rendered.text, Keyword.put(opts, :blocks, rendered.blocks)) |> classify()
    end
  end

  def send_card(_, _, _), do: {:error, {:not_attempted, :missing_token}}

  @doc false
  def invoke(%Client{credentials: %{token: token}} = client, request, options)
      when is_binary(token) and token != "" do
    opts = Keyword.merge(Client.options(client), options)
    data = request.data

    opts =
      Enum.reduce([:thread_id, :reply_to_id, :cursor, :limit, :direction], opts, fn key, acc ->
        case data[Atom.to_string(key)] do
          nil -> acc
          value -> Keyword.put(acc, key, value)
        end
      end)

    opts =
      if data["thread_id"] || data["reply_to_id"],
        do: Keyword.put(opts, :thread_ts, data["thread_id"] || data["reply_to_id"]),
        else: opts

    opts = if is_binary(data["direction"]), do: Keyword.put(opts, :direction, direction(data["direction"])), else: opts

    case Jido.Chat.Operations.Definitions.lookup(request.type) do
      {_, operation, _, _, _} -> call(operation, client, request, opts) |> classify()
      _ -> {:error, {:not_attempted, :unsupported}}
    end
  end

  def invoke(%Client{}, _request, _options), do: {:error, {:not_attempted, :missing_token}}

  defp direction("backward"), do: :backward
  defp direction(_), do: :forward

  defp call(:send_message, _client, %{data: data}, opts) do
    with {:ok, opts} <- text_options(data, opts), do: send_message(data["room_id"], data["text"], opts)
  end

  defp call(:edit_message, _client, %{data: data}, opts) do
    with {:ok, opts} <- text_options(data, opts),
         do: edit_message(data["room_id"], data["message_id"], data["text"], opts)
  end

  defp call(:send_file, _, %{data: %{"keyboard" => keyboard}}, _) when not is_nil(keyboard),
    do: {:error, {:not_attempted, :unsupported}}

  defp call(:send_file, _, %{data: %{"format" => format}}, _) when format in ["html", "plain"],
    do: {:error, {:not_attempted, :unsupported}}

  defp call(:send_file, client, %{data: data}, opts) do
    with {:ok, upload} <- file_source(client, data["source"], opts) do
      upload = Map.put(upload, :metadata, %{caption: data["caption"]})
      send_file(data["room_id"], upload, opts)
    end
  end

  defp call(:fetch_metadata, _, %{data: data}, opts) do
    with {:ok, result} <- fetch_metadata(data["room_id"], opts), do: {:ok, Map.take(result, ~w(id name kind))}
  end

  defp call(:fetch_thread, _, %{data: data}, opts), do: fetch_thread(data["room_id"], opts)
  defp call(:fetch_message, _, %{data: data}, opts), do: fetch_message(data["room_id"], data["message_id"], opts)

  defp call(:get_user, _, %{data: data}, opts) do
    with {:ok, result} <- get_user(data["user_id"], opts), do: {:ok, canonical_actor(result)}
  end

  defp call(:fetch_subject, _, %{data: data}, opts) do
    with {:ok, result} <- fetch_subject(data["room_id"], opts), do: {:ok, wire(result, ~w(id room_id kind title))}
  end

  defp call(:get_thread_participants, _, %{data: data}, opts) do
    with {:ok, result} <- get_thread_participants(data["room_id"], opts) do
      {:ok,
       %{
         "participants" => Enum.map(result.participants, &canonical_actor/1),
         "complete" => result.complete,
         "scope" => result.scope,
         "next_cursor" => result.next_cursor
       }}
    end
  end

  defp call(:download_file, client, %{data: data}, opts) do
    ref = data["resource_ref"]

    if ref["client_id"] == client.id do
      with {:ok, bytes} <- fetch_media(ref["id"], opts), do: {:ok, %{"content_base64" => Base.encode64(bytes)}}
    else
      {:error, {:not_attempted, :invalid_reference}}
    end
  end

  defp call(operation, _, %{data: data}, opts) when operation in [:delete_message, :mark_as_read] do
    result = apply(__MODULE__, operation, [data["room_id"], data["message_id"], opts])
    acknowledge(result)
  end

  defp call(operation, _, %{data: data}, opts) when operation in [:add_reaction, :remove_reaction] do
    acknowledge(apply(__MODULE__, operation, [data["room_id"], data["message_id"], data["reaction"], opts]))
  end

  defp call(:open_dm, _, %{data: data}, opts) do
    with {:ok, id} <- open_dm(data["user_id"], opts), do: {:ok, %{"id" => id, "kind" => "direct"}}
  end

  defp call(:post_ephemeral, _, %{data: data}, opts) do
    with {:ok, opts} <- text_options(data, opts),
         do: post_ephemeral(data["room_id"], data["user_id"], data["text"], opts)
  end

  defp call(operation, _, %{data: data}, opts) when operation in [:fetch_messages, :list_threads],
    do: apply(__MODULE__, operation, [data["room_id"], opts])

  defp call(:open_modal, _, %{data: data}, opts), do: open_modal(data["room_id"], Modal.new(data["modal"]), opts)

  defp call(:load_options, _, request, opts) do
    with {:ok, result} <- load_options(request, opts), do: {:ok, wire(result, ~w(options option_groups complete))}
  end

  defp call(_, _, _, _), do: {:error, {:not_attempted, :unsupported}}

  defp acknowledge(:ok), do: {:ok, %{"acknowledged" => true}}
  defp acknowledge({:ok, _}), do: {:ok, %{"acknowledged" => true}}
  defp acknowledge(error), do: error
  defp canonical_actor(result), do: wire(result, ~w(id username display_name is_bot is_self))

  defp wire(result, keys) do
    Map.new(keys, fn key -> {key, map_get(result, [key])} end) |> compact() |> string_keys()
  end

  defp string_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), string_keys(item)} end)

  defp string_keys(value) when is_list(value), do: Enum.map(value, &string_keys/1)
  defp string_keys(value), do: value

  defp text_options(data, opts) do
    if data["format"] == "html" do
      {:error, {:not_attempted, :unsupported}}
    else
      opts = Keyword.put(opts, :mrkdwn, data["format"] != "plain")

      case data["keyboard"] do
        nil ->
          {:ok, opts}

        %{"rows" => rows} ->
          text = data["text"] || ""

          prefix =
            if text == "",
              do: [],
              else: [
                %{
                  "type" => "section",
                  "text" => %{
                    "type" => if(data["format"] == "plain", do: "plain_text", else: "mrkdwn"),
                    "text" => text
                  }
                }
              ]

          blocks =
            Enum.with_index(rows, fn row, row_id ->
              %{
                "type" => "actions",
                "elements" =>
                  Enum.with_index(row, fn button, index ->
                    %{
                      "type" => "button",
                      "action_id" => button["value"] || "chat_link_#{row_id}_#{index}",
                      "text" => %{"type" => "plain_text", "text" => button["text"]}
                    }
                    |> Map.merge(Map.take(button, ["value", "url"]))
                  end)
              }
            end)

          {:ok, Keyword.put(opts, :blocks, prefix ++ blocks)}
      end
    end
  end

  defp file_source(_client, %{"content_base64" => content, "filename" => name}, _opts) do
    with {:ok, bytes} <- Base.decode64(content), do: {:ok, %{data: bytes, filename: name}}
  end

  defp file_source(client, %{"client_id" => id} = ref, opts) when id == client.id do
    case opts[:file_resolver] do
      resolver when is_function(resolver, 1) -> resolver.(ref)
      _ -> {:error, {:not_attempted, :unresolved_reference}}
    end
  end

  defp file_source(_, _, _), do: {:error, {:not_attempted, :invalid_reference}}

  defp classify({:error, {:slack_api_error, error, _body}}) do
    category =
      case error do
        value when value in ["invalid_auth", "not_authed", "token_revoked"] -> :unauthorized
        value when value in ["missing_scope", "no_permission", "not_in_channel"] -> :forbidden
        value when value in ["channel_not_found", "message_not_found", "user_not_found"] -> :not_found
        "ratelimited" -> :rate_limited
        _ -> :provider_failure
      end

    {:error, {:rejected, category}}
  end

  defp classify({:error, :not_found}), do: {:error, {:rejected, :not_found}}
  defp classify(result), do: result

  @doc "Runs the Slack send_message provider call with explicit options."
  def send_message(channel_id, text, opts \\ []) do
    opts = SendOptions.new(opts)

    with {:ok, result} <-
           transport(opts).send_message(
             channel_id,
             text,
             SendOptions.transport_opts(opts) ++ payload_to_opts(SendOptions.payload_opts(opts))
           ) do
      {:ok,
       %{
         "id" => stringify(map_get(result, [:ts, "ts"])),
         "room_id" => stringify(map_get(result, [:channel, "channel"]) || channel_id),
         "text" => text,
         "timestamp" => map_get(result, [:ts, "ts"]),
         "status" => "sent",
         "thread_id" => opts.thread_ts
       }
       |> compact()}
    end
  end

  @doc "Runs the Slack send_file provider call with explicit options."
  def send_file(channel_id, file, opts \\ []) do
    upload =
      Map.merge(%{path: nil, data: nil, media_type: nil, filename: nil, url: nil, metadata: %{}, kind: :file}, file)

    raw_opts = opts
    send_opts = SendOptions.new(opts)

    with :ok <- validate_upload(upload),
         {:ok, result} <-
           transport(send_opts).send_file(
             channel_id,
             upload,
             SendOptions.transport_opts(send_opts) ++
               file_transport_opts(raw_opts, send_opts, upload)
           ) do
      {:ok, upload_response(channel_id, upload, result)}
    end
  end

  @doc "Runs the Slack edit_message provider call with explicit options."
  def edit_message(channel_id, message_id, text, opts \\ []) do
    opts = EditOptions.new(opts)

    with {:ok, result} <-
           transport(opts).edit_message(
             channel_id,
             message_id,
             text,
             EditOptions.transport_opts(opts) ++ payload_to_opts(EditOptions.payload_opts(opts))
           ) do
      {:ok,
       %{
         "id" => stringify(map_get(result, [:ts, "ts"]) || message_id),
         "room_id" => stringify(map_get(result, [:channel, "channel"]) || channel_id),
         "text" => text,
         "timestamp" => map_get(result, [:ts, "ts"]),
         "status" => "updated"
       }
       |> compact()}
    end
  end

  @doc "Runs the Slack delete_message provider call with explicit options."
  def delete_message(channel_id, message_id, opts \\ []) do
    opts = opts |> pick_opts([:token, :transport, :req, :base_url]) |> DeleteOptions.new()

    with {:ok, _result} <-
           transport(opts).delete_message(
             channel_id,
             message_id,
             DeleteOptions.transport_opts(opts)
           ) do
      :ok
    end
  end

  @doc "Runs the Slack fetch_metadata provider call with explicit options."
  def fetch_metadata(channel_id, opts \\ []) do
    opts =
      opts |> pick_opts([:token, :transport, :req, :base_url, :include_num_members]) |> MetadataOptions.new()

    with {:ok, result} <-
           transport(opts).fetch_metadata(channel_id, MetadataOptions.transport_opts(opts)) do
      {:ok,
       %{
         "id" => stringify(map_get(result, [:id, "id"]) || channel_id),
         "name" => map_get(result, [:name, "name"]),
         "member_count" => map_get(result, [:num_members, "num_members"]),
         "kind" => if(conversation_is_dm?(result, channel_id), do: "direct", else: "channel")
       }
       |> compact()}
    end
  end

  @doc "Runs the Slack fetch_thread provider call with explicit options."
  def fetch_thread(channel_id, opts \\ []) do
    thread = opts[:thread_id] || opts[:external_thread_id] || opts[:thread_ts] || opts[:message_id]

    with {:ok, info} <- fetch_metadata(channel_id, opts) do
      if thread do
        with {:ok, root} <- fetch_message(channel_id, thread, Keyword.put(opts, :thread_ts, thread)),
             do: {:ok, %{"id" => stringify(thread), "room_id" => stringify(channel_id), "name" => root["text"]}}
      else
        {:ok, %{"id" => stringify(channel_id), "room_id" => stringify(channel_id), "name" => info["name"]}}
      end
    end
  end

  @doc "Runs the Slack fetch_message provider call with explicit options."
  def fetch_message(channel_id, message_id, opts \\ []) do
    selected = pick_opts(opts, [:token, :transport, :req, :base_url, :thread_ts, :external_thread_id, :thread_id])

    with {:ok, raw} when is_map(raw) <- transport(selected).fetch_message(channel_id, message_id, selected),
         do: {:ok, portable_message(raw, channel_id, message_id)}
  end

  @doc "Runs the Slack get_user provider call with explicit options."
  def get_user(user_id, opts \\ []) do
    transport_opts = pick_opts(opts, [:token, :transport, :req, :base_url])

    with {:ok, raw_user} when is_map(raw_user) <-
           transport(transport_opts).get_user(user_id, transport_opts) do
      {:ok, user_info(raw_user, user_id)}
    else
      {:ok, _raw_user} -> {:error, :invalid_user_response}
      {:error, _reason} = error -> error
    end
  end

  @doc "Runs the Slack fetch_subject provider call with explicit options."
  def fetch_subject(channel_id, opts \\ []) do
    transport_opts =
      pick_opts(opts, [
        :token,
        :transport,
        :req,
        :base_url,
        :thread_ts,
        :external_thread_id,
        :message_id,
        :thread_id,
        :include_num_members
      ])
      |> Keyword.put_new(:include_num_members, false)

    thread_ts =
      opts[:thread_id] || opts[:external_thread_id] || opts[:thread_ts] || opts[:message_id]

    with {:ok, channel} <- transport(transport_opts).fetch_metadata(channel_id, transport_opts),
         {:ok, subject} <- build_subject(channel_id, thread_ts, channel, transport_opts) do
      {:ok,
       subject
       |> Map.put(:kind, if(thread_ts, do: "thread", else: "conversation"))
       |> Map.put(:room_id, stringify(channel_id))}
    end
  end

  @doc "Runs the Slack get_thread_participants provider call with explicit options."
  def get_thread_participants(channel_id, opts \\ []) do
    thread_ts =
      opts[:thread_id] || opts[:external_thread_id] || opts[:thread_ts] || opts[:message_id]

    with {:ok, thread_ts} <- require_thread_ts(thread_ts),
         {:ok, limit} <- bounded_positive_integer(opts[:limit], 100, 1_000, :invalid_limit),
         {:ok, page_size} <-
           bounded_positive_integer(opts[:page_size], min(limit, 100), 200, :invalid_page_size),
         {:ok, max_pages} <-
           bounded_positive_integer(opts[:max_pages], 20, 100, :invalid_max_pages),
         {:ok, entries} <-
           collect_participant_entries(
             channel_id,
             thread_ts,
             opts,
             limit,
             page_size,
             max_pages
           ),
         {:ok, users} <- participant_entries_to_users(entries, opts) do
      {:ok, %{participants: users, complete: false, scope: "observed", next_cursor: nil}}
    end
  end

  @doc "Runs the Slack mark_as_read provider call with explicit options."
  def mark_as_read(channel_id, message_id, opts \\ []) do
    transport_opts = pick_opts(opts, [:token, :transport, :req, :base_url])
    transport(transport_opts).mark_as_read(channel_id, message_id, transport_opts)
  end

  @doc "Runs the Slack fetch_media provider call with explicit options."
  def fetch_media(reference, opts \\ []) do
    transport_opts = pick_opts(opts, [:token, :transport, :req, :headers])

    with {:ok, url} <- media_url(reference) do
      transport(transport_opts).download_file(url, transport_opts)
    end
  end

  @doc "Runs the Slack open_dm provider call with explicit options."
  def open_dm(user_id, opts \\ []) do
    transport_opts = pick_opts(opts, [:token, :transport, :req, :base_url])
    transport(transport_opts).open_dm(user_id, transport_opts)
  end

  @doc "Runs the Slack open_thread provider call with explicit options."
  def open_thread(channel_id, message_id, opts \\ []) do
    thread_ts = opts[:thread_ts] || opts[:external_thread_id] || message_id

    {:ok,
     %{
       external_thread_id: stringify(thread_ts),
       delivery_external_room_id: stringify(channel_id)
     }}
  end

  @doc "Runs the Slack post_ephemeral provider call with explicit options."
  def post_ephemeral(channel_id, user_id, text, opts \\ []) do
    opts = EphemeralOptions.new(opts)

    with {:ok, result} <-
           transport(opts).post_ephemeral(
             channel_id,
             user_id,
             text,
             EphemeralOptions.transport_opts(opts) ++ payload_to_opts(EphemeralOptions.payload_opts(opts))
           ) do
      {:ok,
       %{
         "id" => stringify(map_get(result, [:message_ts, "message_ts"])),
         "room_id" => stringify(channel_id),
         "text" => text,
         "status" => "sent"
       }}
    end
  end

  @doc "Runs the Slack open_modal provider call with explicit options."
  def open_modal(_channel_id, %Modal{} = modal, opts \\ []) do
    trigger = opts[:trigger_id] || modal.metadata[:trigger_id] || modal.metadata["trigger_id"]

    opts =
      Keyword.put(opts, :trigger_id, trigger)
      |> pick_opts([:token, :transport, :req, :base_url, :trigger_id])
      |> ModalOptions.new()

    if is_nil(opts.trigger_id) do
      {:error, :missing_trigger_id}
    else
      with {:ok, view_payload} <- Renderer.modal(modal),
           {:ok, result} <- transport(opts).open_modal(opts.trigger_id, view_payload, ModalOptions.transport_opts(opts)) do
        view = map_get(result, [:view, "view"]) || %{}
        id = stringify(map_get(view, [:id, "id"]) || map_get(result, [:view_id, "view_id"]))

        {:ok, %{"opened" => true, "id" => id} |> compact()}
      end
    end
  end

  @doc "Runs the Slack load_options provider call with explicit options."
  def load_options(%Jido.Signal{} = event, opts \\ []) do
    with {:ok, loader} <- options_loader(opts),
         {:ok, result} <- loader |> invoke_options_loader(event, opts) |> normalize_loader_return(),
         {:ok, _wire} <- Renderer.options_response(result) do
      {:ok,
       %{
         options: map_get(result, [:options, "options"]) || [],
         option_groups: map_get(result, [:option_groups, "option_groups"]) || [],
         complete: true
       }}
    end
  end

  @doc "Runs the Slack add_reaction provider call with explicit options."
  def add_reaction(channel_id, message_id, emoji, opts \\ []) do
    opts = opts |> pick_opts([:token, :transport, :req, :base_url]) |> ReactionOptions.new()

    with {:ok, _result} <-
           transport(opts).add_reaction(
             channel_id,
             message_id,
             emoji,
             ReactionOptions.transport_opts(opts)
           ) do
      :ok
    end
  end

  @doc "Runs the Slack remove_reaction provider call with explicit options."
  def remove_reaction(channel_id, message_id, emoji, opts \\ []) do
    opts = opts |> pick_opts([:token, :transport, :req, :base_url]) |> ReactionOptions.new()

    with {:ok, _result} <-
           transport(opts).remove_reaction(
             channel_id,
             message_id,
             emoji,
             ReactionOptions.transport_opts(opts)
           ) do
      :ok
    end
  end

  @doc "Runs the Slack fetch_messages provider call with explicit options."
  def fetch_messages(channel_id, opts \\ []) do
    opts =
      opts
      |> pick_opts([
        :token,
        :transport,
        :req,
        :base_url,
        :cursor,
        :limit,
        :direction,
        :thread_ts,
        :inclusive,
        :external_thread_id
      ])
      |> maybe_put_thread_ts()
      |> FetchOptions.new()

    with :ok <- validate_history_direction(opts.direction),
         {:ok, result} <-
           transport(opts).fetch_messages(channel_id, FetchOptions.transport_opts(opts)),
         entries when is_list(entries) <- map_get(result, [:messages, "messages"]) || [],
         true <- Enum.all?(entries, &is_map/1) do
      thread_ts = opts.thread_ts

      {:ok,
       %{
         "messages" => normalize_messages(entries, channel_id, thread_ts),
         "next_cursor" => next_cursor(result),
         "complete" => map_get(result, [:has_more, "has_more"]) == false or is_nil(next_cursor(result))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_result}
    end
  end

  @doc "Runs the Slack fetch_channel_messages provider call with explicit options."
  def fetch_channel_messages(channel_id, opts \\ []) do
    opts =
      opts
      |> Keyword.drop([:thread_ts, :external_thread_id])

    fetch_messages(channel_id, opts)
  end

  @doc "Runs the Slack list_threads provider call with explicit options."
  def list_threads(channel_id, opts \\ []) do
    fetch_opts =
      opts
      |> pick_opts([:token, :transport, :req, :base_url, :cursor, :limit, :direction])
      |> FetchOptions.new()

    with :ok <- validate_history_direction(fetch_opts.direction),
         {:ok, result} <-
           transport(fetch_opts).list_threads(channel_id, FetchOptions.transport_opts(fetch_opts)),
         entries when is_list(entries) <- map_get(result, [:threads, "threads"]) || [],
         true <- Enum.all?(entries, &is_map/1) do
      threads =
        entries
        |> Enum.flat_map(&normalize_thread_summary(channel_id, &1))

      {:ok,
       %{
         "threads" => threads,
         "next_cursor" => next_cursor(result),
         "complete" => map_get(result, [:has_more, "has_more"]) == false or is_nil(next_cursor(result))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_provider_result}
    end
  end

  def verify_webhook(%{} = request, opts \\ []) do
    signing_secret =
      opts[:signing_secret] || opts[:slack_signing_secret]

    if is_nil(signing_secret) do
      :ok
    else
      verify_slack_signature(request, signing_secret, opts)
    end
  end

  def format_webhook_response(result, opts \\ [])

  def format_webhook_response({:ok, _} = result, opts) do
    request = opts[:request]
    payload = if request, do: request_payload(request), else: %{}

    if url_verification_payload?(payload) do
      Map.new(%{status: 200, body: map_get(payload, [:challenge, "challenge"])})
    else
      InteractionResponse.webhook_response(result, opts) || Map.new(%{status: 200, body: ""})
    end
  end

  def format_webhook_response({:error, reason}, _opts)
      when reason in [:invalid_signature, :stale_timestamp, :missing_signature, :missing_timestamp],
      do: %{status: 401, body: %{error: "invalid_signature"}}

  def format_webhook_response({:error, _}, _opts), do: %{status: 400, body: %{error: "ingress_rejected"}}

  defp verify_slack_signature(request, signing_secret, opts) do
    raw_body = raw_body(request, opts)

    if is_nil(raw_body) do
      {:error, :missing_raw_body}
    else
      timestamp = header_value(request.headers, "x-slack-request-timestamp")
      signature = header_value(request.headers, "x-slack-signature")

      cond do
        is_nil(timestamp) -> {:error, :missing_timestamp}
        is_nil(signature) -> {:error, :missing_signature}
        stale_timestamp?(timestamp, opts) -> {:error, :stale_timestamp}
        secure_compare(signature, slack_signature(signing_secret, timestamp, raw_body)) -> :ok
        true -> {:error, :invalid_signature}
      end
    end
  end

  defp decode_request_payload(%{} = request) do
    request.payload
    |> decode_payload_source()
    |> case do
      {:ok, payload} -> {:ok, payload}
      {:error, _reason} -> decode_payload_source(request[:raw])
    end
  end

  defp decode_payload_source(%{} = payload) do
    case map_get(payload, [:payload, "payload"]) do
      json when is_binary(json) -> Jason.decode(json)
      _ -> {:ok, normalize_struct(payload)}
    end
  end

  defp decode_payload_source(binary) when is_binary(binary) do
    with {:error, _reason} <- Jason.decode(binary) do
      decoded = URI.decode_query(binary)

      case Map.get(decoded, "payload") do
        nil -> {:ok, decoded}
        json -> Jason.decode(json)
      end
    end
  end

  defp decode_payload_source(_), do: {:error, :unsupported_payload}

  defp url_verification_payload?(payload) when is_map(payload) do
    map_get(payload, [:type, "type"]) == "url_verification"
  end

  defp media_url(url) when is_binary(url) and url != "", do: {:ok, url}
  defp media_url(%{url: url}) when is_binary(url) and url != "", do: {:ok, url}
  defp media_url(%{"url" => url}) when is_binary(url) and url != "", do: {:ok, url}
  defp media_url(_reference), do: {:error, :invalid_media_reference}

  defp message_text(message) do
    case map_get(message, [:text, "text"]) do
      text when is_binary(text) and text != "" -> text
      _ -> initial_file_comment(message)
    end
  end

  defp initial_file_comment(message) do
    message
    |> map_get([:files, "files"])
    |> List.wrap()
    |> Enum.find_value(fn file ->
      case map_get(file, [:initial_comment, "initial_comment"]) do
        comment when is_binary(comment) and comment != "" ->
          comment

        comment when is_map(comment) ->
          case map_get(comment, [:comment, "comment", :text, "text"]) do
            text when is_binary(text) and text != "" -> text
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp first_non_blank(values), do: Enum.find_value(values, &blank_to_nil/1)

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  defp normalize_messages(messages, room, thread) when is_list(messages) do
    Enum.map(messages, fn message ->
      portable_message(message, room)
      |> Map.put_new("thread_id", stringify(thread || external_thread_id(message)))
      |> compact()
    end)
  end

  defp portable_message(message, room, fallback_id \\ nil) do
    %{
      "id" => stringify(map_get(message, [:ts, "ts"]) || fallback_id),
      "room_id" => stringify(map_get(message, [:channel, "channel"]) || room),
      "text" => message_text(message),
      "thread_id" => external_thread_id(message),
      "timestamp" => map_get(message, [:ts, "ts"])
    }
    |> compact()
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp build_subject(channel_id, nil, channel, _transport_opts) do
    channel = normalize_struct(channel)

    {:ok,
     Map.new(%{
       type: "slack_channel",
       id: stringify(channel_id),
       title: channel_subject_title(channel),
       status: conversation_status(channel),
       metadata: subject_metadata(channel_id, nil, channel)
     })}
  end

  defp build_subject(channel_id, thread_ts, channel, transport_opts) do
    with {:ok, root} <-
           transport(transport_opts).fetch_message(
             channel_id,
             thread_ts,
             transport_opts
             |> Keyword.put(:thread_ts, thread_ts)
             |> Keyword.put(:limit, 1)
           ),
         {:ok, permalink} <-
           transport(transport_opts).get_permalink(channel_id, thread_ts, transport_opts) do
      channel = normalize_struct(channel)
      root = normalize_struct(root)

      {:ok,
       Map.new(%{
         type: "slack_thread",
         id: stringify(thread_ts),
         title: first_non_blank([message_text(root), channel_subject_title(channel)]),
         url: permalink,
         status: conversation_status(channel),
         metadata: subject_metadata(channel_id, thread_ts, channel)
       })}
    end
  end

  defp channel_subject_title(channel) do
    first_non_blank([
      channel |> map_get([:topic, "topic"]) |> maybe_get([:value, "value"]),
      channel |> map_get([:purpose, "purpose"]) |> maybe_get([:value, "value"]),
      map_get(channel, [:name, "name"])
    ])
  end

  defp conversation_status(channel) do
    if map_get(channel, [:is_archived, "is_archived"]), do: "archived", else: "open"
  end

  defp subject_metadata(channel_id, thread_ts, channel) do
    %{
      provider: :slack,
      channel_id: stringify(channel_id),
      thread_ts: stringify(thread_ts),
      channel_name: map_get(channel, [:name, "name"]),
      topic: channel |> map_get([:topic, "topic"]) |> maybe_get([:value, "value"]),
      purpose: channel |> map_get([:purpose, "purpose"]) |> maybe_get([:value, "value"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp collect_participant_entries(channel_id, thread_ts, opts, limit, page_size, max_pages) do
    transport_opts = pick_opts(opts, [:token, :transport, :req, :base_url])

    state = %{
      limit: limit,
      page_size: page_size,
      max_pages: max_pages,
      cursor: nil,
      page_count: 0,
      seen: MapSet.new(),
      entries: [],
      entry_count: 0
    }

    collect_participant_entries(channel_id, thread_ts, transport_opts, state)
  end

  defp collect_participant_entries(
         _channel_id,
         _thread_ts,
         _transport_opts,
         %{entry_count: count, limit: limit, entries: entries}
       )
       when count >= limit,
       do: {:ok, Enum.reverse(entries)}

  defp collect_participant_entries(
         _channel_id,
         _thread_ts,
         _transport_opts,
         %{page_count: page_count, max_pages: max_pages, cursor: cursor}
       )
       when page_count >= max_pages and not is_nil(cursor),
       do: {:error, :participant_page_limit_exceeded}

  defp collect_participant_entries(channel_id, thread_ts, transport_opts, state) do
    page_opts =
      transport_opts
      |> Keyword.put(:thread_ts, thread_ts)
      |> Keyword.put(:limit, state.page_size)
      |> maybe_put_kw(:cursor, state.cursor)

    with {:ok, result} <- transport(transport_opts).fetch_messages(channel_id, page_opts) do
      state =
        result
        |> map_get([:messages, "messages"])
        |> List.wrap()
        |> Enum.reduce_while(state, fn message, state ->
          case participant_entry(message) do
            nil ->
              {:cont, state}

            {key, entry} ->
              cond do
                MapSet.member?(state.seen, key) ->
                  {:cont, state}

                state.entry_count + 1 >= state.limit ->
                  {:halt, add_participant_entry(state, key, entry)}

                true ->
                  {:cont, add_participant_entry(state, key, entry)}
              end
          end
        end)

      next_cursor = next_cursor(result) |> blank_to_nil()

      if is_nil(next_cursor) do
        {:ok, Enum.reverse(state.entries)}
      else
        collect_participant_entries(
          channel_id,
          thread_ts,
          transport_opts,
          %{state | cursor: next_cursor, page_count: state.page_count + 1}
        )
      end
    end
  end

  defp add_participant_entry(state, key, entry) do
    %{
      state
      | seen: MapSet.put(state.seen, key),
        entries: [entry | state.entries],
        entry_count: state.entry_count + 1
    }
  end

  defp participant_entry(message) when is_map(message) do
    case map_get(message, [:user, "user"]) |> blank_to_nil() do
      user_id when is_binary(user_id) ->
        {{:user, user_id}, {:user, user_id}}

      nil ->
        case map_get(message, [:bot_id, "bot_id"]) |> blank_to_nil() do
          bot_id when is_binary(bot_id) -> {{:bot, bot_id}, {:bot, bot_user_info(bot_id, message)}}
          nil -> nil
        end
    end
  end

  defp participant_entry(_message), do: nil

  defp participant_entries_to_users(entries, opts) do
    transport_opts = pick_opts(opts, [:token, :transport, :req, :base_url])

    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, users} ->
      case user_from_entry(entry, transport_opts) do
        {:ok, user} -> {:cont, {:ok, [user | users]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, users} -> {:ok, Enum.reverse(users)}
      {:error, _reason} = error -> error
    end
  end

  defp user_from_entry({:user, user_id}, transport_opts) do
    get_user(user_id, transport_opts)
  end

  defp user_from_entry({:bot, user}, _transport_opts), do: {:ok, user}

  defp bot_user_info(bot_id, message) do
    profile = map_get(message, [:bot_profile, "bot_profile"]) || %{}
    icons = map_get(profile, [:icons, "icons"]) || %{}

    Map.new(%{
      id: bot_id,
      username: map_get(message, [:username, "username"]) || map_get(profile, [:name, "name"]),
      display_name: map_get(profile, [:name, "name"]),
      avatar_url:
        first_non_blank([
          map_get(icons, [:image_512, "image_512"]),
          map_get(icons, [:image_192, "image_192"]),
          map_get(icons, [:image_72, "image_72"])
        ]),
      is_bot: true,
      metadata: %{provider: :slack, bot_id: bot_id}
    })
  end

  defp user_info(raw_user, fallback_id) do
    raw_user = normalize_struct(raw_user)
    profile = map_get(raw_user, [:profile, "profile"]) || %{}

    Map.new(%{
      id: stringify(map_get(raw_user, [:id, "id"]) || fallback_id),
      username: map_get(raw_user, [:name, "name"]),
      display_name:
        first_non_blank([
          map_get(profile, [:display_name, "display_name"]),
          map_get(profile, [:real_name, "real_name"]),
          map_get(raw_user, [:real_name, "real_name"])
        ]),
      email: map_get(profile, [:email, "email"]),
      avatar_url:
        first_non_blank([
          map_get(profile, [:image_original, "image_original"]),
          map_get(profile, [:image_512, "image_512"]),
          map_get(profile, [:image_192, "image_192"]),
          map_get(profile, [:image_72, "image_72"])
        ]),
      is_bot:
        map_get(raw_user, [:is_bot, "is_bot"]) ||
          map_get(raw_user, [:is_app_user, "is_app_user"]) || false,
      metadata:
        %{
          provider: :slack,
          team_id: map_get(raw_user, [:team_id, "team_id"]),
          deleted: map_get(raw_user, [:deleted, "deleted"]),
          timezone: map_get(raw_user, [:tz, "tz"]),
          is_admin: map_get(raw_user, [:is_admin, "is_admin"]),
          is_owner: map_get(raw_user, [:is_owner, "is_owner"])
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    })
  end

  defp require_thread_ts(nil), do: {:error, :missing_thread_ts}
  defp require_thread_ts(thread_ts), do: {:ok, thread_ts}

  defp bounded_positive_integer(nil, default, _maximum, _error), do: {:ok, default}

  defp bounded_positive_integer(value, _default, maximum, _error)
       when is_integer(value) and value > 0 and value <= maximum,
       do: {:ok, value}

  defp bounded_positive_integer(_value, _default, _maximum, error), do: {:error, error}

  defp validate_upload(%{path: path}) when is_binary(path) and path != "", do: :ok

  defp validate_upload(%{data: data, filename: filename})
       when is_binary(data) and data != "" and is_binary(filename) and filename != "" do
    :ok
  end

  defp validate_upload(%{data: data}) when is_binary(data) and data != "" do
    {:error, :missing_filename}
  end

  defp validate_upload(%{url: url}) when is_binary(url) and url != "" do
    {:error, :unsupported_remote_url}
  end

  defp validate_upload(_upload), do: {:error, :missing_file_source}

  defp file_transport_opts(raw_opts, %SendOptions{} = opts, %{} = upload) do
    []
    |> maybe_put_kw(:thread_ts, opts.thread_ts)
    |> maybe_put_kw(:initial_comment, upload_initial_comment(raw_opts, upload))
  end

  defp upload_initial_comment(raw_opts, %{} = upload) do
    metadata = upload.metadata

    Keyword.get(raw_opts, :initial_comment) ||
      Keyword.get(raw_opts, :caption) ||
      Keyword.get(raw_opts, :text) ||
      map_get(metadata, [:caption, "caption"]) ||
      map_get(metadata, [:transcript, "transcript"])
  end

  defp upload_response(channel_id, %{} = upload, result) do
    file = result |> map_get([:files, "files"]) |> List.wrap() |> List.first() |> normalize_struct()
    timestamp = slack_file_share_ts(file, channel_id)

    %{
      "id" => timestamp,
      "room_id" => stringify(channel_id),
      "timestamp" => timestamp,
      "status" => "sent",
      "text" => upload.metadata[:caption] || upload.metadata["caption"],
      "thread_id" => map_get(result, [:thread_ts, "thread_ts"])
    }
    |> compact()
  end

  defp slack_file_share_ts(file, channel_id) when is_map(file) do
    shares = map_get(file, [:shares, "shares"]) |> normalize_struct()
    channel_id = stringify(channel_id)

    [
      maybe_get(shares, [:public, "public"]),
      maybe_get(shares, [:private, "private"])
    ]
    |> Enum.find_value(fn share_group ->
      share_group
      |> normalize_struct()
      |> Map.get(channel_id, [])
      |> List.wrap()
      |> List.first()
      |> maybe_get([:ts, "ts"])
    end)
  end

  defp slack_file_share_ts(_file, _channel_id), do: nil

  defp maybe_put_kw(keyword, _key, nil), do: keyword
  defp maybe_put_kw(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp normalize_thread_summary(channel_id, raw) when is_map(raw) do
    id = map_get(raw, [:thread_ts, "thread_ts", :ts, "ts"])
    [%{"id" => stringify(id), "room_id" => stringify(channel_id), "name" => message_text(raw)} |> compact()]
  end

  defp normalize_thread_summary(_channel_id, _raw), do: []

  defp external_thread_id(message) when is_map(message) do
    thread_ts = map_get(message, [:thread_ts, "thread_ts"])
    ts = map_get(message, [:ts, "ts"])
    reply_count = map_get(message, [:reply_count, "reply_count"]) || 0

    cond do
      is_binary(thread_ts) -> thread_ts
      reply_count > 0 -> ts
      true -> nil
    end
  end

  defp infer_chat_type_from_channel_id("D" <> _rest), do: :dm
  defp infer_chat_type_from_channel_id("G" <> _rest), do: :group
  defp infer_chat_type_from_channel_id("C" <> _rest), do: :channel
  defp infer_chat_type_from_channel_id(_), do: :channel

  defp conversation_is_dm?(metadata, channel_id) do
    map_get(metadata, [:is_im, "is_im"]) ||
      infer_chat_type_from_channel_id(stringify(channel_id)) == :dm
  end

  defp validate_history_direction(:backward), do: :ok
  defp validate_history_direction(_direction), do: {:error, :unsupported_direction}

  defp options_loader(opts) do
    case opts[:options_loader] do
      loader when is_function(loader, 1) or is_function(loader, 2) -> {:ok, loader}
      {module, function, args} = loader when is_atom(module) and is_atom(function) and is_list(args) -> {:ok, loader}
      _ -> {:error, :unsupported}
    end
  end

  defp invoke_options_loader(loader, event, _opts) when is_function(loader, 1),
    do: loader.(event)

  defp invoke_options_loader(loader, event, opts) when is_function(loader, 2),
    do: loader.(event, opts)

  defp invoke_options_loader({module, function, args}, event, _opts),
    do: apply(module, function, args ++ [event])

  defp normalize_loader_return({:ok, result}), do: {:ok, result}
  defp normalize_loader_return({:error, reason}), do: {:error, reason}
  defp normalize_loader_return(result) when is_map(result), do: {:ok, result}
  defp normalize_loader_return(other), do: {:error, {:invalid_options_loader_result, other}}

  defp request_payload(%{} = request) do
    case decode_request_payload(request) do
      {:ok, payload} -> payload
      _ -> %{}
    end
  end

  defp raw_body(request, opts) do
    cond do
      is_binary(opts[:raw_body]) -> opts[:raw_body]
      is_binary(get_in(request, [:metadata, :raw_body])) -> get_in(request, [:metadata, :raw_body])
      is_binary(request[:raw]) -> request[:raw]
      true -> nil
    end
  end

  defp stale_timestamp?(timestamp, opts) do
    with {ts, ""} <- Integer.parse(to_string(timestamp)) do
      now = opts[:now] || System.os_time(:second)
      abs(now - ts) > 300
    else
      _ -> true
    end
  end

  defp slack_signature(signing_secret, timestamp, raw_body) do
    ("v0:" <> to_string(timestamp) <> ":" <> raw_body)
    |> then(&:crypto.mac(:hmac, :sha256, signing_secret, &1))
    |> Base.encode16(case: :lower)
    |> then(&(@signature_prefix <> &1))
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    if byte_size(left) == byte_size(right) do
      left
      |> :binary.bin_to_list()
      |> Enum.zip(:binary.bin_to_list(right))
      |> Enum.reduce(0, fn {a, b}, acc ->
        Bitwise.bor(acc, Bitwise.bxor(a, b))
      end)
      |> Kernel.==(0)
    else
      false
    end
  end

  defp payload_to_opts(payload) when is_map(payload) do
    Enum.map(payload, fn
      {"mrkdwn", value} -> {:mrkdwn, value}
      {"blocks", value} -> {:blocks, value}
      {"attachments", value} -> {:attachments, value}
      {"thread_ts", value} -> {:thread_ts, value}
      {"reply_broadcast", value} -> {:reply_broadcast, value}
      {"unfurl_links", value} -> {:unfurl_links, value}
      {"unfurl_media", value} -> {:unfurl_media, value}
      {"username", value} -> {:username, value}
      {"icon_emoji", value} -> {:icon_emoji, value}
      {"icon_url", value} -> {:icon_url, value}
      {key, value} when is_atom(key) -> {key, value}
    end)
  end

  defp header_value(headers, header_name) when is_map(headers) or is_list(headers) do
    target = String.downcase(header_name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == target, do: to_string(value), else: nil
    end)
  end

  defp next_cursor(result) when is_map(result) do
    result
    |> map_get([:response_metadata, "response_metadata"])
    |> maybe_get([:next_cursor, "next_cursor"])
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp maybe_put_thread_ts(opts) when is_list(opts) do
    case Keyword.get(opts, :external_thread_id) do
      nil -> opts
      thread_ts -> Keyword.put_new(opts, :thread_ts, thread_ts)
    end
  end

  defp transport(%{transport: transport}) when not is_nil(transport), do: transport
  defp transport(opts) when is_list(opts), do: Keyword.get(opts, :transport, ReqClient)
  defp transport(_opts), do: ReqClient

  defp normalize_struct(%_{} = struct), do: struct |> Map.from_struct() |> normalize_struct()

  defp normalize_struct(map) when is_map(map),
    do: Enum.into(map, %{}, fn {k, v} -> {k, normalize_value(v)} end)

  defp normalize_struct(other), do: other

  defp normalize_value(%_{} = struct), do: normalize_struct(struct)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(other), do: other

  defp pick_opts(opts, allowed_keys) when is_list(opts), do: Keyword.take(opts, allowed_keys)

  defp map_get(nil, _keys), do: nil

  defp map_get(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, nil, fn key, _ ->
      alternate = if is_atom(key), do: Atom.to_string(key), else: existing_atom(key)

      case Map.fetch(map, key) do
        {:ok, value} when not is_nil(value) ->
          {:halt, value}

        _ ->
          case Map.fetch(map, alternate) do
            {:ok, value} when not is_nil(value) -> {:halt, value}
            _ -> {:cont, nil}
          end
      end
    end)
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp maybe_get(nil, _keys), do: nil
  defp maybe_get(map, keys) when is_map(map), do: map_get(map, keys)
  defp maybe_get(_other, _keys), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
