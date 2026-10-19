defmodule Jido.Chat.Slack.Normalizer do
  @moduledoc "Private Slack protocol mapper for complete native Signal deliveries."
  alias Jido.Chat.{Client, Delivery}

  alias Jido.Chat.Signal.{
    ActionReceived,
    AssistantContextChanged,
    AssistantThreadStarted,
    Identity,
    MembershipChanged,
    MessageDeleted,
    MessageReceived,
    MessageUpdated,
    ModalClosed,
    ModalSubmitted,
    NormalizationFailed,
    OptionsRequested,
    Policy,
    ReactionAdded,
    ReactionRemoved,
    SlashCommandReceived
  }

  @limits [:signal_too_large, :delivery_too_large, :too_many_signals, :too_many_failures]

  @doc false
  @spec normalize(Client.t(), term()) :: {:ok, Delivery.t()} | {:error, Jido.Chat.Errors.Contract.t()}
  def normalize(client, %{payload: payload}), do: normalize(client, payload)

  def normalize(%Client{} = client, input) do
    result =
      try do
        payload = decode(input)
        inner = if field(payload, "envelope_id"), do: field(payload, "payload"), else: payload
        inner = decode(inner)
        identity = field(inner, "event_id") || "digest:" <> digest(canonical(inner))
        delivery = "slack:" <> (field(payload, "envelope_id") || identity)
        context = %{client: client, delivery: delivery, item: "slack:" <> identity}
        with {:ok, facts} <- map_payload(context, inner), do: Delivery.new(client, delivery, List.wrap(facts))
      rescue
        _ -> Policy.error(:invalid_delivery)
      catch
        _, _ -> Policy.error(:invalid_delivery)
      end

    result
  end

  defp decode(%{} = payload) do
    case field(payload, "payload") do
      encoded when is_binary(encoded) -> Jason.decode!(encoded)
      _ -> payload
    end
  end

  defp decode(encoded) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> encoded |> URI.decode_query() |> decode()
    end
  end

  defp decode(_input), do: throw(:invalid_payload)

  defp map_payload(context, payload) do
    type = protocol_type(field(payload, "type"))
    event = field(payload, "event")

    result =
      cond do
        type == "url_verification" ->
          {:ok, []}

        is_map(event) ->
          map_event(context, event)

        is_binary(field(payload, "command")) ->
          slash(context, payload)

        type in ~w(block_actions message_action shortcut view_submission view_closed block_suggestion) ->
          interaction_fact(context, payload)

        type in ~w(message app_mention reaction_added reaction_removed member_joined_channel member_left_channel assistant_thread_started assistant_thread_context_changed) ->
          map_event(context, payload)

        map_size(payload) == 0 ->
          {:ok, []}

        true ->
          failed(context, "unsupported_item", type || "unknown", nil)
      end

    case result do
      {:ok, facts} ->
        {:ok, List.wrap(facts)}

      {:error, %Jido.Chat.Errors.Contract{code: code}} = error when code in @limits ->
        error

      _ ->
        room = field(payload, "channel")
        room = if is_map(room), do: field(room, "id"), else: room
        failed(context, "invalid_item", type || "unknown", room)
    end
  end

  defp map_event(context, event) do
    case protocol_type(field(event, "type")) do
      type when type in ["message", "app_mention"] -> message(context, event, type == "app_mention")
      "reaction_added" -> reaction(context, event, ReactionAdded)
      "reaction_removed" -> reaction(context, event, ReactionRemoved)
      "member_joined_channel" -> membership(context, event, true)
      "member_left_channel" -> membership(context, event, false)
      "assistant_thread_started" -> assistant(context, event, AssistantThreadStarted)
      "assistant_thread_context_changed" -> assistant(context, event, AssistantContextChanged)
      type -> failed(context, "unsupported_item", type || "unknown", field(event, "channel"))
    end
  end

  defp message(context, event, mentioned) do
    case protocol_type(field(event, "subtype")) do
      "message_deleted" ->
        old = field(event, "previous_message") || %{}

        data = %{
          "room_id" => field(event, "channel") || field(old, "channel"),
          "message_id" => field(event, "deleted_ts") || field(old, "ts"),
          "thread_id" => field(old, "thread_ts"),
          "timestamp" => field(event, "event_ts") || field(event, "ts")
        }

        build(context, MessageDeleted, "message_deleted", data)

      "message_changed" ->
        current = field(event, "message") || %{}
        previous = field(event, "previous_message") || %{}
        room = field(event, "channel") || field(current, "channel") || field(previous, "channel")

        data = %{
          "room_id" => room,
          "message_id" => field(current, "ts") || field(previous, "ts"),
          "text" => message_text(current),
          "sender" => lifecycle_actor(current, previous, context.client),
          "thread_id" => field(current, "thread_ts") || field(previous, "thread_ts"),
          "timestamp" => field(current, "edited") |> field("ts") || field(event, "event_ts") || field(event, "ts")
        }

        with {:ok, media} <- media(context, current),
             do: build(context, MessageUpdated, "message_changed", Map.put(data, "media", media))

      _ ->
        data = %{
          "room_id" => field(event, "channel"),
          "message_id" => field(event, "ts"),
          "text" => message_text(event),
          "sender" => actor(event, context.client),
          "thread_id" => field(event, "thread_ts"),
          "reply_to_id" => field(event, "thread_ts"),
          "timestamp" => field(event, "ts"),
          "mentioned" => mentioned || mentions_bot?(event, context.client),
          "mentions" => mentions(message_text(event)),
          "conversation_kind" => conversation_kind(field(event, "channel")),
          "conversation_name" => field(event, "channel_name") || field(event, "channel_title")
        }

        with {:ok, media} <- media(context, event),
             do: build(context, MessageReceived, "message", Map.put(data, "media", media))
    end
  end

  defp membership(context, event, joined) do
    actor = if joined, do: field(event, "inviter")
    actor = if actor == "", do: nil, else: actor

    data = %{
      "room_id" => field(event, "channel"),
      "participant_id" => field(event, "user"),
      "actor_id" => actor,
      "bot_self" => field(event, "user") == Client.options(context.client)[:bot_user_id],
      "transition" => if(joined, do: "joined", else: "left"),
      "evidence" => if(joined, do: "explicit_join", else: "explicit_leave"),
      "previous" => nil,
      "current" => %{"status" => if(joined, do: "member", else: "left"), "is_member" => joined}
    }

    build(context, MembershipChanged, field(event, "type"), data)
  end

  defp reaction(context, event, definition) do
    item = field(event, "item") || %{}

    build(context, definition, field(event, "type"), %{
      "room_id" => field(item, "channel"),
      "message_id" => field(item, "ts"),
      "actor_id" => field(event, "user"),
      "reaction" => field(event, "reaction")
    })
  end

  defp assistant(context, event, definition) do
    thread = field(event, "assistant_thread") || event
    source = field(thread, "context") || %{}

    data = %{
      "room_id" => field(thread, "channel_id"),
      "thread_id" => field(thread, "thread_ts"),
      "actor_id" => field(thread, "user_id") || field(event, "user"),
      "context" => select(source, ~w(channel_id team_id enterprise_id))
    }

    build(context, definition, field(event, "type"), data)
  end

  defp slash(context, payload) do
    with {:ok, interaction} <- capture_interaction(context, payload, field(payload, "channel_id")) do
      data = %{
        "room_id" => field(payload, "channel_id"),
        "interaction_id" => interaction,
        "command" => field(payload, "command"),
        "text" => field(payload, "text") || "",
        "actor_id" => field(payload, "user_id")
      }

      build(context, SlashCommandReceived, "slash", data)
    end
  end

  defp interaction_fact(context, payload) do
    type = field(payload, "type")
    view = field(payload, "view") || %{}
    message = field(payload, "message") || %{}
    room = field(payload, "channel") |> field("id")
    room = room || field(payload, "container") |> field("channel_id")
    room = room || private_room(field(view, "private_metadata"))
    actor = field(payload, "user") |> field("id")

    with {:ok, interaction} <- capture_interaction(context, payload, room) do
      case type do
        "view_submission" ->
          build(context, ModalSubmitted, type, %{
            "room_id" => room,
            "interaction_id" => interaction,
            "view_id" => field(view, "id"),
            "callback_id" => field(view, "callback_id"),
            "actor_id" => actor,
            "values" => modal_values(view)
          })

        "view_closed" ->
          build(context, ModalClosed, type, %{
            "room_id" => room,
            "interaction_id" => interaction,
            "view_id" => field(view, "id"),
            "callback_id" => field(view, "callback_id"),
            "actor_id" => actor
          })

        "block_suggestion" ->
          build(context, OptionsRequested, type, %{
            "room_id" => room,
            "interaction_id" => interaction,
            "action_id" => field(payload, "action_id"),
            "query" => field(payload, "value") || "",
            "actor_id" => actor,
            "view_id" => field(view, "id"),
            "limit" => 100
          })

        _ ->
          actions = field(payload, "actions") || [%{"action_id" => field(payload, "callback_id")}]

          Enum.with_index(actions)
          |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, acc} ->
            data = %{
              "room_id" => room,
              "interaction_id" => interaction,
              "action_id" => field(action, "action_id"),
              "actor_id" => actor,
              "message_id" => field(message, "ts") || field(payload, "container") |> field("message_ts"),
              "thread_id" => field(message, "thread_ts"),
              "value" => action_value(action),
              "values" => Map.put(%{}, field(action, "action_id") || "value", action_values(action))
            }

            case build(context, ActionReceived, type <> ":" <> to_string(index), data) do
              {:ok, fact} ->
                {:cont, {:ok, acc ++ [fact]}}

              {:error, %Jido.Chat.Errors.Contract{code: code}} = error when code in @limits ->
                {:halt, error}

              _ ->
                case failed(context, "invalid_item", type, room, "action_failure:" <> to_string(index)) do
                  {:ok, fact} -> {:cont, {:ok, acc ++ [fact]}}
                  error -> {:halt, error}
                end
            end
          end)
      end
    end
  end

  defp capture_interaction(context, payload, _room) do
    id = "slack:interaction:" <> digest({context.client.id, canonical(payload)})
    {:ok, id}
  end

  defp private_room(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> field(map, "channel_id")
      _ -> nil
    end
  end

  defp private_room(_value), do: nil

  defp modal_values(view) do
    values = field(view, "state") |> field("values")

    if is_map(values) do
      Enum.reduce(values, %{}, fn {_block, actions}, acc ->
        Enum.reduce(actions, acc, fn {action, state}, result ->
          Map.put(result, to_string(action), action_values(state))
        end)
      end)
    else
      %{}
    end
  end

  defp action_values(action) do
    cond do
      not is_nil(field(action, "value")) ->
        field(action, "value")

      is_list(field(action, "selected_options")) ->
        Enum.map(field(action, "selected_options"), &field(&1, "value"))

      is_list(field(action, "selected_users")) ->
        field(action, "selected_users")

      is_list(field(action, "selected_conversations")) ->
        field(action, "selected_conversations")

      true ->
        field(action, "selected_option") |> field("value") || field(action, "selected_user") ||
          field(action, "selected_conversation") || field(action, "selected_date")
    end
  end

  defp action_value(action) do
    case action_values(action) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp media(context, message) do
    Enum.reduce_while(field(message, "files") || [], {:ok, []}, fn file, {:ok, acc} ->
      url =
        non_blank(field(file, "url_private_download")) || non_blank(field(file, "url_private")) ||
          non_blank(field(file, "permalink"))

      mime = normalized_mime(field(file, "mimetype"))
      filename = non_blank(field(file, "name")) || non_blank(field(file, "title"))
      kind = media_kind(mime, field(file, "filetype"), filename, url)

      with true <- is_binary(url) and url != "" do
        ref = %{"id" => url, "client_id" => context.client.id, "kind" => "media"}

        value =
          %{"kind" => kind, "resource_ref" => ref}
          |> optional("name", filename)
          |> optional("media_type", mime)

        {:cont, {:ok, acc ++ [value]}}
      else
        _ -> {:halt, Policy.error(:invalid_delivery)}
      end
    end)
  end

  defp media_kind("image/" <> _, _, _, _), do: "image"
  defp media_kind("audio/" <> _, _, _, _), do: "audio"
  defp media_kind("video/" <> _, _, _, _), do: "video"
  defp media_kind(mime, _, _, _) when is_binary(mime), do: "file"

  defp media_kind(_, type, filename, url) do
    reference = filename || if(is_binary(url), do: URI.parse(url).path) || ""
    extension = Path.extname(reference) |> String.trim_leading(".") |> String.downcase()
    type = if is_binary(type), do: String.downcase(type), else: extension
    type = if type in ["", "unknown"], do: extension, else: type

    cond do
      type in ~w(avif bmp gif heic heif jpeg jpg png svg tif tiff webp) -> "image"
      type in ~w(aac flac m4a mp3 ogg wav) -> "audio"
      type in ~w(avi m4v mkv mov mp4 webm) -> "video"
      true -> "file"
    end
  end

  defp non_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp non_blank(_), do: nil

  defp normalized_mime(value) do
    case non_blank(value) do
      nil -> nil
      value -> value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
    end
  end

  defp actor(message, client) do
    profile = field(message, "user_profile") || field(message, "bot_profile") || %{}
    bot = field(message, "bot_id")
    id = field(message, "user") || if(is_binary(bot), do: "bot:" <> bot, else: field(profile, "id"))

    %{
      "id" => id,
      "username" => field(message, "username") || field(profile, "name"),
      "display_name" => field(profile, "display_name") || field(profile, "real_name") || field(profile, "name"),
      "is_bot" => not is_nil(field(message, "bot_id")),
      "is_self" => id in [Client.options(client)[:bot_user_id], Client.options(client)[:bot_id]]
    }
    |> present()
  end

  defp lifecycle_actor(current, previous, client) do
    selected = actor(current, client)
    if is_binary(selected["id"]), do: selected, else: actor(previous, client)
  end

  defp protocol_type(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp protocol_type(value), do: value

  defp message_text(message) do
    text = field(message, "text")

    comment =
      field(message, "initial_comment") |> field("comment") ||
        Enum.find_value(field(message, "files") || [], &(field(&1, "initial_comment") |> field("comment")))

    if is_binary(non_blank(text)), do: text, else: comment || ""
  end

  defp mentions(text) when is_binary(text), do: Regex.scan(~r/<@([^>]+)>/, text) |> Enum.map(&Enum.at(&1, 1))
  defp mentions(_text), do: []
  defp mentions_bot?(message, client), do: Client.options(client)[:bot_user_id] in mentions(message_text(message))
  defp conversation_kind("D" <> _), do: "direct"
  defp conversation_kind("G" <> _), do: "group"
  defp conversation_kind("C" <> _), do: "channel"
  defp conversation_kind(_), do: "unknown"

  defp build(context, definition, ordinal, data) do
    data =
      data
      |> present()
      |> Map.put("delivery_id", context.delivery)
      |> Map.put("item_id", context.item <> ":" <> ordinal)

    data = if definition == MembershipChanged, do: Map.put_new(data, "previous", nil), else: data
    subject = if data["room_id"], do: Identity.conversation_subject(context.client.id, data["room_id"])
    definition.new(data, source: context.client.source, subject: subject)
  end

  defp failed(context, code, kind, room, ordinal \\ "failure") do
    data = %{"code" => code, "provider_kind" => kind, "item_index" => 0, "room_id" => room}
    build(context, NormalizationFailed, ordinal, data)
  end

  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
  defp present(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp select(map, keys), do: Map.new(keys, &{&1, field(map, &1)}) |> present()

  defp digest(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic])) |> Base.encode16(case: :lower)

  defp canonical(%_{} = value), do: canonical(Map.from_struct(value))

  defp canonical(value) when is_map(value),
    do: Enum.map(value, fn {key, item} -> {to_string(key), canonical(item)} end) |> Enum.sort()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(_value), do: throw(:invalid_provider_input)
  defp field(%_{} = value, key), do: field(Map.from_struct(value), key)

  defp field(value, key) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, result} ->
        result

      :error ->
        Enum.find_value(value, fn {name, result} ->
          if is_atom(name) and Atom.to_string(name) == key, do: {:found, result}
        end)
        |> case do
          {:found, result} -> result
          nil -> nil
        end
    end
  end

  defp field(_value, _key), do: nil
end
