defmodule Jido.Chat.Slack.MetadataOptions do
  @moduledoc """
  Typed options for Slack `fetch_metadata/2`.
  """

  alias Jido.Chat.Slack.Transport.ReqClient

  @schema Zoi.struct(
            __MODULE__,
            %{
              token: Zoi.string() |> Zoi.nullish(),
              transport: Zoi.any() |> Zoi.default(ReqClient),
              req: Zoi.any() |> Zoi.nullish(),
              include_num_members: Zoi.boolean() |> Zoi.default(true)
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
    |> Keyword.put(:include_num_members, opts.include_num_members)
  end

  defp maybe_kw(keyword, _key, nil), do: keyword
  defp maybe_kw(keyword, key, value), do: Keyword.put(keyword, key, value)
end
