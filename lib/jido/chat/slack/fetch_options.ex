defmodule Jido.Chat.Slack.FetchOptions do
  @moduledoc """
  Typed options for Slack history fetch operations.
  """

  alias Jido.Chat.Slack.Transport.ReqClient

  @schema Zoi.struct(
            __MODULE__,
            %{
              token: Zoi.string() |> Zoi.nullish(),
              transport: Zoi.any() |> Zoi.default(ReqClient),
              req: Zoi.any() |> Zoi.nullish(),
              cursor: Zoi.string() |> Zoi.nullish(),
              limit: Zoi.integer() |> Zoi.default(50),
              direction: Zoi.enum([:forward, :backward]) |> Zoi.default(:backward),
              thread_ts: Zoi.any() |> Zoi.nullish(),
              inclusive: Zoi.boolean() |> Zoi.nullish()
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

  @spec transport_opts(t()) :: keyword()
  def transport_opts(%__MODULE__{} = opts) do
    []
    |> maybe_kw(:token, opts.token)
    |> maybe_kw(:req, opts.req)
    |> maybe_kw(:cursor, opts.cursor)
    |> maybe_kw(:thread_ts, opts.thread_ts && to_string(opts.thread_ts))
    |> maybe_kw(:inclusive, opts.inclusive)
    |> Keyword.put(:limit, opts.limit)
    |> Keyword.put(:direction, opts.direction)
  end

  defp maybe_kw(keyword, _key, nil), do: keyword
  defp maybe_kw(keyword, key, value), do: Keyword.put(keyword, key, value)
end
