defmodule Jido.Chat.Slack.Adapter do
  @moduledoc """
  Slack `Jido.Chat.Adapter` implementation using Slack Web API with webhook or
  Socket Mode ingress.
  """

  use Jido.Chat.Adapter

  alias Jido.Chat.{
    ChannelInfo,
    EphemeralMessage,
    EventEnvelope,
    FileUpload,
    Incoming,
    Message,
    MessagePage,
    ModalResult,
    Response,
    SlashCommandEvent,
    ThreadPage,
    ThreadSummary,
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
    ModalOptions,
    ReactionOptions,
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
      add_reaction: :native,
      remove_reaction: :native,
      post_ephemeral: :native,
      open_dm: :native,
      fetch_messages: :native,
      fetch_channel_messages: :native,
      list_threads: :native,
      open_thread: :native,
      post_channel_message: :fallback,
      stream: :fallback,
      open_modal: :native,
      webhook: :native,
      verify_webhook: :native,
      parse_event: :native,
      format_webhook_response: :native
    }

  @impl true
  def listener_child_specs(bridge_id, opts \\ [])
      when is_binary(bridge_id) and is_list(opts) do
    ingress = normalize_ingress_opts(opts)

    case ingress_mode(ingress) do
      :webhook ->
        {:ok, []}

      :socket_mode ->
        with {:ok, sink_mfa} <- validate_sink_mfa(Keyword.get(opts, :sink_mfa)) do
          {:ok,
           [
             Supervisor.child_spec(
               {SocketModeWorker, socket_mode_worker_opts(bridge_id, ingress, opts, sink_mfa)},
               id: {:slack_socket_mode_worker, bridge_id}
             )
           ]}
        end

      :invalid ->
        {:error, :invalid_ingress_mode}
    end
  end

  @impl true
  def transform_incoming(payload) do
    with {:ok, message_payload, metadata} <- normalize_message_payload(payload) do
      channel_id = map_get(message_payload, [:channel, "channel"])
      user_id = message_user_id(message_payload)
      text = map_get(message_payload, [:text, "text"])
      thread_ts = external_thread_id(message_payload)
      chat_type = parse_chat_type(message_payload)
      mentions = parse_mentions(text)

      {:ok,
       Incoming.new(%{
         external_room_id: channel_id,
         external_user_id: user_id,
         text: text,
         username: message_username(message_payload),
         display_name: message_display_name(message_payload),
         external_message_id: map_get(message_payload, [:ts, "ts"]),
         external_reply_to_id: external_reply_to_id(message_payload),
         external_thread_id: thread_ts,
         timestamp: map_get(message_payload, [:ts, "ts"]),
         chat_type: chat_type,
         chat_title:
           map_get(message_payload, [
             :channel_name,
             "channel_name",
             :channel_title,
             "channel_title"
           ]),
         was_mentioned: metadata.was_mentioned,
         mentions: mentions,
         media: extract_media(message_payload),
         channel_meta: %{
           adapter_name: :slack,
           external_room_id: channel_id,
           external_thread_id: thread_ts,
           chat_type: chat_type,
           chat_title:
             map_get(message_payload, [
               :channel_name,
               "channel_name",
               :channel_title,
               "channel_title"
             ]),
           is_dm: chat_type == :dm,
           metadata: %{
             subtype: map_get(message_payload, [:subtype, "subtype"]),
             team: map_get(message_payload, [:team, "team"]),
             event_ts: map_get(message_payload, [:event_ts, "event_ts"])
           }
         },
         raw: normalize_struct(message_payload),
         metadata: Map.merge(metadata.extra, %{subtype: map_get(message_payload, [:subtype, "subtype"])})
       })}
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
       Response.new(%{
         external_message_id: map_get(result, [:ts, "ts"]),
         external_room_id: map_get(result, [:channel, "channel"]) || channel_id,
         timestamp: map_get(result, [:ts, "ts"]),
         channel_type: :slack,
         status: :sent,
         raw: result,
         metadata: %{message: map_get(result, [:message, "message"])}
       })}
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
       Response.new(%{
         external_message_id: map_get(result, [:ts, "ts"]) || stringify(message_id),
         external_room_id: map_get(result, [:channel, "channel"]) || channel_id,
         timestamp: map_get(result, [:ts, "ts"]),
         channel_type: :slack,
         status: :edited,
         raw: result,
         metadata: %{message: map_get(result, [:message, "message"])}
       })}
    end
  end

  @impl true
  def delete_message(channel_id, message_id, opts \\ []) do
    opts = opts |> pick_opts([:token, :transport, :req]) |> DeleteOptions.new()

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
  def start_typing(_channel_id, _opts \\ []), do: {:error, :unsupported}

  @impl true
  def fetch_metadata(channel_id, opts \\ []) do
    opts =
      opts |> pick_opts([:token, :transport, :req, :include_num_members]) |> MetadataOptions.new()

    with {:ok, result} <-
           transport(opts).fetch_metadata(channel_id, MetadataOptions.transport_opts(opts)) do
      metadata = normalize_struct(result)

      {:ok,
       ChannelInfo.new(%{
         id: stringify(map_get(metadata, [:id, "id"]) || channel_id),
         name:
           map_get(metadata, [:name, "name"]) ||
             map_get(metadata, [:user, "user"]) |> maybe_get([:name, "name"]),
         is_dm: conversation_is_dm?(metadata, channel_id),
         member_count: map_get(metadata, [:num_members, "num_members"]),
         metadata: metadata
       })}
    end
  end

  @impl true
  def fetch_thread(channel_id, opts \\ []) do
    external_thread_id =
      opts[:external_thread_id] || opts[:thread_ts] || opts[:message_id]

    if is_nil(external_thread_id) do
      with {:ok, info} <- fetch_metadata(channel_id, opts) do
        {:ok,
         %{
           id: "slack:#{channel_id}",
           adapter_name: :slack,
           external_room_id: channel_id,
           channel_id: "slack:#{channel_id}",
           is_dm: info.is_dm || false,
           metadata: info.metadata
         }}
      end
    else
      with {:ok, info} <- fetch_metadata(channel_id, opts),
           {:ok, root_message} <-
             fetch_message(
               channel_id,
               external_thread_id,
               Keyword.put(opts, :thread_ts, external_thread_id)
             ) do
        {:ok,
         %{
           id: thread_id(channel_id, external_thread_id),
           adapter_name: :slack,
           external_room_id: channel_id,
           external_thread_id: stringify(external_thread_id),
           channel_id: "slack:#{channel_id}",
           is_dm: info.is_dm || false,
           metadata: Map.merge(info.metadata, %{root_message: root_message})
         }}
      end
    end
  end

  @impl true
  def fetch_message(channel_id, message_id, opts \\ []) do
    transport_opts =
      opts
      |> pick_opts([:token, :transport, :req, :thread_ts, :external_thread_id])

    with {:ok, raw_message} <-
           transport(transport_opts).fetch_message(channel_id, message_id, transport_opts),
         {:ok, incoming} <- transform_incoming(ensure_channel_id(raw_message, channel_id)) do
      {:ok,
       Message.from_incoming(incoming,
         adapter_name: :slack,
         thread_id: thread_id(incoming.external_room_id, incoming.external_thread_id)
       )}
    end
  end

  @impl true
  def open_dm(user_id, opts \\ []) do
    transport_opts = pick_opts(opts, [:token, :transport, :req])
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
             EphemeralOptions.transport_opts(opts) ++
               payload_to_opts(EphemeralOptions.payload_opts(opts))
           ) do
      thread_ts = map_get(result, [:message_ts, "message_ts"]) || opts.thread_ts

      {:ok,
       EphemeralMessage.new(%{
         id:
           "slack:ephemeral:" <>
             (map_get(result, [:message_ts, "message_ts"]) || Jido.Chat.ID.generate!()),
         thread_id: thread_id(channel_id, thread_ts),
         used_fallback: false,
         raw: result,
         metadata: %{channel_id: stringify(channel_id), user_id: stringify(user_id)}
       })}
    end
  end

  @impl true
  def open_modal(channel_id, payload, opts \\ []) when is_map(payload) do
    opts = opts |> pick_opts([:token, :transport, :req, :trigger_id]) |> ModalOptions.new()

    if is_nil(opts.trigger_id) do
      {:error, :missing_trigger_id}
    else
      with {:ok, result} <-
             transport(opts).open_modal(
               opts.trigger_id,
               payload,
               ModalOptions.transport_opts(opts)
             ) do
        view = map_get(result, [:view, "view"]) || %{}

        {:ok,
         ModalResult.new(%{
           id:
             "slack:modal:" <>
               (map_get(view, [:id, "id"]) || map_get(result, [:view_id, "view_id"]) ||
                  Jido.Chat.ID.generate!()),
           status: :opened,
           external_room_id: channel_id,
           raw: result,
           metadata: %{
             trigger_id: opts.trigger_id,
             view_id: map_get(view, [:id, "id"]),
             callback_id: map_get(view, [:callback_id, "callback_id"])
           }
         })}
      end
    end
  end

  @impl true
  def add_reaction(channel_id, message_id, emoji, opts \\ []) do
    opts = opts |> pick_opts([:token, :transport, :req]) |> ReactionOptions.new()

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
    opts = opts |> pick_opts([:token, :transport, :req]) |> ReactionOptions.new()

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
       MessagePage.new(%{
         messages:
           normalize_messages(
             map_get(result, [:messages, "messages"]) || [],
             channel_id,
             thread_ts
           ),
         next_cursor: next_cursor(result),
         direction: opts.direction,
         metadata: %{raw: result}
       })}
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
      |> pick_opts([:token, :transport, :req, :cursor, :limit, :direction])
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
       ThreadPage.new(%{
         threads: threads,
         next_cursor: next_cursor(result),
         metadata: %{raw: result}
       })}
    end
  end

  @impl true
  def verify_webhook(%WebhookRequest{} = request, opts \\ []) do
    signing_secret =
      opts[:signing_secret] || opts[:slack_signing_secret] ||
        Application.get_env(:jido_chat_slack, :slack_signing_secret)

    if is_nil(signing_secret) do
      :ok
    else
      verify_slack_signature(request, signing_secret, opts)
    end
  end

  @impl true
  def parse_event(%WebhookRequest{} = request, _opts \\ []) do
    with {:ok, payload} <- decode_request_payload(request) do
      parse_payload_event(payload, request)
    end
  end

  @impl true
  def format_webhook_response(result, opts \\ [])

  def format_webhook_response({:ok, _chat, :noop}, opts) do
    request = opts[:request]
    payload = request && request_payload(request)

    if url_verification_payload?(payload) do
      WebhookResponse.new(%{
        status: 200,
        headers: %{"content-type" => "text/plain"},
        body: map_get(payload, [:challenge, "challenge"])
      })
    else
      WebhookResponse.new(%{
        status: 200,
        headers: %{"content-type" => "text/plain"},
        body: ""
      })
    end
  end

  def format_webhook_response({:ok, _chat, _event} = result, opts) do
    case InteractionResponse.webhook_response(result, opts) do
      %WebhookResponse{} = response ->
        response

      nil ->
        WebhookResponse.new(%{
          status: 200,
          headers: %{"content-type" => "text/plain"},
          body: ""
        })
    end
  end

  def format_webhook_response({:error, reason}, _opts)
      when reason in [
             :invalid_signature,
             :stale_timestamp,
             :missing_signature,
             :missing_timestamp
           ] do
    WebhookResponse.error(401, %{error: to_string(reason)})
  end

  def format_webhook_response({:error, :missing_raw_body}, _opts) do
    WebhookResponse.error(400, %{error: "missing_raw_body"})
  end

  def format_webhook_response({:error, reason}, _opts) do
    WebhookResponse.error(400, %{error: inspect(reason)})
  end

  @impl true
  def handle_webhook(%Jido.Chat{} = chat, payload, opts \\ []) when is_map(payload) do
    request =
      WebhookRequest.new(%{
        adapter_name: :slack,
        headers: opts[:headers] || %{},
        payload: payload,
        raw: opts[:raw_body] || payload,
        metadata: %{raw_body: opts[:raw_body]}
      })

    with :ok <- verify_webhook(request, opts),
         {:ok, parsed_event} <- parse_event(request, opts),
         {:ok, updated_chat, incoming} <- route_parsed_event(chat, parsed_event, opts, request) do
      {:ok, updated_chat, incoming}
    end
  end

  defp route_parsed_event(chat, :noop, _opts, %WebhookRequest{} = request) do
    {:ok, chat, synthetic_incoming("slack", nil, nil, request_payload(request), :noop)}
  end

  defp route_parsed_event(chat, %EventEnvelope{} = envelope, opts, _request) do
    with {:ok, updated_chat, routed_envelope} <-
           Jido.Chat.process_event(chat, :slack, envelope, opts),
         {:ok, incoming} <- incoming_from_event(routed_envelope) do
      {:ok, updated_chat, incoming}
    end
  end

  defp incoming_from_event(%EventEnvelope{event_type: :message, payload: %Incoming{} = incoming}),
    do: {:ok, incoming}

  defp incoming_from_event(%EventEnvelope{event_type: :slash_command, raw: raw}) do
    {:ok,
     synthetic_incoming(
       map_get(raw, [:channel_id, "channel_id"]) || "slack",
       map_get(raw, [:user_id, "user_id"]),
       map_get(raw, [:trigger_id, "trigger_id"]),
       raw,
       :slash_command
     )}
  end

  defp incoming_from_event(%EventEnvelope{event_type: :action, raw: raw}) do
    channel_id =
      map_get(raw, [:channel, "channel"])
      |> maybe_get([:id, "id"])

    user_id = map_get(raw, [:user, "user"]) |> maybe_get([:id, "id"])
    message_id = map_get(raw, [:container, "container"]) |> maybe_get([:message_ts, "message_ts"])

    {:ok, synthetic_incoming(channel_id || "slack", user_id, message_id, raw, :action)}
  end

  defp incoming_from_event(%EventEnvelope{event_type: :modal_submit, raw: raw}) do
    metadata =
      decode_private_metadata(
        map_get(raw, [:view, "view"])
        |> maybe_get([:private_metadata, "private_metadata"])
      )

    {:ok,
     synthetic_incoming(
       Map.get(metadata, "channel_id") || "slack",
       map_get(raw, [:user, "user"]) |> maybe_get([:id, "id"]),
       map_get(raw, [:view, "view"]) |> maybe_get([:id, "id"]),
       raw,
       :modal_submit
     )}
  end

  defp incoming_from_event(%EventEnvelope{event_type: :modal_close, raw: raw}) do
    metadata =
      decode_private_metadata(
        map_get(raw, [:view, "view"])
        |> maybe_get([:private_metadata, "private_metadata"])
      )

    {:ok,
     synthetic_incoming(
       Map.get(metadata, "channel_id") || "slack",
       map_get(raw, [:user, "user"]) |> maybe_get([:id, "id"]),
       map_get(raw, [:view, "view"]) |> maybe_get([:id, "id"]),
       raw,
       :modal_close
     )}
  end

  defp incoming_from_event(%EventEnvelope{event_type: :reaction, raw: raw}) do
    item = map_get(raw, [:item, "item"]) || %{}

    {:ok,
     synthetic_incoming(
       map_get(item, [:channel, "channel"]) || "slack",
       map_get(raw, [:user, "user"]),
       map_get(item, [:ts, "ts"]),
       raw,
       :reaction
     )}
  end

  defp incoming_from_event(_), do: {:error, :unsupported_event_type}

  defp parse_payload_event(payload, request) when is_map(payload) do
    cond do
      url_verification_payload?(payload) ->
        {:ok, :noop}

      slash_command_payload?(payload) ->
        {:ok, slash_command_envelope(payload)}

      interactive_payload?(payload) ->
        interactive_event_envelope(payload)

      event_callback_payload?(payload) ->
        event_callback_envelope(payload, request)

      message_like_payload?(payload) ->
        with {:ok, incoming} <- transform_incoming(payload) do
          {:ok,
           EventEnvelope.new(%{
             adapter_name: :slack,
             event_type: :message,
             thread_id: thread_id(incoming.external_room_id, incoming.external_thread_id),
             channel_id: stringify(incoming.external_room_id),
             message_id: stringify(incoming.external_message_id),
             payload: incoming,
             raw: payload,
             metadata: %{source: :direct}
           })}
        end

      true ->
        {:ok, :noop}
    end
  end

  defp parse_payload_event(_payload, _request), do: {:ok, :noop}

  defp event_callback_envelope(payload, request) do
    event = map_get(payload, [:event, "event"]) || %{}

    case normalize_event_type(map_get(event, [:type, "type"])) do
      :message ->
        message_payload = extract_event_message(event, payload)

        if is_nil(message_payload) do
          {:ok, :noop}
        else
          with {:ok, incoming} <- transform_incoming(message_payload) do
            {:ok,
             EventEnvelope.new(%{
               adapter_name: :slack,
               event_type: :message,
               thread_id: thread_id(incoming.external_room_id, incoming.external_thread_id),
               channel_id: stringify(incoming.external_room_id),
               message_id: stringify(incoming.external_message_id),
               payload: incoming,
               raw: payload,
               metadata: %{
                 event_id: map_get(payload, [:event_id, "event_id"]),
                 path: request.path
               }
             })}
          end
        end

      :app_mention ->
        with {:ok, incoming} <- transform_incoming(Map.put(event, "type", "app_mention")) do
          {:ok,
           EventEnvelope.new(%{
             adapter_name: :slack,
             event_type: :message,
             thread_id: thread_id(incoming.external_room_id, incoming.external_thread_id),
             channel_id: stringify(incoming.external_room_id),
             message_id: stringify(incoming.external_message_id),
             payload: incoming,
             raw: payload,
             metadata: %{event_id: map_get(payload, [:event_id, "event_id"])}
           })}
        end

      :reaction_added ->
        {:ok, reaction_envelope(payload, true)}

      :reaction_removed ->
        {:ok, reaction_envelope(payload, false)}

      _ ->
        {:ok, :noop}
    end
  end

  defp slash_command_envelope(payload) do
    channel_id = map_get(payload, [:channel_id, "channel_id"])

    user =
      author_from_user_payload(%{
        "id" => map_get(payload, [:user_id, "user_id"]),
        "username" => map_get(payload, [:user_name, "user_name"])
      })

    EventEnvelope.new(%{
      adapter_name: :slack,
      event_type: :slash_command,
      thread_id: thread_id(channel_id, nil),
      channel_id: stringify(channel_id),
      message_id: stringify(map_get(payload, [:trigger_id, "trigger_id"])),
      payload:
        SlashCommandEvent.new(%{
          adapter_name: :slack,
          thread_id: thread_id(channel_id, nil),
          channel_id: stringify(channel_id),
          message_id: stringify(map_get(payload, [:trigger_id, "trigger_id"])),
          command: map_get(payload, [:command, "command"]),
          text: map_get(payload, [:text, "text"]) || "",
          trigger_id: stringify(map_get(payload, [:trigger_id, "trigger_id"])),
          user: user,
          raw: payload,
          metadata: %{
            response_url: map_get(payload, [:response_url, "response_url"]),
            team_id: map_get(payload, [:team_id, "team_id"])
          }
        }),
      raw: payload,
      metadata: %{}
    })
  end

  defp interactive_event_envelope(payload) do
    case map_get(payload, [:type, "type"]) do
      "block_actions" ->
        {:ok, action_envelope(payload)}

      "shortcut" ->
        {:ok, action_envelope(payload)}

      "message_action" ->
        {:ok, action_envelope(payload)}

      "view_submission" ->
        {:ok, modal_submit_envelope(payload)}

      "view_closed" ->
        {:ok, modal_close_envelope(payload)}

      _ ->
        {:ok, :noop}
    end
  end

  defp action_envelope(payload) do
    action = first_action(payload)
    channel_id = map_get(payload, [:channel, "channel"]) |> maybe_get([:id, "id"])

    message_id =
      map_get(payload, [:container, "container"]) |> maybe_get([:message_ts, "message_ts"])

    message = map_get(payload, [:message, "message"]) || %{}
    thread_ts = external_thread_id(message)

    EventEnvelope.new(%{
      adapter_name: :slack,
      event_type: :action,
      thread_id: thread_id(channel_id, thread_ts),
      channel_id: stringify(channel_id),
      message_id: stringify(message_id || map_get(message, [:ts, "ts"])),
      payload: %{
        adapter_name: :slack,
        thread_id: thread_id(channel_id, thread_ts),
        message_id: stringify(message_id || map_get(message, [:ts, "ts"])),
        action_id:
          map_get(action, [:action_id, "action_id"]) ||
            map_get(payload, [:callback_id, "callback_id"]),
        value: extract_action_value(action),
        trigger_id: map_get(payload, [:trigger_id, "trigger_id"]),
        user: author_from_user_payload(map_get(payload, [:user, "user"]) || %{}),
        raw: payload,
        metadata: %{
          response_url: map_get(payload, [:response_url, "response_url"]),
          channel_id: channel_id
        }
      },
      raw: payload,
      metadata: %{}
    })
  end

  defp modal_submit_envelope(payload) do
    view = map_get(payload, [:view, "view"]) || %{}

    EventEnvelope.new(%{
      adapter_name: :slack,
      event_type: :modal_submit,
      thread_id: nil,
      channel_id: nil,
      message_id: stringify(map_get(view, [:id, "id"])),
      payload: %{
        adapter_name: :slack,
        callback_id: map_get(view, [:callback_id, "callback_id"]),
        view_id: map_get(view, [:id, "id"]),
        values: extract_modal_values(view),
        user: author_from_user_payload(map_get(payload, [:user, "user"]) || %{}),
        raw: payload,
        metadata: %{
          private_metadata: map_get(view, [:private_metadata, "private_metadata"]),
          hash: map_get(view, [:hash, "hash"])
        }
      },
      raw: payload,
      metadata: %{}
    })
  end

  defp modal_close_envelope(payload) do
    view = map_get(payload, [:view, "view"]) || %{}

    EventEnvelope.new(%{
      adapter_name: :slack,
      event_type: :modal_close,
      thread_id: nil,
      channel_id: nil,
      message_id: stringify(map_get(view, [:id, "id"])),
      payload: %{
        adapter_name: :slack,
        callback_id: map_get(view, [:callback_id, "callback_id"]),
        view_id: map_get(view, [:id, "id"]),
        user: author_from_user_payload(map_get(payload, [:user, "user"]) || %{}),
        raw: payload,
        metadata: %{
          private_metadata: map_get(view, [:private_metadata, "private_metadata"]),
          hash: map_get(view, [:hash, "hash"])
        }
      },
      raw: payload,
      metadata: %{}
    })
  end

  defp reaction_envelope(payload, added?) do
    event = map_get(payload, [:event, "event"]) || %{}
    item = map_get(event, [:item, "item"]) || %{}
    channel_id = map_get(item, [:channel, "channel"])
    ts = map_get(item, [:ts, "ts"])

    EventEnvelope.new(%{
      adapter_name: :slack,
      event_type: :reaction,
      thread_id: thread_id(channel_id, ts),
      channel_id: stringify(channel_id),
      message_id: stringify(ts),
      payload: %{
        adapter_name: :slack,
        thread_id: thread_id(channel_id, ts),
        message_id: stringify(ts),
        emoji: map_get(event, [:reaction, "reaction"]),
        added: added?,
        user: author_from_user_payload(%{"id" => map_get(event, [:user, "user"])}),
        raw: event,
        metadata: %{item: item}
      },
      raw: payload,
      metadata: %{}
    })
  end

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

  defp message_like_payload?(payload) when is_map(payload) do
    normalize_event_type(map_get(payload, [:type, "type"])) in [:message, :app_mention]
  end

  defp slash_command_payload?(payload) when is_map(payload) do
    is_binary(map_get(payload, [:command, "command"])) and
      is_binary(map_get(payload, [:user_id, "user_id"]))
  end

  defp interactive_payload?(payload) when is_map(payload) do
    map_get(payload, [:type, "type"]) in [
      "block_actions",
      "shortcut",
      "message_action",
      "view_submission",
      "view_closed"
    ]
  end

  defp event_callback_payload?(payload) when is_map(payload) do
    map_get(payload, [:type, "type"]) == "event_callback" and
      is_map(map_get(payload, [:event, "event"]))
  end

  defp url_verification_payload?(payload) when is_map(payload) do
    map_get(payload, [:type, "type"]) == "url_verification"
  end

  defp normalize_message_payload(payload) when is_map(payload) do
    cond do
      normalize_event_type(map_get(payload, [:type, "type"])) in [:message, :app_mention] ->
        with message when is_map(message) <- unwrap_message_event(payload) do
          {:ok, message,
           %{
             was_mentioned: normalize_event_type(map_get(payload, [:type, "type"])) == :app_mention,
             extra: %{}
           }}
        else
          nil -> {:error, :unsupported_message_type}
        end

      event_callback_payload?(payload) ->
        event = map_get(payload, [:event, "event"]) || %{}

        case normalize_event_type(map_get(event, [:type, "type"])) do
          type when type in [:message, :app_mention] ->
            case extract_event_message(event, payload) do
              nil ->
                {:error, :unsupported_message_type}

              message ->
                {:ok, message,
                 %{
                   was_mentioned: type == :app_mention,
                   extra: %{event_id: map_get(payload, [:event_id, "event_id"])}
                 }}
            end

          _ ->
            {:error, :unsupported_message_type}
        end

      true ->
        {:error, :unsupported_message_type}
    end
  end

  defp normalize_message_payload(_), do: {:error, :unsupported_message_type}

  defp extract_event_message(event, _payload) do
    case map_get(event, [:subtype, "subtype"]) do
      "message_changed" ->
        map_get(event, [:message, "message"])

      "message_deleted" ->
        nil

      _ ->
        event
    end
  end

  defp unwrap_message_event(payload) do
    case map_get(payload, [:subtype, "subtype"]) do
      "message_changed" -> map_get(payload, [:message, "message"])
      "message_deleted" -> nil
      _ -> payload
    end
  end

  defp extract_media(message) when is_map(message) do
    message
    |> map_get([:files, "files"])
    |> List.wrap()
    |> Enum.map(&normalize_media/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_media(file) when is_map(file) do
    url =
      map_get(file, [:url_private, "url_private"]) ||
        map_get(file, [:url_private_download, "url_private_download"])

    if is_nil(url) do
      nil
    else
      %{
        kind: media_kind(file),
        url: url,
        media_type: map_get(file, [:mimetype, "mimetype"]),
        metadata: %{
          id: map_get(file, [:id, "id"]),
          name: map_get(file, [:name, "name"]),
          size: map_get(file, [:size, "size"])
        }
      }
    end
  end

  defp media_kind(file) do
    case map_get(file, [:mimetype, "mimetype"]) do
      "image/" <> _rest -> :image
      "video/" <> _rest -> :video
      "audio/" <> _rest -> :audio
      _ -> :file
    end
  end

  defp parse_mentions(text) when is_binary(text) do
    Regex.scan(~r/<@([A-Z0-9]+)>/, text, return: :index)
    |> Enum.map(fn
      [{offset, length}, {user_offset, user_length}] ->
        %{
          user_id: binary_part(text, user_offset, user_length),
          username: nil,
          offset: offset,
          length: length
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_mentions(_), do: []

  defp normalize_messages(messages, channel_id, thread_ts) do
    Enum.flat_map(messages, fn raw ->
      case transform_incoming(raw) do
        {:ok, incoming} ->
          [
            Message.from_incoming(incoming,
              adapter_name: :slack,
              thread_id: thread_id(channel_id, thread_ts || incoming.external_thread_id)
            )
          ]

        {:error, _reason} ->
          []
      end
    end)
  end

  defp ensure_channel_id(%{} = raw_message, channel_id) do
    if is_nil(map_get(raw_message, [:channel, "channel"])) do
      Map.put(raw_message, :channel, stringify(channel_id))
    else
      raw_message
    end
  end

  defp ensure_channel_id(raw_message, _channel_id), do: raw_message

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
    file =
      result
      |> map_get([:files, "files"])
      |> List.wrap()
      |> List.first()
      |> normalize_struct()

    Response.new(%{
      external_message_id: slack_file_share_ts(file, channel_id),
      external_room_id: stringify(channel_id),
      timestamp: slack_file_share_ts(file, channel_id),
      channel_type: :slack,
      status: :sent,
      raw: result,
      metadata:
        %{
          file_id: map_get(file, [:id, "id"]),
          filename: map_get(file, [:name, "name"]),
          size: map_get(file, [:size, "size"]),
          url: map_get(file, [:url_private, "url_private"]),
          content_type: map_get(file, [:mimetype, "mimetype"]),
          upload_kind: upload.kind,
          delivered_kind: slack_file_kind(file, upload.kind)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    })
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

  defp slack_file_kind(file, fallback) do
    case map_get(file, [:mimetype, "mimetype"]) do
      <<"image/", _::binary>> -> :image
      <<"audio/", _::binary>> -> :audio
      <<"video/", _::binary>> -> :video
      _ -> fallback
    end
  end

  defp maybe_put_kw(keyword, _key, nil), do: keyword
  defp maybe_put_kw(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp normalize_thread_summary(channel_id, raw_thread) when is_map(raw_thread) do
    case transform_incoming(raw_thread) do
      {:ok, incoming} ->
        [
          ThreadSummary.new(%{
            id:
              thread_id(
                channel_id,
                external_thread_id(raw_thread) || incoming.external_message_id
              ),
            last_reply_at: map_get(raw_thread, [:latest_reply, "latest_reply"]),
            reply_count: map_get(raw_thread, [:reply_count, "reply_count"]) || 0,
            root_message:
              Message.from_incoming(incoming,
                adapter_name: :slack,
                thread_id:
                  thread_id(
                    channel_id,
                    incoming.external_thread_id || incoming.external_message_id
                  )
              ),
            metadata: %{raw: raw_thread}
          })
        ]

      {:error, _reason} ->
        []
    end
  end

  defp normalize_thread_summary(_channel_id, _raw_thread), do: []

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

  defp external_reply_to_id(message) when is_map(message) do
    thread_ts = map_get(message, [:thread_ts, "thread_ts"])
    ts = map_get(message, [:ts, "ts"])

    if is_binary(thread_ts) and thread_ts != ts, do: thread_ts, else: nil
  end

  defp message_user_id(message) when is_map(message) do
    map_get(message, [:user, "user"]) ||
      bot_id(message)
  end

  defp message_username(message) when is_map(message) do
    map_get(message, [:username, "username"]) ||
      map_get(message, [:user_profile, "user_profile"])
      |> maybe_get([:display_name, "display_name"])
  end

  defp message_display_name(message) when is_map(message) do
    message_username(message) ||
      map_get(message, [:user_profile, "user_profile"]) |> maybe_get([:real_name, "real_name"])
  end

  defp bot_id(message) do
    case map_get(message, [:bot_id, "bot_id"]) do
      nil -> nil
      bot_id -> "bot:" <> to_string(bot_id)
    end
  end

  defp parse_chat_type(message) do
    case map_get(message, [:channel_type, "channel_type"]) do
      "im" -> :dm
      "mpim" -> :group
      "group" -> :group
      "channel" -> :channel
      _ -> infer_chat_type_from_channel_id(map_get(message, [:channel, "channel"]))
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

  defp author_from_user_payload(payload) when is_map(payload) do
    %{
      user_id: stringify(map_get(payload, [:id, "id"]) || "unknown"),
      user_name:
        map_get(payload, [:username, "username"]) ||
          map_get(payload, [:name, "name"]) ||
          stringify(map_get(payload, [:id, "id"]) || "unknown"),
      full_name:
        map_get(payload, [:real_name, "real_name"]) ||
          map_get(payload, [:username, "username"]) ||
          map_get(payload, [:name, "name"])
    }
  end

  defp extract_action_value(action) when is_map(action) do
    map_get(action, [:value, "value"]) ||
      map_get(action, [:selected_option, "selected_option"]) |> maybe_get([:value, "value"]) ||
      map_get(action, [:selected_user, "selected_user"]) ||
      map_get(action, [:selected_channel, "selected_channel"]) ||
      map_get(action, [:selected_conversation, "selected_conversation"])
  end

  defp extract_action_value(_), do: nil

  defp extract_modal_values(view) when is_map(view) do
    view
    |> map_get([:state, "state"])
    |> maybe_get([:values, "values"])
    |> normalize_struct()
  end

  defp extract_modal_values(_), do: %{}

  defp first_action(payload) do
    payload
    |> map_get([:actions, "actions"])
    |> List.wrap()
    |> List.first()
    |> normalize_struct()
  end

  defp decode_private_metadata(nil), do: %{}

  defp decode_private_metadata(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, metadata} when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp decode_private_metadata(_), do: %{}

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

  defp synthetic_incoming(room_id, user_id, message_id, raw, event_type) do
    Incoming.new(%{
      external_room_id: room_id || "slack",
      external_user_id: user_id,
      external_message_id: message_id,
      text: nil,
      raw: normalize_struct(raw),
      metadata: %{event_type: event_type}
    })
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

  defp normalize_event_type("message"), do: :message
  defp normalize_event_type("app_mention"), do: :app_mention
  defp normalize_event_type("reaction_added"), do: :reaction_added
  defp normalize_event_type("reaction_removed"), do: :reaction_removed
  defp normalize_event_type(other) when is_atom(other), do: other
  defp normalize_event_type(_), do: :unknown

  defp thread_id(channel_id, nil), do: "slack:#{channel_id}"
  defp thread_id(channel_id, thread_ts), do: "slack:#{channel_id}:#{thread_ts}"

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
        map_get(ingress, [:app_token, "app_token"]) ||
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

  defp normalize_keyword_opts(value) when is_list(value), do: value
  defp normalize_keyword_opts(value) when is_map(value), do: Enum.into(value, [])
  defp normalize_keyword_opts(_value), do: []

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
