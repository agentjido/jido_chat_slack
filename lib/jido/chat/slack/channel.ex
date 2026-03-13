defmodule Jido.Chat.Slack.Channel do
  @moduledoc """
  Compatibility wrapper for legacy `Jido.Chat.Channel` integrations.

  New integrations should use `Jido.Chat.Slack.Adapter`.
  """

  @behaviour Jido.Chat.Channel

  alias Jido.Chat.Slack.Adapter

  @impl true
  defdelegate channel_type(), to: Adapter

  @impl true
  def capabilities do
    [
      :text,
      :file,
      :reactions,
      :threads,
      :message_edit,
      :message_delete,
      :actions,
      :slash_commands,
      :modals,
      :interaction_ephemeral,
      :webhook_secret
    ]
  end

  @impl true
  defdelegate transform_incoming(payload), to: Adapter

  @impl true
  defdelegate send_message(channel_id, text, opts), to: Adapter

  @impl true
  defdelegate edit_message(channel_id, message_id, text, opts), to: Adapter

  @doc "Deletes a message when supported by Slack permissions."
  @spec delete_message(String.t() | integer(), String.t() | integer(), keyword()) ::
          :ok | {:error, term()}
  defdelegate delete_message(channel_id, message_id, opts), to: Adapter

  @doc "Slack typing indicators are not supported through this adapter."
  @spec start_typing(String.t() | integer(), keyword()) :: :ok | {:error, term()}
  defdelegate start_typing(channel_id, opts), to: Adapter

  @doc "Fetches Slack conversation metadata and normalizes to `Jido.Chat.ChannelInfo`."
  @spec fetch_metadata(String.t() | integer(), keyword()) ::
          {:ok, Jido.Chat.ChannelInfo.t()} | {:error, term()}
  defdelegate fetch_metadata(channel_id, opts), to: Adapter

  @doc "Fetches Slack thread metadata and normalizes to `Jido.Chat.Thread`."
  @spec fetch_thread(String.t() | integer(), keyword()) ::
          {:ok, Jido.Chat.Thread.t()} | {:error, term()}
  defdelegate fetch_thread(channel_id, opts), to: Adapter

  @doc "Fetches a single Slack message and normalizes to `Jido.Chat.Message`."
  @spec fetch_message(String.t() | integer(), String.t() | integer(), keyword()) ::
          {:ok, Jido.Chat.Message.t()} | {:error, term()}
  defdelegate fetch_message(channel_id, message_id, opts), to: Adapter

  @doc "Opens a DM conversation with a user."
  @spec open_dm(String.t() | integer(), keyword()) ::
          {:ok, String.t() | integer()} | {:error, term()}
  defdelegate open_dm(user_id, opts), to: Adapter

  @doc "Posts a native Slack ephemeral message."
  @spec post_ephemeral(String.t() | integer(), String.t() | integer(), String.t(), keyword()) ::
          {:ok, Jido.Chat.EphemeralMessage.t()} | {:error, term()}
  defdelegate post_ephemeral(channel_id, user_id, text, opts), to: Adapter

  @doc "Opens a Slack modal when a `trigger_id` is provided."
  @spec open_modal(String.t() | integer(), map(), keyword()) ::
          {:ok, Jido.Chat.ModalResult.t()} | {:error, term()}
  defdelegate open_modal(channel_id, payload, opts), to: Adapter

  @doc "Adds reaction to a Slack message."
  @spec add_reaction(String.t() | integer(), String.t() | integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  defdelegate add_reaction(channel_id, message_id, emoji, opts), to: Adapter

  @doc "Removes reaction from a Slack message."
  @spec remove_reaction(String.t() | integer(), String.t() | integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  defdelegate remove_reaction(channel_id, message_id, emoji, opts), to: Adapter

  @doc "Fetches Slack message history and normalizes to `Jido.Chat.MessagePage`."
  @spec fetch_messages(String.t() | integer(), keyword()) ::
          {:ok, Jido.Chat.MessagePage.t()} | {:error, term()}
  defdelegate fetch_messages(channel_id, opts), to: Adapter

  @doc "Fetches Slack channel-level history and normalizes to `Jido.Chat.MessagePage`."
  @spec fetch_channel_messages(String.t() | integer(), keyword()) ::
          {:ok, Jido.Chat.MessagePage.t()} | {:error, term()}
  defdelegate fetch_channel_messages(channel_id, opts), to: Adapter

  @doc "Lists Slack thread roots synthesized from channel history."
  @spec list_threads(String.t() | integer(), keyword()) ::
          {:ok, Jido.Chat.ThreadPage.t()} | {:error, term()}
  defdelegate list_threads(channel_id, opts), to: Adapter

  @doc "Adapter webhook helper."
  @spec handle_webhook(Jido.Chat.t(), map(), keyword()) ::
          {:ok, Jido.Chat.t(), Jido.Chat.Incoming.t()} | {:error, term()}
  defdelegate handle_webhook(chat, payload, opts), to: Adapter
end
