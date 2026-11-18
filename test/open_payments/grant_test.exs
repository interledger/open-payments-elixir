defmodule OpenPayments.GrantTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Grant, Key, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{GrantRequest, GrantResponse, JWK}

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @wallet "https://client.example.com/alice"
  @url "https://auth.example.com/tenant"
  @payload %{
    "access_token" => %{
      "access" => [%{"type" => "incoming-payment", "actions" => ["create", "read"]}]
    }
  }
  @continuation %{
    "access_token" => %{"value" => "test-continuation-token"},
    "uri" => "https://auth.example.com/continue/id"
  }
  @approved %{
    "continue" => @continuation,
    "access_token" => %{
      "value" => "test-resource-token",
      "manage" => "https://auth.example.com/token/id",
      "access" => []
    }
  }
  @pending %{
    "continue" => @continuation,
    "interact" => %{
      "redirect" => "https://auth.example.com/consent/id",
      "finish" => "test-server-finish"
    }
  }

  test "matches the pinned initial grant POST operation, payload and success status" do
    operation = Enum.find(Specification.operations(), &(&1.id == "post-request"))
    assert operation.server == :auth
    assert operation.method == :post
    assert operation.success_statuses == [200]
    post = Specification.document(:auth)["paths"]["/"]["post"]

    assert post["requestBody"]["content"]["application/json"]["schema"]["$ref"] ==
             "#/components/schemas/grant-request"

    assert post["security"] == []
    assert length(post["responses"]["200"]["content"]["application/json"]["schema"]["oneOf"]) == 2
  end

  test "sends the exact signed typed POST over real HTTP without authorization or inferred paths" do
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(@pending)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "grant-1"})

    wire_payload =
      @payload
      |> Map.put("client", %{"walletAddress" => @wallet, "display" => %{"name" => "Café 🌍"}})
      |> Map.put("interact", %{
        "start" => ["redirect"],
        "finish" => %{
          "method" => "redirect",
          "uri" => "https://client.example.com/return",
          "nonce" => "test-client-nonce"
        }
      })

    {:ok, typed} = GrantRequest.from_map(wire_payload)
    target = "/tenant/opaque%2fpath/../auth?part=a%2Bb&part=second"
    original = {client, typed}

    assert {:ok, %GrantResponse{} = grant} = Grant.request(client, base <> target, typed)
    assert GrantResponse.pending?(grant)
    assert GrantResponse.to_map(grant) == @pending
    assert_receive {:http_request, wire}
    assert wire.method == "POST"
    assert wire.target == target
    assert wire.body == Jason.encode!(typed)
    assert Jason.decode!(wire.body) == wire_payload
    headers = Map.new(wire.headers)
    assert headers["accept"] == "application/json"
    assert headers["accept-encoding"] == "identity"
    assert headers["x-request-id"] == "grant-1"
    assert headers["content-type"] == "application/json"
    assert headers["content-length"] == Integer.to_string(byte_size(wire.body))

    assert headers["content-digest"] ==
             "sha-512=:#{Base.encode64(:crypto.hash(:sha512, wire.body))}:"

    refute Map.has_key?(headers, "authorization")
    assert verify_wire(wire)
    refute verify_wire(%{wire | target: target <> "tampered"})
    assert {client, typed} == original
  end

  test "injects the configured normalized wallet string only when a JSON map omits client" do
    client = client(wallet_address: "$client.example.com", adapter: TransportAdapter)

    respond(@approved, fn request ->
      assert Jason.decode!(request.body) ==
               Map.put(@payload, "client", "https://client.example.com/.well-known/pay")

      assert Req.Request.get_header(request, "authorization") == []
      assert Req.Request.get_header(request, "signature") != []
    end)

    assert {:ok, grant} = Grant.request(client, @url, @payload)
    assert GrantResponse.approved?(grant)
    refute Map.has_key?(@payload, "client")
  end

  test "preserves explicit wallet string/object identities and display metadata without discovery" do
    client = client(adapter: TransportAdapter)

    for identity <- [
          "https://other.example.com/wallet",
          %{"walletAddress" => @wallet, "display" => %{"name" => "Example"}}
        ] do
      payload = Map.put(@payload, "client", identity)

      respond(@approved, fn request ->
        assert URI.to_string(request.url) == @url
        assert Jason.decode!(request.body) == payload
      end)

      assert {:ok, _} = Grant.request(client, @url, payload)
    end
  end

  test "sends directed identity matching the signing key and ID while preserving public metadata" do
    client = client(adapter: TransportAdapter)
    {:ok, key} = Key.from_seed(@seed, "example-key-1")
    jwk = Key.public_jwk(key) |> JWK.to_map() |> Map.put("use", "sig") |> Map.put("custom", true)
    payload = Map.put(@payload, "client", %{"jwk" => jwk, "display" => %{"name" => "Example"}})
    {:ok, typed} = GrantRequest.from_map(payload)

    respond(@approved, fn request ->
      assert Jason.decode!(request.body) == payload
      assert hd(Req.Request.get_header(request, "signature-input")) =~ ~s(keyid="example-key-1")
      refute request.body =~ ~s("d":)
    end)

    assert {:ok, _} = Grant.request(client, @url, typed)
  end

  test "rejects directed key/ID mismatches and interactive directed requests before transport" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, key} = Key.from_seed(@seed, "example-key-1")
    jwk = Key.public_jwk(key) |> JWK.to_map()

    for changed <- [
          Map.put(jwk, "kid", "private-wrong-id"),
          Map.put(jwk, "x", Base.url_encode64(:binary.copy(<<1>>, 32), padding: false)),
          Map.put(jwk, "x", "AA")
        ] do
      payload = Map.put(@payload, "client", %{"jwk" => changed})

      assert {:error,
              %Error{
                kind: :validation,
                operation: :request_grant,
                validation_errors: [%{field: "client.jwk"}]
              } = error} = Grant.request(client, @url, payload)

      refute inspect(Map.from_struct(error)) =~ "private-wrong-id"
    end

    payload =
      @payload |> Map.put("client", %{"jwk" => jwk}) |> Map.put("interact", %{"start" => []})

    assert {:error, %Error{validation_errors: [%{field: :interact}]}} =
             Grant.request(client, @url, payload)
  end

  test "sends all official grant request examples including subject, display and card requests" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["requestBody"]["content"][
        "application/json"
      ]["examples"]

    client = client(adapter: TransportAdapter)
    assert map_size(examples) > 0

    for {_name, %{"value" => wire}} <- examples do
      respond(@approved, fn request -> assert Jason.decode!(request.body) == wire end)
      assert {:ok, %GrantResponse{}} = Grant.request(client, @url, wire)
    end
  end

  test "decodes every official initial response including pending interaction and card results" do
    examples =
      Specification.document(:auth)["paths"]["/"]["post"]["responses"]["200"]["content"][
        "application/json"
      ]["examples"]

    client = client(adapter: TransportAdapter)
    assert map_size(examples) > 0

    for {_name, %{"value" => wire}} <- examples do
      respond(wire)
      assert {:ok, grant} = Grant.request(client, @url, @payload)
      assert GrantResponse.to_map(grant) == wire
    end
  end

  test "rejects public/invalid clients and invalid raw or manually modified typed requests before HTTP" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for invalid_client <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :request_grant}} =
               Grant.request(invalid_client, @url, @payload)
    end

    {:ok, typed} = GrantRequest.from_map(Map.put(@payload, "client", @wallet))

    for payload <- [
          nil,
          [],
          "private-input",
          %URI{},
          %{},
          Map.put(@payload, "client", nil),
          Map.put(@payload, :custom, true),
          %{typed | client: nil},
          %{typed | access_token: %{typed.access_token | access: nil}}
        ] do
      assert {:error, %Error{kind: :validation, operation: :request_grant} = error} =
               Grant.request(client, @url, payload)

      refute inspect(Map.from_struct(error)) =~ "private-input"
    end
  end

  test "rejects invalid targets and preserves explicit HTTPS ports and query strings" do
    no_request()
    client = client(adapter: TransportAdapter)

    for url <- [
          nil,
          [],
          "",
          "/auth",
          "$auth.example.com",
          "http://localhost:3006",
          "ftp://auth.example.com",
          "https://user@auth.example.com",
          "https://auth.example.com/#fragment",
          "https://auth.example.com:65536"
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :request_grant,
                validation_errors: [%{field: :url}]
              }} = Grant.request(client, url, @payload)
    end

    url = "https://auth.example.com:8443/tenant?part=1&part=2"
    respond(@approved, fn request -> assert URI.to_string(request.url) == url end)
    assert {:ok, _} = Grant.request(client, url, @payload)
  end

  test "returns decoding errors for invalid JSON, success status, encoding or response shape" do
    client = client(adapter: TransportAdapter)

    for {status, body, headers, code} <- [
          {200, "not-json", [], "invalid_json"},
          {204, "", [], "unexpected_status"},
          {201, Jason.encode!(@approved), [], "unexpected_status"},
          {200, Jason.encode!(@approved), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"},
          {200, "null", [], "invalid_response"},
          {200, Jason.encode!(%{"continue" => @continuation}), [], "invalid_response"},
          {200, Jason.encode!(Map.put(@pending, "access_token", @approved["access_token"])), [],
           "invalid_response"}
        ] do
      raw_response(status, body, headers)

      assert {:error,
              %Error{kind: :decoding, status: ^status, code: ^code, operation: :request_grant}} =
               Grant.request(client, @url, @payload)
    end

    respond(put_in(@pending, ["continue", "access_token", "value"], ["private-token"]))

    assert {:error, %Error{validation_errors: [%{field: "continue.access_token.value"}]} = error} =
             Grant.request(client, @url, @payload)

    refute inspect(Map.from_struct(error)) =~ "private-token"
  end

  test "retains HTTP status and GNAP errors while omitting raw non-JSON error bodies" do
    client = client(adapter: TransportAdapter)

    for status <- [400, 401, 403, 404, 422] do
      raw_response(status, ~s({"error":"invalid_client","error_description":"Not permitted"}))

      assert {:error,
              %Error{
                kind: :http,
                status: ^status,
                code: "invalid_client",
                description: "Not permitted",
                operation: :request_grant
              }} = Grant.request(client, @url, @payload)
    end

    raw_response(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             Grant.request(client, @url, @payload)

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "labels timeout and dropped-connection failures without replaying grant initiation" do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, %Error{kind: :transport, code: "timeout", operation: :request_grant}} =
             Grant.request(client(adapter: TransportAdapter), @url, @payload)

    base = HTTPServer.start(fn _ -> :close end)

    assert {:error, %Error{kind: :transport, operation: :request_grant}} =
             Grant.request(client(allow_http: true), base <> "/tenant", @payload)

    assert_receive {:http_request, %{method: "POST", target: "/tenant"}}
    refute_receive {:http_request, _}, 30
  end

  test "does not follow redirects or retry server errors for signed grants" do
    base =
      HTTPServer.start(fn request ->
        status = if request.target == "/redirect", do: 307, else: 503
        {status, [{"location", "/other"}], "failed"}
      end)

    client = client(allow_http: true)

    for {status, target} <- [{307, "/redirect"}, {503, "/unavailable"}] do
      assert {:error, %Error{kind: :http, status: ^status, operation: :request_grant}} =
               Grant.request(client, base <> target, @payload)

      assert_receive {:http_request, %{method: "POST", target: ^target}}
      refute_receive {:http_request, _}, 30
    end
  end

  defp client(opts) do
    {:ok, key} = Key.from_seed(@seed, "example-key-1")

    {:ok, client} =
      Client.new_authenticated(Keyword.merge([wallet_address: @wallet, key: key], opts))

    client
  end

  defp no_request,
    do: Process.put({TransportAdapter, :callback}, fn _ -> flunk("unexpected HTTP request") end)

  defp respond(data, inspect_request \\ fn _ -> :ok end) do
    Process.put({TransportAdapter, :callback}, fn request ->
      inspect_request.(request)
      {request, Req.Response.new(status: 200, body: Jason.encode!(data))}
    end)
  end

  defp raw_response(status, body, headers \\ []) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body, headers: headers)}
    end)
  end

  # Independent reconstruction from the actual wire, without SDK signature builders.
  defp verify_wire(wire) do
    headers = Map.new(wire.headers)
    "sig1=" <> params = headers["signature-input"]

    assert params =~
             ~s|("@method" "@target-uri" "content-digest" "content-length" "content-type");keyid="example-key-1";created=|

    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, headers["signature"])
    signature = Base.decode64!(encoded)
    url = "http://" <> headers["host"] <> wire.target

    base =
      Enum.join(
        [
          ~s("@method": #{wire.method}),
          ~s("@target-uri": #{url}),
          ~s("content-digest": #{headers["content-digest"]}),
          ~s("content-length": #{headers["content-length"]}),
          ~s("content-type": #{headers["content-type"]}),
          ~s("@signature-params": #{params})
        ],
        "\n"
      )

    {:ok, key} = Key.from_seed(@seed, "example-key-1")
    public = key |> Key.public_jwk() |> Map.fetch!(:x) |> Base.url_decode64!(padding: false)
    :crypto.verify(:eddsa, :none, base, signature, [public, :ed25519])
  end
end
