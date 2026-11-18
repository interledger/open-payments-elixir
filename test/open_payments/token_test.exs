defmodule OpenPayments.TokenTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Key, Specification, Token}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{AccessToken, ContinuationToken, TokenRotationResponse}

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @manage "https://auth.example.com/tenant/opaque/manage?part=1"
  @wire_token %{"value" => "test-resource-token", "manage" => @manage, "access" => []}
  @result %{
    "access_token" => %{
      "value" => "test-new-token",
      "manage" => "https://auth.example.com/new/manage",
      "access" => [],
      "expires_in" => 3600
    }
  }

  test "matches the pinned rotation POST, body omission and success/error contracts" do
    operation = Enum.find(Specification.operations(), &(&1.id == "post-token"))
    assert operation.server == :auth
    assert operation.method == :post
    assert operation.success_statuses == [200]
    post = Specification.document(:auth)["paths"]["/token/{id}"]["post"]
    refute Map.has_key?(post, "requestBody")
    assert Map.keys(post["responses"]) |> Enum.sort() == ~w(200 400 401 404 500)

    assert post["responses"]["200"]["content"]["application/json"]["schema"]["required"] == [
             "access_token"
           ]
  end

  test "rotates over real signed HTTP using management URI and resource credential with no body" do
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(@result)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "rotate-1"})
    target = "/tenant/opaque%2Fid/../manage?part=a%2Bb&part=2"
    token = token(base <> target)
    original = {client, token}

    assert {:ok, %TokenRotationResponse{access_token: %AccessToken{}} = response} =
             Token.rotate(client, token)

    assert TokenRotationResponse.to_map(response) == @result
    assert_receive {:http_request, wire}
    assert wire.method == "POST"
    assert wire.target == target
    assert wire.body == ""
    headers = Map.new(wire.headers)
    assert headers["authorization"] == "GNAP test-resource-token"
    assert headers["accept"] == "application/json"
    assert headers["accept-encoding"] == "identity"
    assert headers["x-request-id"] == "rotate-1"
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

  test "decodes official rotation examples and preserves root JSON extensions" do
    examples =
      Specification.document(:auth)["paths"]["/token/{id}"]["post"]["responses"]["200"]["content"][
        "application/json"
      ]["examples"]

    assert map_size(examples) > 0
    client = client(adapter: TransportAdapter)

    for {_name, %{"value" => wire}} <- examples do
      wire = Map.put(wire, "custom", %{"values" => [nil, true, 123]})
      respond(200, Jason.encode!(wire))
      assert {:ok, rotated} = Token.rotate(client, token())
      assert TokenRotationResponse.to_map(rotated) == wire
      assert Jason.decode!(Jason.encode!(rotated)) == wire
    end
  end

  test "subsequent rotations use the returned token and changed management URI without stored state" do
    base =
      HTTPServer.start(fn request ->
        headers = Map.new(request.headers)

        if request.target == "/first" do
          assert headers["authorization"] == "GNAP first-token"

          next = %{
            "value" => "next-token",
            "manage" => "http://" <> headers["host"] <> "/next?part=2",
            "access" => []
          }

          {200, [], Jason.encode!(%{"access_token" => next})}
        else
          assert request.target == "/next?part=2"
          assert headers["authorization"] == "GNAP next-token"
          {200, [], Jason.encode!(@result)}
        end
      end)

    client = client(allow_http: true)
    initial = token(base <> "/first", "first-token")
    assert {:ok, response} = Token.rotate(client, initial)
    assert {:ok, _} = Token.rotate(client, response.access_token)
    assert initial.value == "first-token"

    for target <- ["/first", "/next?part=2"] do
      assert_receive {:http_request, %{target: ^target} = wire}
      assert verify_wire(wire)
    end

    refute_receive {:http_request, _}, 30
  end

  test "concurrent rotations keep per-call credentials separate on a shared client" do
    base =
      HTTPServer.start(fn request ->
        result = Map.put(@result, "echo", Map.new(request.headers)["authorization"])
        {200, [], Jason.encode!(result)}
      end)

    client = client(allow_http: true)

    tasks =
      for value <- ["token-a", "token-b"],
          do:
            {value,
             Task.async(fn -> Token.rotate(client, token(base <> "/" <> value, value)) end)}

    for {value, task} <- tasks do
      assert {:ok, response} = Task.await(task)
      assert response.extensions["echo"] == "GNAP " <> value
    end

    for _ <- 1..2 do
      assert_receive {:http_request, wire}

      assert Map.new(wire.headers)["authorization"] ==
               "GNAP " <> String.trim_leading(wire.target, "/")

      assert verify_wire(wire)
    end
  end

  test "rejects invalid clients and manually changed tokens or continuation credentials before HTTP" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for bad <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :rotate_access_token}} =
               Token.rotate(bad, token())
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
          %{original | expires_in: "3600"}
        ] do
      assert {:error, %Error{kind: :validation, operation: :rotate_access_token}} =
               Token.rotate(client, bad)
    end

    assert {:error, %Error{validation_errors: [%{field: :value}]} = error} =
             Token.rotate(client, %{original | value: ["private-token"]})

    refute inspect(Map.from_struct(error)) =~ "private-token"
  end

  test "applies request URL/token68 policies and permits HTTPS ports and queries" do
    no_request()
    client = client(adapter: TransportAdapter)

    for manage <- [
          "urn:example:manage",
          "http://localhost:3006/manage",
          "https://user@auth.example.com/manage",
          "https://auth.example.com/manage#fragment",
          "https://auth.example.com:65536/manage"
        ] do
      assert {:error, %Error{kind: :validation, operation: :rotate_access_token}} =
               Token.rotate(client, token(manage))
    end

    for value <- ["", "private token", "private\r\ntoken", "private🌍token"] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :rotate_access_token,
                validation_errors: [%{field: :access_token}]
              } = error} = Token.rotate(client, token(@manage, value))

      refute inspect(Map.from_struct(error)) =~ "private"
    end

    manage = "https://auth.example.com:8443/opaque?part=1&part=2"

    Process.put({TransportAdapter, :callback}, fn request ->
      assert URI.to_string(request.url) == manage
      {request, Req.Response.new(body: Jason.encode!(@result))}
    end)

    assert {:ok, _} = Token.rotate(client, token(manage))
  end

  test "preserves schema-valid expiry metadata and does not compare old and new access" do
    client = client(adapter: TransportAdapter)

    wire =
      put_in(@result, ["access_token", "access"], [%{"type" => "quote", "actions" => ["create"]}])

    for expires_in <- [-1, 0, 18_446_744_073_709_551_615] do
      original = %{token() | expires_in: expires_in}
      respond(200, Jason.encode!(wire))
      assert {:ok, response} = Token.rotate(client, original)
      assert TokenRotationResponse.to_map(response) == wire
      assert original.expires_in == expires_in
    end
  end

  test "classifies JSON/status/encoding and token response failures with safe nested paths" do
    client = client(adapter: TransportAdapter)

    for {status, body, headers, code} <- [
          {200, "not-json", [], "invalid_json"},
          {204, "", [], "unexpected_status"},
          {201, Jason.encode!(@result), [], "unexpected_status"},
          {200, Jason.encode!(@result), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"},
          {200, "null", [], "invalid_response"},
          {200, "{}", [], "invalid_response"},
          {200, ~s({"access_token":null}), [], "invalid_response"}
        ] do
      respond(status, body, headers)

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: ^code,
                operation: :rotate_access_token
              }} = Token.rotate(client, token())
    end

    respond(200, Jason.encode!(put_in(@result, ["access_token", "value"], ["private-new-token"])))

    assert {:error,
            %Error{code: "invalid_response", validation_errors: [%{field: "access_token.value"}]} =
              error} = Token.rotate(client, token())

    refute inspect(Map.from_struct(error)) =~ "private-new-token"

    card = %{
      "type" => "outgoing-payment",
      "actions" => ["create"],
      "identifier" => "https://wallet.example.com/alice",
      "cardAuthorization" => %{
        "tlvData" => "test-tlv",
        "requestId" => "test-id",
        "pwk" => %{"key" => ["private-key"], "kvc" => "test-kvc", "iv" => "test-iv"}
      }
    }

    respond(200, Jason.encode!(put_in(@result, ["access_token", "access"], [card])))

    assert {:error,
            %Error{
              validation_errors: [%{field: "access_token.access[0].card_authorization.pwk.key"}]
            } = error} = Token.rotate(client, token())

    refute inspect(Map.from_struct(error)) =~ "private-key"
  end

  test "preserves documented GNAP errors and omits raw non-JSON error bodies" do
    client = client(adapter: TransportAdapter)

    for {status, code} <- [
          {400, "invalid_rotation"},
          {401, "invalid_client"},
          {404, "invalid_rotation"},
          {500, "request_denied"}
        ] do
      respond(status, Jason.encode!(%{"error" => code, "error_description" => "Not permitted"}))

      assert {:error,
              %Error{kind: :http, status: ^status, code: ^code, operation: :rotate_access_token}} =
               Token.rotate(client, token())
    end

    respond(502, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 502, details: nil} = error} =
             Token.rotate(client, token())

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not replay rotation after timeout, connection loss, redirects or server errors" do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, %Error{kind: :transport, code: "timeout", operation: :rotate_access_token}} =
             Token.rotate(client(adapter: TransportAdapter), token())

    base =
      HTTPServer.start(fn request ->
        case request.target do
          "/drop" -> :close
          "/redirect" -> {307, [{"location", "/other"}], "failed"}
          _ -> {503, [], "unavailable"}
        end
      end)

    client = client(allow_http: true)

    for {target, kind} <- [{"/drop", :transport}, {"/redirect", :http}, {"/unavailable", :http}] do
      assert {:error, %Error{kind: ^kind, operation: :rotate_access_token}} =
               Token.rotate(client, token(base <> target))

      assert_receive {:http_request, %{method: "POST", target: ^target}}
      refute_receive {:http_request, _}, 30
    end
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

  # Independent reconstruction against the RFC 8032 public key for the test seed.
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
