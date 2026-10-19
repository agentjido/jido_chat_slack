defmodule Jido.Chat.Slack.LiveHelpers do
  @moduledoc false
  import ExUnit.Assertions
  alias Jido.Chat
  @trace "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
  @doc "Builds a live request with fixed trace context."
  def request(client, definition, data) do
    definition.new!(Map.merge(%{"client_id" => client.id, "request_id" => Jido.Signal.ID.generate!()}, data),
      source: client.source,
      extensions: %{"traceparent" => @trace, "tracestate" => "test=slack-live"}
    )
  end

  @doc "Executes a live command and validates its completion context."
  def execute(client, definition, data, options \\ []) do
    request = request(client, definition, data)

    case Chat.execute(client, request, options: options) do
      {:ok, complete} ->
        check(client, complete, request.data["request_id"])
        assert complete.extensions["jidocausationid"] == request.id
        assert complete.data["operation"] == request.type
        complete.data["result"]

      {:error, error} ->
        flunk("Slack operation failed: #{inspect(error.code)}")
    end
  end

  @doc "Calls a public Chat helper and validates its completion context."
  def facade(client, method, arguments, options \\ []) do
    request_id = Jido.Signal.ID.generate!()

    options =
      Keyword.merge(options,
        request_id: request_id,
        signal_options: [extensions: %{"traceparent" => @trace, "tracestate" => "test=slack-live"}]
      )

    case apply(Chat, method, [client | arguments] ++ [options]) do
      {:ok, complete} ->
        check(client, complete, request_id)
        complete.data["result"]

      {:error, error} ->
        flunk("Slack facade failed: #{inspect(error.code)}")
    end
  end

  @doc "Checks completion identity, privacy, and catalog round trips."
  def check(client, complete, request_id) do
    assert complete.source == client.source
    assert complete.data["client_id"] == client.id
    assert complete.data["request_id"] == request_id
    assert complete.extensions["traceparent"] == @trace
    assert complete.extensions["tracestate"] == "test=slack-live"
    assert is_binary(complete.extensions["jidocausationid"])
    assert {:ok, json} = Jido.Signal.Serialization.serialize(complete)
    refute json =~ "xoxb-"
    refute json =~ "xapp-"
    assert {:ok, decoded} = Jido.Signal.Catalog.decode(Chat.catalog(client), json)
    assert decoded == complete
  end

  @doc "Calls a Slack API method for test setup, observation, or cleanup."
  def api(client, method, form) do
    {:ok, response} =
      Req.post("https://slack.com/api/" <> method, auth: {:bearer, client.credentials.token}, form: form)

    assert response.body["ok"] == true, "Slack fixture API failed: #{response.body["error"]}"
    response.body
  end
end
