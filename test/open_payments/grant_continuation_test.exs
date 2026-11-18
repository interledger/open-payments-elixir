defmodule OpenPayments.GrantContinuationTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Grant, Key, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}

  alias OpenPayments.Types.{
    AccessToken,
    Continuation,
    GrantContinuationRequest,
    GrantContinuationResponse
  }

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @continuation %{
    "uri" => "https://auth.example.com/tenant/opaque?id=1",
    "access_token" => %{"value" => "test-continuation-token"}
  }
  @result %{"continue" => @continuation}

  test "matches the pinned continuation POST, optional body and response status" do
    operation = Enum.find(Specification.operations(), &(&1.id == "post-continue"))
    assert operation.server == :auth
    assert operation.method == :post
    assert operation.success_statuses == [200]
    body = Specification.document(:auth)["paths"]["/continue/{id}"]["post"]["requestBody"]
    assert Map.get(body, "required", false) == false

    assert body["content"]["application/json"]["schema"]["$ref"] ==
             "#/components/schemas/continuation-request"
  end

  test "sends one signed authorized POST with an omitted body to the exact continuation URL" do
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(@result)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "continue-1"})
    target = "/tenant/opaque%2Fid/../resume?part=a%2Bb&part=2"
    continuation = continuation(base <> target)
    original = {client, continuation}

    assert {:ok, %GrantContinuationResponse{} = response} = Grant.continue(client, continuation)
    assert GrantContinuationResponse.continuation_only?(response)
    assert_receive {:http_request, wire}
    assert wire.method == "POST"
    assert wire.target == target
    assert wire.body == ""
    headers = Map.new(wire.headers)
    assert headers["authorization"] == "GNAP test-continuation-token"
    assert headers["accept"] == "application/json"
    assert headers["accept-encoding"] == "identity"
    assert headers["x-request-id"] == "continue-1"
    refute Map.has_key?(headers, "content-digest")
    refute Map.has_key?(headers, "content-type")
    assert verify_wire(wire)

    refute verify_wire(%{
             wire
             | headers:
                 List.keyreplace(
                   wire.headers,
                   "authorization",
                   0,
                   {"authorization", "GNAP changed-token"}
                 )
           })

    assert {client, continuation} == original
  end

  test "distinguishes nil, empty map and empty typed JSON bodies on the actual wire" do
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(@result)} end)
    client = client(allow_http: true)
    continuation = continuation(base <> "/resume")

    for payload <- [nil, %{}, %GrantContinuationRequest{}] do
      assert {:ok, _} = Grant.continue(client, continuation, payload)
      assert_receive {:http_request, wire}
      headers = Map.new(wire.headers)

      if is_nil(payload) do
        assert wire.body == ""
        refute Map.has_key?(headers, "content-digest")
      else
        assert wire.body == "{}"
        assert headers["content-type"] == "application/json"
        assert headers["content-length"] == "2"

        assert headers["content-digest"] ==
                 "sha-512=:#{Base.encode64(:crypto.hash(:sha512, "{}"))}:"
      end

      assert verify_wire(wire)
    end
  end

  test "sends a typed interaction reference and extensions with exact Unicode bytes and signed content" do
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(@result)} end)
    client = client(allow_http: true)
    wire_payload = %{"interact_ref" => "test-reference", "custom" => "Café 🌍"}
    {:ok, payload} = GrantContinuationRequest.from_map(wire_payload)

    assert {:ok, _} = Grant.continue(client, continuation(base <> "/resume"), payload)
    assert_receive {:http_request, wire}
    assert wire.body == Jason.encode!(payload)
    assert Jason.decode!(wire.body) == wire_payload
    headers = Map.new(wire.headers)
    assert headers["content-length"] == Integer.to_string(byte_size(wire.body))

    assert headers["content-digest"] ==
             "sha-512=:#{Base.encode64(:crypto.hash(:sha512, wire.body))}:"

    refute Map.has_key?(Jason.decode!(wire.body), "client")
    assert verify_wire(wire)
  end

  test "sends every official continuation request example" do
    examples =
      Specification.document(:auth)["paths"]["/continue/{id}"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    assert map_size(examples) > 0
    client = client(adapter: TransportAdapter)

    for {_name, %{"value" => wire}} <- examples do
      respond(@result, fn request -> assert Jason.decode!(request.body) == wire end)
      assert {:ok, _} = Grant.continue(client, continuation(), wire)
    end
  end

  test "decodes official continuation results and combined token/subject data without initial branch rules" do
    examples =
      Specification.document(:auth)["paths"]["/continue/{id}"]["post"]["responses"]["200"][
        "content"
      ]["application/json"]["examples"]

    values = Enum.map(examples, fn {_name, %{"value" => wire}} -> wire end)
    token = Enum.find_value(values, & &1["access_token"])
    subject = Enum.find_value(values, & &1["subject"])
    assert token && subject
    client = client(adapter: TransportAdapter)

    for wire <- [Map.merge(@result, %{"access_token" => token, "subject" => subject}) | values] do
      respond(wire)
      assert {:ok, response} = Grant.continue(client, continuation())
      assert GrantContinuationResponse.to_map(response) == wire
    end
  end

  test "uses the caller-supplied latest URI and rotated credential without persisting old data" do
    base =
      HTTPServer.start(fn request ->
        headers = Map.new(request.headers)

        if request.target == "/first" do
          assert headers["authorization"] == "GNAP first-token"

          next = %{
            "uri" => "http://" <> headers["host"] <> "/next?part=2",
            "access_token" => %{"value" => "next-token"}
          }

          {200, [], Jason.encode!(%{"continue" => next})}
        else
          assert request.target == "/next?part=2"
          assert headers["authorization"] == "GNAP next-token"
          {200, [], Jason.encode!(@result)}
        end
      end)

    client = client(allow_http: true)
    first = continuation(base <> "/first", "first-token")
    assert {:ok, response} = Grant.continue(client, first)
    assert {:ok, _} = Grant.continue(client, response.continue)
    assert first.access_token.value == "first-token"
    assert_receive {:http_request, %{target: "/first"}}
    assert_receive {:http_request, %{target: "/next?part=2"}}
    refute_receive {:http_request, _}, 30
  end

  test "shared clients keep continuation credentials separate across concurrent calls" do
    base =
      HTTPServer.start(fn request ->
        token = Map.new(request.headers)["authorization"]
        {200, [], Jason.encode!(Map.put(@result, "echo", token))}
      end)

    client = client(allow_http: true)

    tasks =
      for token <- ["token-a", "token-b"],
          do:
            {token,
             Task.async(fn ->
               Grant.continue(client, continuation(base <> "/" <> token, token))
             end)}

    for {token, task} <- tasks do
      assert {:ok, response} = Task.await(task)
      assert response.extensions["echo"] == "GNAP " <> token
    end

    for _ <- 1..2 do
      assert_receive {:http_request, wire}

      assert Map.new(wire.headers)["authorization"] ==
               "GNAP " <> String.trim_leading(wire.target, "/")

      assert verify_wire(wire)
    end
  end

  test "validates clients and typed continuation/credential roles before sending" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for bad <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :continue_grant}} =
               Grant.continue(bad, continuation())
    end

    {:ok, resource_token} =
      AccessToken.from_map(%{
        "value" => "resource-token",
        "manage" => "https://auth.example.com/token/id",
        "access" => []
      })

    original = continuation()

    for bad <- [
          nil,
          @continuation,
          resource_token,
          %{original | access_token: resource_token},
          %{original | access_token: %{original.access_token | value: nil}},
          %{original | wait: "30"},
          %{original | extensions: %{"uri" => "override"}}
        ] do
      assert {:error, %Error{kind: :validation, operation: :continue_grant}} =
               Grant.continue(client, bad)
    end
  end

  test "applies request URL and token68 rules after schema validation without leaking credentials" do
    no_request()
    client = client(adapter: TransportAdapter)

    for uri <- [
          "urn:example:continue",
          "http://localhost:3006/continue/id",
          "https://user@auth.example.com/resume",
          "https://auth.example.com/resume#fragment",
          "https://auth.example.com:65536/resume"
        ] do
      assert {:error, %Error{kind: :validation, operation: :continue_grant}} =
               Grant.continue(client, continuation(uri))
    end

    for token <- ["", "private token", "private\r\ntoken", "private🌍token"] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :continue_grant,
                validation_errors: [%{field: :access_token}]
              } = error} = Grant.continue(client, continuation(@continuation["uri"], token))

      refute inspect(Map.from_struct(error)) =~ "private"
    end

    uri = "https://auth.example.com:8443/tenant?part=1&part=2"
    respond(@result, fn request -> assert URI.to_string(request.url) == uri end)
    assert {:ok, _} = Grant.continue(client, continuation(uri))
  end

  test "revalidates typed or JSON payloads, rejects explicit-null references and preserves extension names" do
    no_request()
    client = client(adapter: TransportAdapter)

    for payload <- [
          [],
          true,
          "private-input",
          %URI{},
          %{"interact_ref" => nil},
          %{"interact_ref" => false},
          %{custom: true},
          %GrantContinuationRequest{interact_ref: false},
          %GrantContinuationRequest{extensions: %{"interact_ref" => "override"}}
        ] do
      assert {:error, %Error{kind: :validation, operation: :continue_grant} = error} =
               Grant.continue(client, continuation(), payload)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end

    payload = %{"interactRef" => "extension-value"}
    respond(@result, fn request -> assert Jason.decode!(request.body) == payload end)
    assert {:ok, _} = Grant.continue(client, continuation(), payload)
  end

  test "preserves wait metadata without SDK sleeping or automatic polling" do
    respond(@result, fn _ -> send(self(), :continued_once) end)
    client = client(adapter: TransportAdapter)
    original = continuation()

    for wait <- [-1, 0, 86_400] do
      assert {:ok, _} = Grant.continue(client, %{original | wait: wait})
      assert_received :continued_once
      refute_received :continued_once
    end
  end

  test "labels JSON, status, encoding and nested response failures safely" do
    client = client(adapter: TransportAdapter)

    for {status, body, headers, code} <- [
          {200, "not-json", [], "invalid_json"},
          {204, "", [], "unexpected_status"},
          {201, Jason.encode!(@result), [], "unexpected_status"},
          {200, Jason.encode!(@result), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"},
          {200, "null", [], "invalid_response"},
          {200, "{}", [], "invalid_response"}
        ] do
      raw_response(status, body, headers)

      assert {:error,
              %Error{kind: :decoding, status: ^status, code: ^code, operation: :continue_grant}} =
               Grant.continue(client, continuation())
    end

    respond(put_in(@result, ["continue", "access_token", "value"], ["private-next-token"]))

    assert {:error,
            %Error{
              kind: :decoding,
              status: 200,
              code: "invalid_response",
              validation_errors: [%{field: "continue.access_token.value"}]
            } = error} = Grant.continue(client, continuation())

    refute inspect(Map.from_struct(error)) =~ "private-next-token"
  end

  test "preserves GNAP HTTP errors and status without exposing raw failure bodies" do
    client = client(adapter: TransportAdapter)

    for {status, code} <- [
          {400, "invalid_interaction"},
          {401, "invalid_continuation"},
          {403, "request_denied"},
          {404, "unknown_request"},
          {429, "too_many_requests"}
        ] do
      raw_response(
        status,
        Jason.encode!(%{"error" => code, "error_description" => "Not permitted"})
      )

      assert {:error,
              %Error{kind: :http, status: ^status, code: ^code, operation: :continue_grant}} =
               Grant.continue(client, continuation())
    end

    raw_response(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             Grant.continue(client, continuation())

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not replay after timeouts, dropped connections, redirects or server errors" do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, %Error{kind: :transport, code: "timeout", operation: :continue_grant}} =
             Grant.continue(client(adapter: TransportAdapter), continuation())

    base =
      HTTPServer.start(fn request ->
        case request.target do
          "/drop" -> :close
          "/redirect" -> {307, [{"location", "/other"}], "failed"}
          _ -> {503, [], "unavailable"}
        end
      end)

    client = client(allow_http: true)

    for {path, kind} <- [{"/drop", :transport}, {"/redirect", :http}, {"/unavailable", :http}] do
      assert {:error, %Error{kind: ^kind, operation: :continue_grant}} =
               Grant.continue(client, continuation(base <> path))

      assert_receive {:http_request, %{method: "POST", target: ^path}}
      refute_receive {:http_request, _}, 30
    end
  end

  defp continuation(uri \\ @continuation["uri"], token \\ "test-continuation-token") do
    {:ok, continuation} =
      Continuation.from_map(%{"uri" => uri, "access_token" => %{"value" => token}})

    continuation
  end

  defp client(opts) do
    {:ok, key} = Key.from_seed(@seed, "example-key-1")

    {:ok, client} =
      Client.new_authenticated(
        Keyword.merge([wallet_address: "https://client.example.com/alice", key: key], opts)
      )

    client
  end

  defp no_request,
    do: Process.put({TransportAdapter, :callback}, fn _ -> flunk("unexpected HTTP request") end)

  defp respond(data, check \\ fn _ -> :ok end) do
    Process.put({TransportAdapter, :callback}, fn request ->
      check.(request)
      {request, Req.Response.new(body: Jason.encode!(data))}
    end)
  end

  defp raw_response(status, body, headers \\ []) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body, headers: headers)}
    end)
  end

  # Reconstruct independently from captured HTTP, including authorization.
  defp verify_wire(wire) do
    headers = Map.new(wire.headers)

    content =
      if Map.has_key?(headers, "content-digest"),
        do: ~w(content-digest content-length content-type),
        else: []

    components = ["@method", "@target-uri", "authorization"] ++ content
    "sig1=" <> params = headers["signature-input"]

    expected =
      "(" <> Enum.map_join(components, " ", &~s("#{&1}")) <> ~s|);keyid="example-key-1";created=|

    assert String.starts_with?(params, expected)
    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, headers["signature"])
    url = "http://" <> headers["host"] <> wire.target

    lines = [
      ~s("@method": #{wire.method}),
      ~s("@target-uri": #{url}),
      ~s("authorization": #{headers["authorization"]})
    ]

    lines =
      lines ++
        Enum.map(content, fn field -> ~s("#{field}": #{headers[field]}) end) ++
        [~s("@signature-params": #{params})]

    {:ok, key} = Key.from_seed(@seed, "example-key-1")
    public = key |> Key.public_jwk() |> Map.fetch!(:x) |> Base.url_decode64!(padding: false)

    :crypto.verify(:eddsa, :none, Enum.join(lines, "\n"), Base.decode64!(encoded), [
      public,
      :ed25519
    ])
  end
end
