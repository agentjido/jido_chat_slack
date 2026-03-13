defmodule Jido.Chat.Slack.SendOptions do
  @moduledoc """
  Typed options for Slack `send_message/3`.
  """

  alias Jido.Chat.Slack.Transport.ReqClient

  @schema Zoi.struct(
            __MODULE__,
            %{
              token: Zoi.string() |> Zoi.nullish(),
              transport: Zoi.any() |> Zoi.default(ReqClient),
              req: Zoi.any() |> Zoi.nullish(),
              blocks: Zoi.any() |> Zoi.nullish(),
              attachments: Zoi.any() |> Zoi.nullish(),
              thread_ts: Zoi.any() |> Zoi.nullish(),
              reply_broadcast: Zoi.boolean() |> Zoi.nullish(),
              unfurl_links: Zoi.boolean() |> Zoi.nullish(),
              unfurl_media: Zoi.boolean() |> Zoi.nullish(),
              username: Zoi.string() |> Zoi.nullish(),
              icon_emoji: Zoi.string() |> Zoi.nullish(),
              icon_url: Zoi.string() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema

  def new(%__MODULE__{} = opts), do: opts
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()
  def new(opts) when is_map(opts), do: Jido.Chat.Schema.parse!(__MODULE__, @schema, opts)

  @spec payload_opts(t()) :: map()
  def payload_opts(%__MODULE__{} = opts) do
    %{}
    |> maybe_put("blocks", opts.blocks)
    |> maybe_put("attachments", opts.attachments)
    |> maybe_put("thread_ts", opts.thread_ts && to_string(opts.thread_ts))
    |> maybe_put("reply_broadcast", opts.reply_broadcast)
    |> maybe_put("unfurl_links", opts.unfurl_links)
    |> maybe_put("unfurl_media", opts.unfurl_media)
    |> maybe_put("username", opts.username)
    |> maybe_put("icon_emoji", opts.icon_emoji)
    |> maybe_put("icon_url", opts.icon_url)
  end

  @spec transport_opts(t()) :: keyword()
  def transport_opts(%__MODULE__{} = opts) do
    []
    |> maybe_kw(:token, opts.token)
    |> maybe_kw(:req, opts.req)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_kw(keyword, _key, nil), do: keyword
  defp maybe_kw(keyword, key, value), do: Keyword.put(keyword, key, value)
end
