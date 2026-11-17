defmodule OpenPayments.WalletAddressKeysTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Specification, WalletAddress}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{JWK, JWKS}

  @key %{
    "kid" => "key-1",
    "alg" => "EdDSA",
    "kty" => "OKP",
    "crv" => "Ed25519",
    "x" => "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
  }

  test "matches the pinned public JWKS operation and example" do
    operation = Enum.find(Specification.operations(), &(&1.id == "get-wallet-address-keys"))
    assert operation.method == :get
    assert operation.server == :wallet_address
    assert operation.success_statuses == [200]

    {:ok, schema} = Specification.fetch_schema(:wallet_address, "json-web-key-set")
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for example <- schema["examples"] do
      respond(200, Jason.encode!(example))
      assert {:ok, %JWKS{} = set} = WalletAddress.get_keys(client, "$wallet.example.com/alice")
      assert JWKS.to_map(set) == example
    end
  end

  test "fetches typed public keys over a real unsigned local connection" do
    key = Map.put(@key, "custom", %{"value" => true})
    wire = %{"keys" => [key, Map.put(@key, "kid", "next-key")]}
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(wire)} end)
    {:ok, client} = Client.new_public(allow_http: true)

    assert {:ok, %JWKS{keys: [%JWK{}, %JWK{}]} = set} =
             WalletAddress.get_keys(client, base <> "/accounts/alice")

    assert JWKS.to_map(set) == wire
    assert_receive {:http_request, request}
    assert request.method == "GET"
    assert request.target == "/accounts/alice/jwks.json"
    assert request.body == ""
    headers = Map.new(request.headers)
    assert headers["accept"] == "application/json"
    assert headers["accept-encoding"] == "identity"
    refute Map.has_key?(headers, "authorization")
    refute Map.has_key?(headers, "signature")
  end

  test "appends the key path after wallet resolution and preserves encoded paths" do
    Process.put({TransportAdapter, :callback}, fn request ->
      send(self(), {:requested, URI.to_string(request.url)})
      {request, Req.Response.new(body: ~s({"keys":[]}))}
    end)

    {:ok, client} = Client.new_public(allow_http: true, adapter: TransportAdapter)

    for {input, expected} <- [
          {"https://Wallet.Example.COM", "https://wallet.example.com/jwks.json"},
          {"https://wallet.example.com/", "https://wallet.example.com/jwks.json"},
          {"https://wallet.example.com/alice/", "https://wallet.example.com/alice/jwks.json"},
          {"https://wallet.example.com/a//b/", "https://wallet.example.com/a//b/jwks.json"},
          {"$wallet.example.com", "https://wallet.example.com/.well-known/pay/jwks.json"},
          {"$wallet.example.com/", "https://wallet.example.com/.well-known/pay/jwks.json"},
          {"$wallet.example.com/a%2fb/../alice",
           "https://wallet.example.com/a%2fb/../alice/jwks.json"},
          {"http://localhost:3000/accounts/alice",
           "http://localhost:3000/accounts/alice/jwks.json"},
          {"http://[::1]:3000/alice", "http://[::1]:3000/alice/jwks.json"}
        ] do
      assert {:ok, %JWKS{keys: []}} = WalletAddress.get_keys(client, input)
      assert_received {:requested, ^expected}
    end
  end

  test "accepts empty sets and duplicate IDs and fetches afresh on each call" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for keys <- [[], [@key, @key], [Map.put(@key, "kid", "rotated-key")]] do
      Process.put({TransportAdapter, :callback}, fn request ->
        send(self(), :fetched)
        {request, Req.Response.new(body: Jason.encode!(%{"keys" => keys}))}
      end)

      assert {:ok, set} = WalletAddress.get_keys(client, "https://wallet.example.com/alice")
      assert JWKS.to_map(set) == %{"keys" => keys}
      assert_received :fetched
    end
  end

  test "rejects invalid client and wallet identifiers before HTTP execution" do
    Process.put({TransportAdapter, :callback}, fn _ -> flunk("unexpected HTTP request") end)
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for input <- [
          nil,
          [],
          "",
          "http://localhost:3000/alice",
          "https://wallet.example.com:443/alice",
          "https://user@wallet.example.com/alice",
          "https://wallet.example.com/alice?",
          "https://wallet.example.com/alice#fragment",
          "$wallet.example.com:443/alice"
        ] do
      assert {:error, %Error{kind: :validation, operation: :get_wallet_address_keys}} =
               WalletAddress.get_keys(client, input)
    end

    assert {:error, %Error{kind: :configuration, operation: :get_wallet_address_keys}} =
             WalletAddress.get_keys(nil, "https://wallet.example.com/alice")
  end

  test "rejects invalid JSON, invalid sets and private key material with indexed errors" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for body <- [
          "not-json",
          "",
          "null",
          "[]",
          "{}",
          ~s({"keys":null}),
          ~s({"keys":[],"extra":true}),
          Jason.encode!(%{"keys" => [Map.delete(@key, "alg")]})
        ] do
      respond(200, body)

      assert {:error, %Error{kind: :decoding, status: 200, operation: :get_wallet_address_keys}} =
               WalletAddress.get_keys(client, "https://wallet.example.com/alice")
    end

    respond(200, Jason.encode!(%{"keys" => [@key, Map.put(@key, "d", "private-key-material")]}))

    assert {:error, %Error{code: "invalid_response", validation_errors: issues} = error} =
             WalletAddress.get_keys(client, "https://wallet.example.com/alice")

    assert Enum.any?(issues, &(&1.field == "keys[1].d"))
    refute inspect(Map.from_struct(error)) =~ "private-key-material"
  end

  test "retains operation context for HTTP, unexpected status and transport errors" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)
    respond(404, ~s({"error":{"code":"not_found","description":"No keys"}}))

    assert {:error,
            %Error{
              kind: :http,
              status: 404,
              code: "not_found",
              operation: :get_wallet_address_keys
            }} =
             WalletAddress.get_keys(client, "https://wallet.example.com/alice")

    respond(204, "")

    assert {:error,
            %Error{
              kind: :decoding,
              code: "unexpected_status",
              operation: :get_wallet_address_keys
            }} =
             WalletAddress.get_keys(client, "https://wallet.example.com/alice")

    Process.put({TransportAdapter, :callback}, fn request ->
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error,
            %Error{kind: :transport, code: "timeout", operation: :get_wallet_address_keys}} =
             WalletAddress.get_keys(client, "https://wallet.example.com/alice")
  end

  test "does not follow a JWKS redirect" do
    base = HTTPServer.start(fn _ -> {302, [{"location", "/other-keys"}], "redirect"} end)
    {:ok, client} = Client.new_public(allow_http: true)

    assert {:error, %Error{kind: :http, status: 302, operation: :get_wallet_address_keys}} =
             WalletAddress.get_keys(client, base <> "/alice")

    assert_receive {:http_request, %{target: "/alice/jwks.json"}}
    refute_receive {:http_request, _}, 30
  end

  defp respond(status, body) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body)}
    end)
  end
end
