defmodule Jido.Chat.Slack.ProviderErrorsTest do
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias Jido.Chat.Slack.{Adapter, Operations}

  defmodule Transport do
    def send_message(_, _, opts), do: {:error, {:slack_api_error, opts[:token], %{}}}
    def delete_message(_, _, _), do: {:error, :offline}
    def fetch_messages(_, _), do: {:ok, %{messages: :invalid}}
    def list_threads(_, _), do: {:ok, %{threads: :invalid}}
  end

  test "provider rejections have explicit outcomes and stable categories" do
    for {error, expected} <- [
          {"invalid_auth", :unauthorized},
          {"missing_scope", :forbidden},
          {"message_not_found", :not_found},
          {"ratelimited", :rate_limited},
          {"invalid_blocks", :provider_failure}
        ] do
      client = Jido.Chat.Client.new!(Adapter, id: "errors", credentials: %{token: error}, transport: Transport)

      request =
        Jido.Chat.Signal.SendMessage.new!(%{
          "client_id" => client.id,
          "request_id" => "req",
          "room_id" => "C",
          "text" => "hi"
        })

      assert {:error, %{code: ^expected, signal: failed}} = Jido.Chat.execute(client, request)
      assert failed.data["outcome"] == "rejected"
    end

    client = Jido.Chat.Client.new!(Adapter, id: "errors", credentials: %{token: "test"}, transport: Transport)

    request =
      Jido.Chat.Signal.DeleteMessage.new!(%{
        "client_id" => client.id,
        "request_id" => "req",
        "room_id" => "C",
        "message_id" => "1"
      })

    assert {:error, _} = Jido.Chat.execute(client, request)
    assert {:error, :invalid_provider_result} = Operations.fetch_messages("C", transport: Transport)
    assert {:error, :invalid_provider_result} = Operations.list_threads("C", transport: Transport)
  end

  def load_options(_), do: %{options: []}

  test "host option loaders accept map results and reject invalid results" do
    event =
      Jido.Chat.Signal.LoadOptions.new!(%{
        "client_id" => "test",
        "request_id" => "req",
        "interaction_id" => "I",
        "query" => "a"
      })

    for loader <- [fn _, _ -> %{options: []} end, {__MODULE__, :load_options, []}] do
      assert {:ok, %{complete: true}} = Operations.load_options(event, options_loader: loader)
    end

    assert {:error, :unsupported} = Operations.load_options(event)
    assert {:error, :offline} = Operations.load_options(event, options_loader: fn _ -> {:error, :offline} end)

    assert {:error, {:invalid_options_loader_result, :invalid}} =
             Operations.load_options(event, options_loader: fn _ -> :invalid end)

    for opts <- [[limit: 0], [page_size: 201], [max_pages: 101]] do
      assert {:error, _} = Operations.get_thread_participants("C", [thread_id: "1"] ++ opts)
    end

    assert {:error, :missing_thread_ts} = Operations.get_thread_participants("C")
    assert {:error, :invalid_media_reference} = Operations.fetch_media(%{})
    assert {:error, :missing_trigger_id} = Operations.open_modal("C", Jido.Chat.Modal.new(%{title: "Form"}))
  end

  test "webhook verification uses exact raw bytes and a bounded timestamp window" do
    timestamp = "1000"
    body = "{\"text\":\"hello\"}"

    signature =
      "v0=" <> Base.encode16(:crypto.mac(:hmac, :sha256, "secret", "v0:" <> timestamp <> ":" <> body), case: :lower)

    request = %{headers: [{"x-slack-request-timestamp", timestamp}, {"x-slack-signature", signature}], raw: body}
    assert :ok = Operations.verify_webhook(request, signing_secret: "secret", now: 1_000)
    assert {:error, :invalid_signature} = Operations.verify_webhook(request, signing_secret: "wrong", now: 1_000)
    assert {:error, :stale_timestamp} = Operations.verify_webhook(request, signing_secret: "secret", now: 2_000)

    assert {:error, :stale_timestamp} =
             Operations.verify_webhook(
               %{request | headers: [{"x-slack-request-timestamp", "bad"}, {"x-slack-signature", signature}]},
               signing_secret: "secret"
             )

    assert {:error, :missing_timestamp} = Operations.verify_webhook(%{request | headers: []}, signing_secret: "secret")

    assert {:error, :missing_signature} =
             Operations.verify_webhook(%{request | headers: [{"x-slack-request-timestamp", timestamp}]},
               signing_secret: "secret",
               now: 1_000
             )

    assert {:error, :missing_raw_body} = Operations.verify_webhook(%{headers: []}, signing_secret: "secret")
    assert Operations.format_webhook_response({:error, :invalid_signature}).status == 401
    assert Operations.format_webhook_response({:error, :bad}).status == 400

    for payload <- [
          %{payload: Jason.encode!(%{"type" => "url_verification", "challenge" => "test"})},
          URI.encode_query(%{"payload" => Jason.encode!(%{"type" => "url_verification", "challenge" => "test"})})
        ] do
      response = Operations.format_webhook_response({:ok, []}, request: %{payload: payload})
      assert response.body == "test"
    end

    assert Operations.format_webhook_response({:ok, []}, request: %{payload: nil, raw: "bad"}).status == 200
  end
end
