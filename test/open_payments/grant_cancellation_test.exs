defmodule OpenPayments.GrantCancellationTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Grant, Key, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{AccessToken, Continuation, GrantContinuationResponse, GrantResponse}

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @uri "https://auth.example.com/tenant/opaque?part=1"
  @token %{
    "value" => "resource-token",
    "manage" => "https://auth.example.com/token/id",
    "access" => []
  }

  test "matches the pinned cancellation method, no-body contract and documented statuses" do
    operation = Enum.find(Specification.operations(), &(&1.id == "delete-continue"))
    assert operation.server == :auth
    assert operation.method == :delete
    assert operation.success_statuses == [204]
    delete = Specification.document(:auth)["paths"]["/continue/{id}"]["delete"]
    refute Map.has_key?(delete, "requestBody")
    assert Map.keys(delete["responses"]) |> Enum.sort() == ~w(204 401 404)
    refute Map.has_key?(delete["responses"]["204"], "content")
  end

  test "sends an exact signed authorized DELETE without body or inferred provider path" do
    base = HTTPServer.start(fn _ -> {204, [], ""} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "cancel-1"})
    target = "/tenant/opaque%2Fid/../cancel?part=a%2Bb&part=2"
    continuation = continuation(base <> target)
    original = {client, continuation}

    assert :ok = Grant.cancel(client, continuation)
    assert_receive {:http_request, wire}
    assert wire.method == "DELETE"
    assert wire.target == target
    assert wire.body == ""
    headers = Map.new(wire.headers)
    assert headers["authorization"] == "GNAP test-continuation-token"
    assert headers["accept"] == "application/json"
    assert headers["accept-encoding"] == "identity"
    assert headers["x-request-id"] == "cancel-1"
    refute Map.has_key?(headers, "content-digest")
    refute Map.has_key?(headers, "content-type")
    assert verify_wire(wire)
    refute verify_wire(%{wire | target: target <> "tampered"})

    refute verify_wire(%{
             wire
             | headers:
                 List.keyreplace(
                   wire.headers,
                   "authorization",
                   0,
                   {"authorization", "GNAP wrong-token"}
                 )
           })

    assert {client, continuation} == original
  end

  test "accepts 204 by status without attempting JSON parsing or content decoding" do
    client = client(adapter: TransportAdapter)

    for {body, headers} <- [
          {"", []},
          {"private-uninterpreted-body", [{"content-encoding", "gzip"}]}
        ] do
      respond(204, body, headers)
      assert :ok = Grant.cancel(client, continuation())
    end
  end

  test "rejects invalid clients and continuation data or resource-token substitutions before transport" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for bad <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :cancel_grant}} =
               Grant.cancel(bad, continuation())
    end

    {:ok, resource_token} = AccessToken.from_map(@token)
    original = continuation()

    for bad <- [
          nil,
          %{},
          resource_token,
          %{original | access_token: resource_token},
          %{original | access_token: %{original.access_token | value: nil}},
          %{original | uri: "relative"},
          %{original | wait: false},
          %{original | extensions: %{"uri" => "override"}}
        ] do
      assert {:error, %Error{kind: :validation, operation: :cancel_grant}} =
               Grant.cancel(client, bad)
    end

    assert {:error, %Error{validation_errors: [%{field: "access_token.value"}]} = error} =
             Grant.cancel(client, %{
               original
               | access_token: %{original.access_token | value: ["private-token"]}
             })

    refute inspect(Map.from_struct(error)) =~ "private-token"
  end

  test "applies outgoing URL/token68 policies and preserves explicit HTTPS ports and queries" do
    no_request()
    client = client(adapter: TransportAdapter)

    for uri <- [
          "urn:example:continuation",
          "http://localhost:3006/resume",
          "https://user@auth.example.com/resume",
          "https://auth.example.com/resume#fragment",
          "https://auth.example.com:65536/resume"
        ] do
      assert {:error, %Error{kind: :validation, operation: :cancel_grant}} =
               Grant.cancel(client, continuation(uri))
    end

    for token <- ["", "private token", "private\r\ntoken", "private🌍token"] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :cancel_grant,
                validation_errors: [%{field: :access_token}]
              } = error} = Grant.cancel(client, continuation(@uri, token))

      refute inspect(Map.from_struct(error)) =~ "private"
    end

    uri = "https://auth.example.com:8443/tenant/opaque?part=1&part=2"

    Process.put({TransportAdapter, :callback}, fn request ->
      assert URI.to_string(request.url) == uri
      {request, Req.Response.new(status: 204, body: "")}
    end)

    assert :ok = Grant.cancel(client, continuation(uri))
  end

  test "uses the selected continuation URI and credential per call without mutating the client" do
    client = client(adapter: TransportAdapter)
    original = client

    for {uri, token} <- [
          {"https://auth.example.com/first", "first-token"},
          {"https://auth.example.com/latest?part=2", "latest-token"}
        ] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert URI.to_string(request.url) == uri
        assert Req.Request.get_header(request, "authorization") == ["GNAP " <> token]
        assert request.body == nil
        {request, Req.Response.new(status: 204, body: "")}
      end)

      assert :ok = Grant.cancel(client, continuation(uri, token))
    end

    assert client == original
  end

  test "shared clients keep cancellation credentials isolated during concurrent calls" do
    base = HTTPServer.start(fn _ -> {204, [], ""} end)
    client = client(allow_http: true)

    tasks =
      for token <- ["token-a", "token-b"],
          do:
            Task.async(fn -> Grant.cancel(client, continuation(base <> "/" <> token, token)) end)

    for task <- tasks, do: assert(:ok = Task.await(task))

    for _ <- 1..2 do
      assert_receive {:http_request, wire}

      assert Map.new(wire.headers)["authorization"] ==
               "GNAP " <> String.trim_leading(wire.target, "/")

      assert verify_wire(wire)
    end
  end

  test "treats other success statuses as unexpected without interpreting their bodies" do
    client = client(adapter: TransportAdapter)

    for status <- [200, 201, 202, 205, 206, 299] do
      respond(status, "private-success-body")

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: "unexpected_status",
                operation: :cancel_grant
              } = error} = Grant.cancel(client, continuation())

      assert error.description == "Unexpected Open Payments response status"
      refute inspect(Map.from_struct(error)) =~ "private-success-body"
    end
  end

  test "retains GNAP and nested HTTP errors while omitting raw non-JSON failure bodies" do
    client = client(adapter: TransportAdapter)

    for {status, code} <- [{401, "invalid_continuation"}, {404, "invalid_request"}] do
      respond(status, Jason.encode!(%{"error" => code, "error_description" => "Not permitted"}))

      assert {:error,
              %Error{
                kind: :http,
                status: ^status,
                code: ^code,
                description: "Not permitted",
                operation: :cancel_grant
              }} = Grant.cancel(client, continuation())
    end

    respond(
      403,
      ~s({"error":{"code":"denied","description":"Denied","details":{"field":"grant"}}})
    )

    assert {:error,
            %Error{kind: :http, status: 403, code: "denied", details: %{"field" => "grant"}}} =
             Grant.cancel(client, continuation())

    respond(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             Grant.cancel(client, continuation())

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not replay cancellation after timeout, connection loss, redirect or server errors" do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, %Error{kind: :transport, code: "timeout", operation: :cancel_grant}} =
             Grant.cancel(client(adapter: TransportAdapter), continuation())

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
      assert {:error, %Error{kind: ^kind, operation: :cancel_grant}} =
               Grant.cancel(client, continuation(base <> path))

      assert_receive {:http_request, %{method: "DELETE", target: ^path}}
      refute_receive {:http_request, _}, 30
    end
  end

  test "requests, continues and cancels a grant using the latest continuation rather than the resource token" do
    base =
      HTTPServer.start(fn request ->
        headers = Map.new(request.headers)
        origin = "http://" <> headers["host"]

        case {request.method, request.target} do
          {"POST", "/auth"} ->
            refute Map.has_key?(headers, "authorization")

            result = %{
              "interact" => %{
                "redirect" => "https://auth.example.com/consent",
                "finish" => "test-finish"
              },
              "continue" => continuation_wire(origin <> "/first", "first-token")
            }

            {200, [], Jason.encode!(result)}

          {"POST", "/first"} ->
            assert headers["authorization"] == "GNAP first-token"
            assert request.body == ""

            result = %{
              "access_token" => @token,
              "continue" => continuation_wire(origin <> "/latest", "latest-token")
            }

            {200, [], Jason.encode!(result)}

          {"DELETE", "/latest"} ->
            assert headers["authorization"] == "GNAP latest-token"
            assert request.body == ""
            {204, [], ""}
        end
      end)

    client = client(allow_http: true)

    assert {:ok, initial} =
             Grant.request(client, base <> "/auth", %{"access_token" => %{"access" => []}})

    assert GrantResponse.pending?(initial)
    assert {:ok, continued} = Grant.continue(client, initial.continue)
    assert GrantContinuationResponse.has_access_token?(continued)
    assert continued.access_token.value == "resource-token"
    assert :ok = Grant.cancel(client, continued.continue)
    assert_receive {:http_request, %{method: "POST", target: "/auth"}}
    assert_receive {:http_request, %{method: "POST", target: "/first"}}
    assert_receive {:http_request, %{method: "DELETE", target: "/latest"} = wire}
    assert verify_wire(wire)
    refute_receive {:http_request, _}, 30
  end

  defp client(opts) do
    {:ok, key} = Key.from_seed(@seed, "example-key-1")

    {:ok, client} =
      Client.new_authenticated(
        Keyword.merge([wallet_address: "https://client.example.com/alice", key: key], opts)
      )

    client
  end

  defp continuation(uri \\ @uri, token \\ "test-continuation-token") do
    {:ok, continuation} = Continuation.from_map(continuation_wire(uri, token))
    continuation
  end

  defp continuation_wire(uri, token), do: %{"uri" => uri, "access_token" => %{"value" => token}}

  defp no_request,
    do: Process.put({TransportAdapter, :callback}, fn _ -> flunk("unexpected HTTP request") end)

  defp respond(status, body, headers \\ []) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body, headers: headers)}
    end)
  end

  # Independent wire reconstruction with the RFC 8032 public key for this seed.
  defp verify_wire(wire) do
    headers = Map.new(wire.headers)
    "sig1=" <> params = headers["signature-input"]

    assert String.starts_with?(
             params,
             ~s|("@method" "@target-uri" "authorization");keyid="example-key-1";created=|
           )

    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, headers["signature"])
    url = "http://" <> headers["host"] <> wire.target

    base =
      Enum.join(
        [
          ~s("@method": #{wire.method}),
          ~s("@target-uri": #{url}),
          ~s("authorization": #{headers["authorization"]}),
          ~s("@signature-params": #{params})
        ],
        "\n"
      )

    :crypto.verify(:eddsa, :none, base, Base.decode64!(encoded), [@public, :ed25519])
  end
end
