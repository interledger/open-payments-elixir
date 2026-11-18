defmodule OpenPayments.TokenRevocationTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Key, Specification, Token}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{AccessToken, ContinuationToken}

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @manage "https://auth.example.com/tenant/opaque/manage?part=1"
  @wire_token %{"value" => "test-resource-token", "manage" => @manage, "access" => []}

  test "matches the pinned revocation DELETE, no-body contract and documented statuses" do
    operation = Enum.find(Specification.operations(), &(&1.id == "delete-token"))
    assert operation.server == :auth
    assert operation.method == :delete
    assert operation.success_statuses == [204]
    delete = Specification.document(:auth)["paths"]["/token/{id}"]["delete"]
    refute Map.has_key?(delete, "requestBody")
    assert Map.keys(delete["responses"]) |> Enum.sort() == ~w(204 401 500)
    refute Map.has_key?(delete["responses"]["204"], "content")
  end

  test "sends one signed authorized DELETE to the token management URI with no body or inferred path" do
    base = HTTPServer.start(fn _ -> {204, [], ""} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "revoke-1"})
    target = "/tenant/opaque%2Fid/../manage?part=a%2Bb&part=2"
    token = token(base <> target)
    original = {client, token}

    assert :ok = Token.revoke(client, token)
    assert_receive {:http_request, wire}
    assert wire.method == "DELETE"
    assert wire.target == target
    assert wire.body == ""
    headers = Map.new(wire.headers)
    assert headers["authorization"] == "GNAP test-resource-token"
    assert headers["accept"] == "application/json"
    assert headers["accept-encoding"] == "identity"
    assert headers["x-request-id"] == "revoke-1"
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

    assert {client, token} == original
  end

  test "acknowledges only 204 without interpreting JSON or response content coding" do
    client = client(adapter: TransportAdapter)

    for {body, headers} <- [
          {"", []},
          {"private-uninterpreted-body", [{"content-encoding", "gzip"}]}
        ] do
      respond(204, body, headers)
      assert :ok = Token.revoke(client, token())
    end

    for status <- [200, 201, 202, 205, 206, 299] do
      respond(status, "private-success-body")

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: "unexpected_status",
                operation: :revoke_access_token
              } = error} = Token.revoke(client, token())

      refute inspect(Map.from_struct(error)) =~ "private-success-body"
    end
  end

  test "rejects invalid clients and token models or continuation credentials before transport" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for bad <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :revoke_access_token}} =
               Token.revoke(bad, token())
    end

    {:ok, continuation_token} =
      ContinuationToken.from_map(%{"value" => "test-continuation-token"})

    original = token()

    for bad <- [
          nil,
          @wire_token,
          continuation_token,
          %{original | value: nil},
          %{original | manage: "relative"},
          %{original | access: nil},
          %{original | expires_in: false}
        ] do
      assert {:error, %Error{kind: :validation, operation: :revoke_access_token}} =
               Token.revoke(client, bad)
    end

    assert {:error, %Error{validation_errors: [%{field: :value}]} = error} =
             Token.revoke(client, %{original | value: ["private-token"]})

    refute inspect(Map.from_struct(error)) =~ "private-token"
  end

  test "applies outgoing URL/token68 rules while allowing HTTPS ports and opaque queries" do
    no_request()
    client = client(adapter: TransportAdapter)

    for manage <- [
          "urn:example:manage",
          "http://localhost:3006/manage",
          "https://user@auth.example.com/manage",
          "https://auth.example.com/manage#fragment",
          "https://auth.example.com:65536/manage"
        ] do
      assert {:error, %Error{kind: :validation, operation: :revoke_access_token}} =
               Token.revoke(client, token(manage))
    end

    for value <- ["", "private token", "private\r\ntoken", "private🌍token"] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :revoke_access_token,
                validation_errors: [%{field: :access_token}]
              } = error} = Token.revoke(client, token(@manage, value))

      refute inspect(Map.from_struct(error)) =~ "private"
    end

    manage = "https://auth.example.com:8443/tenant/opaque?part=1&part=2"

    Process.put({TransportAdapter, :callback}, fn request ->
      assert URI.to_string(request.url) == manage
      {request, Req.Response.new(status: 204, body: "")}
    end)

    assert :ok = Token.revoke(client, token(manage))
  end

  test "uses each supplied credential without expiry tracking or stored token state" do
    client = client(adapter: TransportAdapter)
    original = client

    for {value, expiry} <- [
          {"first-token", -1},
          {"second-token", 0},
          {"third-token", 18_446_744_073_709_551_615}
        ] do
      manage = "https://auth.example.com/opaque/" <> value

      Process.put({TransportAdapter, :callback}, fn request ->
        assert URI.to_string(request.url) == manage
        assert Req.Request.get_header(request, "authorization") == ["GNAP " <> value]
        assert request.body == nil
        {request, Req.Response.new(status: 204, body: "")}
      end)

      token = %{token(manage, value) | expires_in: expiry}
      assert :ok = Token.revoke(client, token)
      assert token.expires_in == expiry
    end

    assert client == original
  end

  test "shared clients isolate revocation credentials across concurrent calls" do
    base = HTTPServer.start(fn _ -> {204, [], ""} end)
    client = client(allow_http: true)

    tasks =
      for value <- ["token-a", "token-b"],
          do: Task.async(fn -> Token.revoke(client, token(base <> "/" <> value, value)) end)

    for task <- tasks, do: assert(:ok = Task.await(task))

    for _ <- 1..2 do
      assert_receive {:http_request, wire}

      assert Map.new(wire.headers)["authorization"] ==
               "GNAP " <> String.trim_leading(wire.target, "/")

      assert verify_wire(wire)
    end
  end

  test "retains GNAP/nested HTTP errors and omits raw non-JSON response values" do
    client = client(adapter: TransportAdapter)

    for {status, code} <- [
          {401, "invalid_client"},
          {500, "request_denied"},
          {404, "invalid_request"}
        ] do
      respond(status, Jason.encode!(%{"error" => code, "error_description" => "Not permitted"}))

      assert {:error,
              %Error{
                kind: :http,
                status: ^status,
                code: ^code,
                description: "Not permitted",
                operation: :revoke_access_token
              }} = Token.revoke(client, token())
    end

    respond(
      403,
      ~s({"error":{"code":"denied","description":"Denied","details":{"field":"token"}}})
    )

    assert {:error,
            %Error{kind: :http, status: 403, code: "denied", details: %{"field" => "token"}}} =
             Token.revoke(client, token())

    respond(502, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 502, details: nil} = error} =
             Token.revoke(client, token())

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not replay revocation after timeouts, dropped connections, redirects or server errors" do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, %Error{kind: :transport, code: "timeout", operation: :revoke_access_token}} =
             Token.revoke(client(adapter: TransportAdapter), token())

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
      assert {:error, %Error{kind: ^kind, operation: :revoke_access_token}} =
               Token.revoke(client, token(base <> path))

      assert_receive {:http_request, %{method: "DELETE", target: ^path}}
      refute_receive {:http_request, _}, 30
    end
  end

  test "rotates then revokes using the latest returned management URI and token value" do
    base =
      HTTPServer.start(fn request ->
        headers = Map.new(request.headers)

        case {request.method, request.target} do
          {"POST", "/first"} ->
            assert headers["authorization"] == "GNAP first-token"
            assert request.body == ""

            rotated = %{
              "value" => "latest-token",
              "manage" => "http://" <> headers["host"] <> "/latest?part=2",
              "access" => []
            }

            {200, [], Jason.encode!(%{"access_token" => rotated})}

          {"DELETE", "/latest?part=2"} ->
            assert headers["authorization"] == "GNAP latest-token"
            assert request.body == ""
            {204, [], ""}
        end
      end)

    client = client(allow_http: true)
    initial = token(base <> "/first", "first-token")
    assert {:ok, rotated} = Token.rotate(client, initial)
    assert :ok = Token.revoke(client, rotated.access_token)
    assert initial.value == "first-token"
    assert_receive {:http_request, %{method: "POST", target: "/first"} = post}
    assert_receive {:http_request, %{method: "DELETE", target: "/latest?part=2"} = delete}
    assert verify_wire(post)
    assert verify_wire(delete)
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

  defp token(manage \\ @manage, value \\ "test-resource-token") do
    {:ok, token} = AccessToken.from_map(%{@wire_token | "manage" => manage, "value" => value})
    token
  end

  defp no_request,
    do: Process.put({TransportAdapter, :callback}, fn _ -> flunk("unexpected HTTP request") end)

  defp respond(status, body, headers \\ []) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body, headers: headers)}
    end)
  end

  # Independently reconstruct the signed inputs against the RFC 8032 public key.
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
