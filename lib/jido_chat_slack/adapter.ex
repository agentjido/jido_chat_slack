defmodule Jido.Chat.Slack.Adapter do
  @moduledoc "Stateless Slack adapter for Chat request and result Signals."
  use Jido.Chat.Adapter
  alias Jido.Chat.Slack.{Normalizer, Operations}

  @impl true
  def channel_type, do: :slack
  @impl true
  def default_transport, do: Jido.Chat.Slack.Transport.ReqClient
  @impl true
  def operations, do: Jido.Chat.Slack.operations()
  @impl true
  def event_definitions, do: Jido.Chat.Slack.event_definitions()

  @native [
    :send_message,
    :send_file,
    :edit_message,
    :delete_message,
    :fetch_metadata,
    :fetch_thread,
    :fetch_message,
    :get_user,
    :fetch_subject,
    :get_thread_participants,
    :mark_as_read,
    :download_file,
    :add_reaction,
    :remove_reaction,
    :post_ephemeral,
    :open_dm,
    :fetch_messages,
    :list_threads,
    :open_modal,
    :load_options
  ]
  @impl true
  def capabilities do
    Map.new(Jido.Chat.Operations.Definitions.all(), fn {_, {_, operation, _, _, _}} ->
      {operation, if(operation in @native, do: :native, else: :unsupported)}
    end)
  end

  @impl true
  def invoke(client, request, opts), do: Operations.invoke(client, request, opts)
  @impl true
  def normalize(client, input, _opts), do: Normalizer.normalize(client, input)
end
