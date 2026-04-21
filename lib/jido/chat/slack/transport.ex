defmodule Jido.Chat.Slack.Transport do
  @moduledoc """
  Transport contract for Slack Web API operations.
  """

  @type api_result :: {:ok, map() | boolean()} | {:error, term()}

  @callback send_message(
              channel_id :: String.t() | integer(),
              text :: String.t(),
              opts :: keyword()
            ) :: api_result()

  @callback send_file(
              channel_id :: String.t() | integer(),
              upload :: Jido.Chat.FileUpload.t(),
              opts :: keyword()
            ) :: api_result()

  @callback edit_message(
              channel_id :: String.t() | integer(),
              message_id :: String.t() | integer(),
              text :: String.t(),
              opts :: keyword()
            ) :: api_result()

  @callback delete_message(
              channel_id :: String.t() | integer(),
              message_id :: String.t() | integer(),
              opts :: keyword()
            ) :: api_result()

  @callback fetch_metadata(channel_id :: String.t() | integer(), opts :: keyword()) ::
              api_result()

  @callback fetch_thread(channel_id :: String.t() | integer(), opts :: keyword()) ::
              api_result()

  @callback fetch_message(
              channel_id :: String.t() | integer(),
              message_id :: String.t() | integer(),
              opts :: keyword()
            ) :: api_result()

  @callback fetch_messages(channel_id :: String.t() | integer(), opts :: keyword()) ::
              api_result()

  @callback fetch_channel_messages(channel_id :: String.t() | integer(), opts :: keyword()) ::
              api_result()

  @callback list_threads(channel_id :: String.t() | integer(), opts :: keyword()) ::
              api_result()

  @callback add_reaction(
              channel_id :: String.t() | integer(),
              message_id :: String.t() | integer(),
              emoji :: String.t(),
              opts :: keyword()
            ) :: api_result()

  @callback remove_reaction(
              channel_id :: String.t() | integer(),
              message_id :: String.t() | integer(),
              emoji :: String.t(),
              opts :: keyword()
            ) :: api_result()

  @callback post_ephemeral(
              channel_id :: String.t() | integer(),
              user_id :: String.t() | integer(),
              text :: String.t(),
              opts :: keyword()
            ) :: api_result()

  @callback open_dm(user_id :: String.t() | integer(), opts :: keyword()) ::
              {:ok, String.t() | integer()} | {:error, term()}

  @callback open_modal(trigger_id :: String.t(), payload :: map(), opts :: keyword()) ::
              api_result()
end
