defmodule Jido.Chat.Slack.WebhookTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Slack.{Adapter, Webhook}

  test "signature verification uses the exact body, timestamp, and Client secret" do
    secret = "signing-secret"
    body = ~s({"type":"event_callback"})
    timestamp = "1700000000"

    signature =
      "v0=" <>
        Base.encode16(:crypto.mac(:hmac, :sha256, secret, "v0:#{timestamp}:#{body}"), case: :lower)

    client = Jido.Chat.Client.new!(Adapter, id: "slack-webhook", credentials: %{signing_secret: secret})
    headers = %{"X-Slack-Request-Timestamp" => timestamp, "X-Slack-Signature" => signature}

    assert :ok = Webhook.verify(client, body, headers, now: 1_700_000_000)
    assert {:error, :invalid_signature} = Webhook.verify(client, body <> " ", headers, now: 1_700_000_000)
    assert {:error, :invalid_signature} = Webhook.verify(client, body, headers, now: 1_700_000_301)
    assert {:error, :missing_signing_secret} = Webhook.verify(%{client | credentials: %{}}, body, headers)
  end

  test "JSON, slash command, and interactive form bodies decode without HTTP ownership" do
    assert {:ok, %{"type" => "event_callback"}} =
             Webhook.decode(~s({"type":"event_callback"}), %{"content-type" => "application/json"})

    assert {:ok, %{"command" => "/ask", "text" => "hello"}} =
             Webhook.decode("command=%2Fask&text=hello", %{
               "content-type" => "application/x-www-form-urlencoded"
             })

    payload = URI.encode_query(%{"payload" => Jason.encode!(%{"type" => "block_actions"})})

    assert {:ok, %{"type" => "block_actions"}} =
             Webhook.decode(payload, %{"content-type" => "application/x-www-form-urlencoded"})

    assert {:error, :invalid_body} = Webhook.decode("invalid", %{"content-type" => "application/json"})
    assert Webhook.response({:reply, "ok"}) == %{status: 200, body: "ok"}
  end
end
