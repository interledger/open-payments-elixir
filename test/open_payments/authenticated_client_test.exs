defmodule OpenPayments.AuthenticatedClientTest do
  use ExUnit.Case, async: true

  alias MessageSignatures.Message
  alias OpenPayments.{Client, Error, IncomingPayment, Key, Specification, WalletAddress}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}

  @fixture File.read!(Path.expand("../fixtures/keys/node-pem.json", __DIR__)) |> Jason.decode!()
  @seed Base.url_decode64!(@fixture["private_jwk"]["d"], padding: false)
  @created 1_618_884_473
  @wallet "https://wallet.example.com/alice"

  test "constructs a signing identity without HTTP and preserves public client getters" do
    Process.put({TransportAdapter, :callback}, fn _ -> flunk("construction must not use HTTP") end)

    {:ok, key} = Key.from_seed(@seed, "key-1")

    assert {:ok, client} =
             Client.new_authenticated(
               wallet_address: @wallet,
               key: key,
               adapter: TransportAdapter
             )

    assert Client.authenticated?(client)
    assert Client.wallet_address(client) == @wallet
    refute Client.allow_http?(client)

    {:ok, public} = Client.new_public()
    refute Client.authenticated?(public)
    assert Client.wallet_address(public) == nil
  end

  test "imports each explicit key source and uses its configured key ID" do
    path =
      Path.join(
        System.tmp_dir!(),
        "open-payments-client-#{System.unique_integer([:positive])}.pem"
      )

    File.write!(path, @fixture["ed25519"])
    on_exit(fn -> File.rm(path) end)

    Process.put({TransportAdapter, :callback}, fn request ->
      [input] = Req.Request.get_header(request, "signature-input")
      assert input =~ ~s(keyid="registered-key")
      assert verify(request) == :ok
      {request, Req.Response.new(body: "{}")}
    end)

    for source <- [
          {:seed, @seed},
          {:pem, @fixture["ed25519"]},
          {:file, path},
          {:base64_pem, Base.encode64(@fixture["ed25519"])},
          {:jwk, Map.put(@fixture["private_jwk"], "kid", "embedded-key")}
        ] do
      assert {:ok, client} =
               Client.new_authenticated(
                 wallet_address: @wallet,
                 key_id: "registered-key",
                 private_key: source,
                 adapter: TransportAdapter
               )

      assert {:ok, _} =
               Client.request_signed(client, :post, "https://auth.example.com/tenant",
                 created: @created
               )
    end

    assert File.read!(path) == @fixture["ed25519"]
  end

  test "resolves wallet pointers and shares discovery's identifier rules" do
    {:ok, key} = Key.from_seed(@seed, "key-1")

    for {input, expected, opts} <- [
          {"$Wallet.Example.COM", "https://wallet.example.com/.well-known/pay", []},
          {"$wallet.example.com/alice%20account", "https://wallet.example.com/alice%20account",
           []},
          {"http://localhost:3000/accounts/alice", "http://localhost:3000/accounts/alice",
           [allow_http: true]}
        ] do
      assert {:ok, client} = Client.new_authenticated([wallet_address: input, key: key] ++ opts)
      assert Client.wallet_address(client) == expected
    end

    for wallet <- [
          nil,
          "",
          "wallet.example.com/alice",
          "http://localhost:3000/alice",
          "https://wallet.example.com:443/alice",
          "https://user@wallet.example.com/alice",
          "https://wallet.example.com/alice?x=1",
          "https://wallet.example.com/alice#fragment",
          "$wallet.example.com:443/alice"
        ] do
      assert {:error, %Error{kind: :configuration}} =
               Client.new_authenticated(wallet_address: wallet, key: key)
    end
  end

  test "rejects missing, conflicting, malformed and unsupported key configurations safely" do
    {:ok, key} = Key.from_seed(@seed, "key-1")

    for config <- [
          [],
          [key: nil],
          [key: "private-key-must-not-leak"],
          [key: key, key_id: "key-1"],
          [key: key, private_key: {:seed, @seed}],
          [private_key: @fixture["ed25519"], key_id: "key-1"],
          [private_key: {:unknown, "private-key-must-not-leak"}, key_id: "key-1"],
          [private_key: {:pem, "private-key-must-not-leak"}, key_id: "key-1"],
          [private_key: {:seed, @seed}],
          [private_key: {:seed, @seed}, key_id: " "],
          [private_key: {:file, "/nonexistent/private-key-must-not-leak.pem"}, key_id: "key-1"]
        ] do
      assert {:error, %Error{kind: :configuration} = error} =
               Client.new_authenticated([wallet_address: @wallet] ++ config)

      refute inspect(Map.from_struct(error)) =~ "private-key-must-not-leak"
      refute inspect(Map.from_struct(error)) =~ @fixture["ed25519"]
    end
  end

  test "checks reused opaque keys for seed/public consistency and valid key IDs" do
    {:ok, key} = Key.from_seed(@seed, "key-1")

    for malformed <- [
          Map.delete(key, :private_key),
          Map.put(key, :private_key, "bad-seed"),
          Map.put(key, :public_key, <<0::256>>),
          Map.put(key, :key_id, nil)
        ] do
      assert {:error, %Error{kind: :configuration}} =
               Client.new_authenticated(wallet_address: @wallet, key: malformed)
    end
  end

  test "validates common options and rejects duplicates before key import" do
    {:ok, key} = Key.from_seed(@seed, "key-1")

    for opts <- [nil, %{}, [:bad], [wallet_address: @wallet, key: key, key: key]] do
      assert {:error, %Error{kind: :configuration}} = Client.new_authenticated(opts)
    end

    for opts <- [
          [unknown: true],
          [allow_http: :yes],
          [request_timeout: 0],
          [headers: %{"Authorization" => "secret"}]
        ] do
      assert {:error, %Error{kind: :configuration}} =
               Client.new_authenticated([wallet_address: @wallet, key: key] ++ opts)
    end
  end

  test "signs actual wire requests with per-call authorization and inherited HTTP configuration" do
    base = HTTPServer.start(fn _ -> {200, [], "{}"} end)
    {:ok, key} = Key.from_seed(@seed, "key-1")

    {:ok, client} =
      Client.new_authenticated(
        wallet_address: "http://localhost:3000/accounts/alice",
        key: key,
        allow_http: true,
        receive_timeout: 1234,
        headers: %{"X-Request-ID" => "signed-1"}
      )

    assert {:ok, _} =
             Client.request_signed(client, :post, base <> "/tenant/grants?part=1",
               json: %{"client" => Client.wallet_address(client)},
               access_token: "per-call-token",
               created: @created
             )

    assert_receive {:http_request, wire}
    assert wire.method == "POST"
    assert wire.target == "/tenant/grants?part=1"
    headers = Map.new(wire.headers)
    assert headers["x-request-id"] == "signed-1"
    assert headers["authorization"] == "GNAP per-call-token"

    assert headers["content-digest"] ==
             "sha-512=:#{Base.encode64(:crypto.hash(:sha512, wire.body))}:"

    url = base <> wire.target
    message = Message.from_request(method: wire.method, url: url, headers: wire.headers)
    assert {:ok, _} = verify_message(message)
    refute inspect(client) =~ "per-call-token"
  end

  test "signed dispatch binds the client key and does not retain per-call tokens" do
    {:ok, key} = Key.from_seed(@seed, "key-1")
    {:ok, other_key} = Key.generate("other-key")

    {:ok, client} =
      Client.new_authenticated(wallet_address: @wallet, key: key, adapter: TransportAdapter)

    original = client

    for token <- ["first-token", "second-token"] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert Req.Request.get_header(request, "authorization") == ["GNAP " <> token]
        assert verify(request) == :ok
        [input] = Req.Request.get_header(request, "signature-input")
        assert input =~ ~s(keyid="key-1")
        refute input =~ "other-key"
        {request, Req.Response.new(body: "{}")}
      end)

      assert {:ok, _} =
               Client.request_signed(client, :get, @wallet,
                 access_token: token,
                 key: other_key,
                 created: @created
               )

      assert client == original
      refute inspect(Map.from_struct(client)) =~ token
    end
  end

  test "rejects signed dispatch with a public client and retains client HTTP policy" do
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    assert {:error, %Error{kind: :configuration, validation_errors: [%{field: :key}]}} =
             Client.request_signed(public, :post, "https://auth.example.com")

    {:ok, key} = Key.from_seed(@seed, "key-1")

    {:ok, client} =
      Client.new_authenticated(wallet_address: @wallet, key: key, adapter: TransportAdapter)

    assert {:error, %Error{validation_errors: [%{field: :url}]}} =
             Client.request_signed(client, :post, "http://localhost:3006/tenant",
               allow_http: true
             )
  end

  test "all existing public operations remain unsigned with an authenticated client" do
    {:ok, key} = Key.from_seed(@seed, "key-1")

    {:ok, client} =
      Client.new_authenticated(wallet_address: @wallet, key: key, adapter: TransportAdapter)

    {:ok, payment_schema} =
      Specification.fetch_schema(:resource, "incoming-payment-without-access-token")

    payment = hd(payment_schema["examples"])

    Process.put({TransportAdapter, :callback}, fn request ->
      assert Req.Request.get_header(request, "signature") == []
      assert Req.Request.get_header(request, "authorization") == []

      body =
        case request.url.path do
          "/alice" ->
            %{
              "id" => @wallet,
              "assetCode" => "USD",
              "assetScale" => 2,
              "authServer" => "https://auth.example.com",
              "resourceServer" => "https://wallet.example.com/tenant"
            }

          "/alice/jwks.json" ->
            %{"keys" => []}

          "/payment" ->
            payment
        end

      {request, Req.Response.new(body: Jason.encode!(body))}
    end)

    assert {:ok, _} = WalletAddress.get(client, @wallet)
    assert {:ok, _} = WalletAddress.get_keys(client, @wallet)
    assert {:ok, _} = IncomingPayment.get_public(client, "https://wallet.example.com/payment")
    assert {:ok, _} = Client.request(client, :get, @wallet, key: key)
  end

  test "inspection and JSON encoding do not expose signing or custom configuration" do
    {:ok, client} =
      Client.new_authenticated(
        wallet_address: "https://private-wallet.example.com/alice",
        key_id: "private-key-id",
        private_key: {:seed, @seed},
        headers: %{"X-Private" => "private-header"}
      )

    refute inspect(client) =~ "private-"
    refute inspect(client) =~ Base.encode16(@seed)
    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(client) end
  end

  defp verify(request) do
    message =
      Message.from_request(
        method: request.method,
        url: URI.to_string(request.url),
        headers:
          Enum.flat_map(request.headers, fn {name, values} -> Enum.map(values, &{name, &1}) end)
      )

    assert {:ok, _} = verify_message(message)
    :ok
  end

  defp verify_message(message) do
    public = Base.url_decode64!(@fixture["public_jwk"]["x"], padding: false)

    MessageSignatures.verify(message,
      key_resolver: fn _, _ -> {:ok, {:ed25519, public}} end,
      now: @created
    )
  end
end
