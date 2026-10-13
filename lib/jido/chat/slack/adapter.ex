defmodule Jido.Chat.Slack.Adapter do
  @moduledoc """
  Slack `Jido.Chat.Adapter` implementation using Slack Web API with webhook or
  Socket Mode ingress.
  """

  use Jido.Chat.Adapter

  alias Jido.Chat.{
    Binding,
    FileUpload,
    Media,
    MessageSubject,
    Modal,
    PostPayload,
    UserInfo,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.Slack.{
    DeleteOptions,
    EditOptions,
    EphemeralOptions,
    FetchOptions,
    InteractionResponse,
    MetadataOptions,
    Normalizer,
    ModalOptions,
    ReactionOptions,
    Renderer,
    SocketModeWorker,
    SendOptions
  }

  alias Jido.Chat.Slack.Transport.ReqClient

  @signature_prefix "v0="

  @impl true
  def channel_type, do: :slack

  @impl true
  @spec capabilities() :: map()
  def capabilities,
    do: %{
      initialize: :fallback,
      shutdown: :fallback,
      send_message: :native,
      send_file: :native,
      edit_message: :native,
      delete_message: :native,
      start_typing: :unsupported,
      fetch_metadata: :native,
      fetch_thread: :native,
      fetch_message: :native,
      get_user: :native,
      fetch_subject: :native,
      get_thread_participants: :native,
      mark_as_read: :native,
      fetch_media: :native,
      add_reaction: :native,
      remove_reaction: :native,
      post_ephemeral: :native,
      open_dm: :native,
      fetch_messages: :native,
      fetch_channel_messages: :native,
      list_threads: :native,
      open_thread: :native,
      post_channel_message: :fallback,
      post_message: :native,
      stream: :fallback,
      open_modal: :native,
      load_options: :native,
      webhook: :native,
      verify_webhook: :native,
      normalize_event: :native,
      membership: :native,
      format_webhook_response: :native,
      markdown: :native,
      cards: :native,
      card_charts: :fallback,
      card_tables: :native,
      link_action_ids: :native,
      modals: :native,
      modal_date_input: :native,
      modal_number_input: :native,
      external_select: :native,
      options_load: :native
    }

  @impl true
  def signal_protocol, do: 1

  @impl true
  def configure_binding(opts) do
    credentials = opts[:credentials] || %{}
    ingress = normalize_ingress_opts(opts)

    token =
      opts[:token] || map_get(credentials, [:token, "token", :bot_token, "bot_token"]) ||
        Application.get_env(:jido_chat_slack, :slack_bot_token)

    captured =
      opts
      |> Keyword.put(:token, token)
      |> Keyword.put(:transport, opts[:transport] || ReqClient)
      |> Keyword.put(
        :signing_secret,
        opts[:signing_secret] || map_get(credentials, [:signing_secret, "signing_secret"]) ||
          Application.get_env(:jido_chat_slack, :slack_signing_secret)
      )
      |> Keyword.put(
        :app_token,
        opts[:app_token] || map_get(ingress, [:app_token, "app_token"]) ||
          map_get(credentials, [:app_token, "app_token"]) || Application.get_env(:jido_chat_slack, :slack_app_token)
      )
      |> Keyword.put(:options_loader, opts[:options_loader] || Application.get_env(:jido_chat_slack, :options_loader))
      |> Keyword.put(:ingress, ingress)

    if is_binary(token) and token != "", do: {:ok, captured}, else: {:error, :missing_token}
  end

  @impl true
  def normalize_event(%Binding{} = binding, input), do: Normalizer.normalize(binding, input)

  @impl true
  def listener_child_specs(bridge_id, opts \\ [])
      when is_binary(bridge_id) and is_list(opts) do
    ingress = normalize_ingress_opts(opts)

    case ingress_mode(ingress) do
      :webhook ->
        {:ok, []}

      :socket_mode ->
        with %Binding{} = binding <- Keyword.get(opts, :binding),
             {:ok, sink_mfa} <- validate_sink_mfa(Keyword.get(opts, :sink_mfa)) do
          {:ok,
           [
             Supervisor.child_spec(
               {SocketModeWorker,
                socket_mode_worker_opts(bridge_id, ingress, binding.options, sink_mfa) |> Keyword.put(:binding, binding)},
               id: {:slack_socket_mode_worker, bridge_id}
             )
           ]}
        else
          nil -> {:error, :invalid_binding}
          {:error, _} = error -> error
        end

      :invalid ->
        {:error, :invalid_ingress_mode}
    end
  end

  @impl true
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
         "status" => "sent"
       }
       |> compact()}
    end
  end

  @impl true
  def post_message(channel_id, payload, opts \\ []) do
    payload = PostPayload.new(payload)
    uploads = PostPayload.upload_candidates(payload)

    cond do
      uploads == [] and payload.kind == :card ->
        with {:ok, rendered} <- Renderer.card(payload.card) do
          send_message(channel_id, rendered.text, Keyword.put(opts, :blocks, rendered.blocks))
        end

      uploads == [] ->
        send_message(channel_id, PostPayload.display_text(payload) || "", opts)

      match?([_single], uploads) ->
        [upload] = uploads

        file_opts = maybe_put_initial_comment(opts, PostPayload.display_text(payload))

        send_file(channel_id, upload, file_opts)

      true ->
        {:error, :multiple_attachments_unsupported}
    end
  end

  @impl true
  def send_file(channel_id, file, opts \\ []) do
    upload = FileUpload.normalize(file)
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

  @impl true
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

  @impl true
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

  @impl true
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

  @impl true
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

  @impl true
  def fetch_message(channel_id, message_id, opts \\ []) do
    selected = pick_opts(opts, [:token, :transport, :req, :base_url, :thread_ts, :external_thread_id, :thread_id])

    with {:ok, raw} when is_map(raw) <- transport(selected).fetch_message(channel_id, message_id, selected),
         do: {:ok, portable_message(raw, channel_id, message_id)}
  end

  @impl true
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

  @impl true
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

    with {:ok, channel} <- transport(transport_opts).fetch_metadata(channel_id, transport_opts) do
      build_subject(channel_id, thread_ts, channel, transport_opts)
    end
  end

  @impl true
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

  @impl true
  def mark_as_read(channel_id, message_id, opts \\ []) do
    transport_opts = pick_opts(opts, [:token, :transport, :req, :base_url])
    transport(transport_opts).mark_as_read(channel_id, message_id, transport_opts)
  end

  @impl true
  def fetch_media(reference, opts \\ []) do
    transport_opts = pick_opts(opts, [:token, :transport, :req, :headers])

    with {:ok, url} <- media_url(reference) do
      transport(transport_opts).download_file(url, transport_opts)
    end
  end

  @impl true
  def open_dm(user_id, opts \\ []) do
    transport_opts = pick_opts(opts, [:token, :transport, :req, :base_url])
    transport(transport_opts).open_dm(user_id, transport_opts)
  end

  @impl true
  def open_thread(channel_id, message_id, opts \\ []) do
    thread_ts = opts[:thread_ts] || opts[:external_thread_id] || message_id

    {:ok,
     %{
       external_thread_id: stringify(thread_ts),
       delivery_external_room_id: stringify(channel_id)
     }}
  end

  @impl true
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

  @impl true
  def open_modal(channel_id, %Modal{} = modal, opts \\ []) do
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

        if owner = modal.metadata[:binding_owner],
          do: :ets.insert(owner.resources, {{:slack_view_room, id}, channel_id})

        {:ok, %{"opened" => true, "id" => id} |> compact()}
      end
    end
  end

  @doc false
  def prepare_modal(%Binding{} = binding, interaction_id, modal) do
    with {:ok, controls} <- Normalizer.interaction(binding, interaction_id),
         trigger when is_binary(trigger) <- controls["trigger_id"] do
      modal = Modal.new(modal)
      metadata = modal.metadata |> Map.put(:trigger_id, trigger) |> Map.put(:binding_owner, binding)
      Jido.Chat.put_resource(binding, "modal", %{modal | metadata: metadata})
    else
      {:error, _} = error -> error
      _ -> Jido.Chat.Signal.Policy.error(:invalid_resource)
    end
  end

  @impl true
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

  @impl true
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

  @impl true
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

  @impl true
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
           transport(opts).fetch_messages(channel_id, FetchOptions.transport_opts(opts)) do
      thread_ts = opts.thread_ts

      {:ok,
       %{
         "messages" => normalize_messages(map_get(result, [:messages, "messages"]) || [], channel_id, thread_ts),
         "next_cursor" => next_cursor(result),
         "complete" => map_get(result, [:has_more, "has_more"]) == false or is_nil(next_cursor(result))
       }}
    end
  end

  @impl true
  def fetch_channel_messages(channel_id, opts \\ []) do
    opts =
      opts
      |> Keyword.drop([:thread_ts, :external_thread_id])

    fetch_messages(channel_id, opts)
  end

  @impl true
  def list_threads(channel_id, opts \\ []) do
    fetch_opts =
      opts
      |> pick_opts([:token, :transport, :req, :base_url, :cursor, :limit, :direction])
      |> FetchOptions.new()

    with :ok <- validate_history_direction(fetch_opts.direction),
         {:ok, result} <-
           transport(fetch_opts).list_threads(channel_id, FetchOptions.transport_opts(fetch_opts)) do
      threads =
        result
        |> map_get([:threads, "threads"])
        |> List.wrap()
        |> Enum.flat_map(&normalize_thread_summary(channel_id, &1))

      {:ok,
       %{
         "threads" => threads,
         "next_cursor" => next_cursor(result),
         "complete" => map_get(result, [:has_more, "has_more"]) == false or is_nil(next_cursor(result))
       }}
    end
  end

  @impl true
  def verify_webhook(%WebhookRequest{} = request, opts \\ []) do
    signing_secret =
      opts[:signing_secret] || opts[:slack_signing_secret]

    if is_nil(signing_secret) do
      :ok
    else
      verify_slack_signature(request, signing_secret, opts)
    end
  end

  @impl true
  def format_webhook_response(result, opts \\ [])

  def format_webhook_response({:ok, _} = result, opts) do
    request = opts[:request]
    payload = if request, do: request_payload(request), else: %{}

    if url_verification_payload?(payload) do
      WebhookResponse.new(%{status: 200, body: map_get(payload, [:challenge, "challenge"])})
    else
      InteractionResponse.webhook_response(result, opts) || WebhookResponse.new(%{status: 200, body: ""})
    end
  end

  def format_webhook_response({:error, reason}, _opts)
      when reason in [:invalid_signature, :stale_timestamp, :missing_signature, :missing_timestamp],
      do: WebhookResponse.error(401, %{error: "invalid_signature"})

  def format_webhook_response({:error, _}, _opts), do: WebhookResponse.error(400, %{error: "ingress_rejected"})

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

  defp decode_request_payload(%WebhookRequest{} = request) do
    request.payload
    |> decode_payload_source()
    |> case do
      {:ok, payload} -> {:ok, payload}
      {:error, _reason} -> decode_payload_source(request.raw)
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
  defp media_url(%Media{url: url}) when is_binary(url) and url != "", do: {:ok, url}
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
     MessageSubject.new(%{
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
       MessageSubject.new(%{
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

    UserInfo.new(%{
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

    UserInfo.new(%{
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

  defp validate_upload(%FileUpload{path: path}) when is_binary(path) and path != "", do: :ok

  defp validate_upload(%FileUpload{data: data, filename: filename})
       when is_binary(data) and data != "" and is_binary(filename) and filename != "" do
    :ok
  end

  defp validate_upload(%FileUpload{data: data}) when is_binary(data) and data != "" do
    {:error, :missing_filename}
  end

  defp validate_upload(%FileUpload{url: url}) when is_binary(url) and url != "" do
    {:error, :unsupported_remote_url}
  end

  defp validate_upload(_upload), do: {:error, :missing_file_source}

  defp file_transport_opts(raw_opts, %SendOptions{} = opts, %FileUpload{} = upload) do
    []
    |> maybe_put_kw(:thread_ts, opts.thread_ts)
    |> maybe_put_kw(:initial_comment, upload_initial_comment(raw_opts, upload))
  end

  defp upload_initial_comment(raw_opts, %FileUpload{} = upload) do
    metadata = upload.metadata

    Keyword.get(raw_opts, :initial_comment) ||
      Keyword.get(raw_opts, :caption) ||
      Keyword.get(raw_opts, :text) ||
      map_get(metadata, [:caption, "caption"]) ||
      map_get(metadata, [:transcript, "transcript"])
  end

  defp upload_response(channel_id, %FileUpload{} = upload, result) do
    file = result |> map_get([:files, "files"]) |> List.wrap() |> List.first() |> normalize_struct()
    timestamp = slack_file_share_ts(file, channel_id)

    %{
      "id" => timestamp,
      "room_id" => stringify(channel_id),
      "timestamp" => timestamp,
      "status" => "sent",
      "text" => upload.metadata[:caption] || upload.metadata["caption"],
      "metadata" => %{
        file_id: map_get(file, [:id, "id"]),
        filename: map_get(file, [:name, "name"]),
        content_type: map_get(file, [:mimetype, "mimetype"]),
        upload_kind: upload.kind,
        delivered_kind: upload.kind
      }
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

  defp maybe_put_initial_comment(opts, nil), do: opts

  defp maybe_put_initial_comment(opts, text),
    do: Keyword.put_new(opts, :initial_comment, text)

  defp request_payload(%WebhookRequest{} = request) do
    case decode_request_payload(request) do
      {:ok, payload} -> payload
      _ -> %{}
    end
  end

  defp raw_body(request, opts) do
    cond do
      is_binary(opts[:raw_body]) -> opts[:raw_body]
      is_binary(request.metadata[:raw_body]) -> request.metadata[:raw_body]
      is_binary(request.raw) -> request.raw
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

  defp header_value(headers, header_name) when is_map(headers) do
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

  defp normalize_ingress_opts(opts) do
    ingress = Keyword.get(opts, :ingress, %{}) |> ensure_map()
    settings_ingress = settings_ingress(opts)
    Map.merge(settings_ingress, ingress)
  end

  defp settings_ingress(opts) do
    opts
    |> Keyword.get(:settings, %{})
    |> ensure_map()
    |> map_get([:ingress, "ingress"])
    |> ensure_map()
  end

  defp ensure_map(%{} = map), do: map
  defp ensure_map(_), do: %{}

  defp ingress_mode(ingress) do
    case map_get(ingress, [:mode, "mode"]) do
      nil -> :webhook
      :webhook -> :webhook
      "webhook" -> :webhook
      :socket_mode -> :socket_mode
      "socket_mode" -> :socket_mode
      _ -> :invalid
    end
  end

  defp validate_sink_mfa({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {:ok, {module, function, args}}

  defp validate_sink_mfa(_), do: {:error, :invalid_sink_mfa}

  defp socket_mode_worker_opts(bridge_id, ingress, opts, sink_mfa) do
    bridge_config = Keyword.get(opts, :bridge_config)
    credentials = bridge_credentials(bridge_config)

    [
      bridge_id: bridge_id,
      sink_mfa: sink_mfa,
      sink_opts: [bridge_id: bridge_id],
      app_token:
        opts[:app_token] || map_get(ingress, [:app_token, "app_token"]) ||
          map_get(ingress, [:socket_mode_app_token, "socket_mode_app_token"]) ||
          map_get(credentials, [:app_token, "app_token"]) ||
          map_get(credentials, [:socket_mode_app_token, "socket_mode_app_token"]),
      open_client: map_get(ingress, [:open_client, "open_client"]) || Jido.Chat.Slack.SocketMode.ReqClient,
      open_client_opts:
        normalize_keyword_opts(
          map_get(ingress, [:open_client_opts, "open_client_opts"]) ||
            map_get(ingress, [:transport_opts, "transport_opts"])
        ),
      socket_client:
        map_get(ingress, [:socket_client, "socket_client"]) ||
          Jido.Chat.Slack.SocketMode.WebSockexClient,
      socket_client_opts: normalize_keyword_opts(map_get(ingress, [:socket_client_opts, "socket_client_opts"])),
      response_builder:
        map_get(ingress, [:response_builder, "response_builder"]) ||
          map_get(ingress, [:slack_response_builder, "slack_response_builder"]),
      reconnect_interval_ms: map_get(ingress, [:reconnect_interval_ms, "reconnect_interval_ms"]) || 250,
      max_backoff_ms: map_get(ingress, [:max_backoff_ms, "max_backoff_ms"]) || 5_000,
      path_prefix: map_get(ingress, [:path_prefix, "path_prefix"]) || "/socket_mode"
    ]
  end

  defp normalize_keyword_opts(value) when is_list(value) do
    Enum.reduce(value, [], fn
      {key, value}, acc when is_atom(key) ->
        Keyword.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case transport_key(key) do
          nil -> acc
          atom_key -> Keyword.put(acc, atom_key, value)
        end

      _other, acc ->
        acc
    end)
  end

  defp normalize_keyword_opts(value) when is_map(value), do: value |> Map.to_list() |> normalize_keyword_opts()
  defp normalize_keyword_opts(_value), do: []

  defp transport_key("base_url"), do: :base_url
  defp transport_key("req"), do: :req
  defp transport_key("headers"), do: :headers
  defp transport_key(_key), do: nil

  defp bridge_credentials(%{credentials: credentials}) when is_map(credentials), do: credentials
  defp bridge_credentials(_), do: %{}

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
    Enum.find_value(keys, fn key ->
      Map.get(map, key) ||
        case key do
          key when is_binary(key) ->
            try do
              Map.get(map, String.to_existing_atom(key))
            rescue
              ArgumentError -> nil
            end

          key when is_atom(key) ->
            Map.get(map, Atom.to_string(key))

          _ ->
            nil
        end
    end)
  end

  defp maybe_get(nil, _keys), do: nil
  defp maybe_get(map, keys) when is_map(map), do: map_get(map, keys)
  defp maybe_get(_other, _keys), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
