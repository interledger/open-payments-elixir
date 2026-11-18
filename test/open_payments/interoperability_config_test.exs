defmodule OpenPayments.InteroperabilityConfigTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Key}
  alias OpenPayments.Test.{Interoperability, TransportAdapter}
  alias OpenPayments.Types.JWKS

  @prefix "OPEN_PAYMENTS_INTEGRATION_"
  @fixture_path Path.expand("../fixtures/keys/node-pem.json", __DIR__)
  @external_resource @fixture_path

  setup do
    name =
      "open-payments-interop-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    directory = Path.join(System.tmp_dir!(), name)
    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    key_file = Path.join(directory, "key.pem")
    token_file = Path.join(directory, "token.txt")
    pem = @fixture_path |> File.read!() |> Jason.decode!() |> Map.fetch!("ed25519")
    File.write!(key_file, pem)
    File.write!(token_file, "public-test-token==\n")

    env =
      Map.new(
        %{
          "WALLET_ADDRESS" => "$wallet.example.com/alice",
          "READ_KIND" => "incoming",
          "RESOURCE_URL" => "https://resource.example.com/tenant/existing-resource?opaque=1",
          "PRIVATE_KEY_FILE" => key_file,
          "KEY_ID" => "public-fixture-key",
          "ACCESS_TOKEN_FILE" => token_file
        },
        fn {key, value} -> {@prefix <> key, value} end
      )

    %{env: env, pem: pem, token_file: token_file}
  end

  test "public configuration needs only a wallet and enforces HTTPS" do
    config =
      Interoperability.public_config(
        getter(%{(@prefix <> "WALLET_ADDRESS") => "$wallet.example.com/alice"})
      )

    refute Client.authenticated?(config.client)
    refute Client.allow_http?(config.client)
    assert is_nil(config.access_token)

    assert {:error, %Error{kind: :validation}} =
             OpenPayments.WalletAddress.get(config.client, "http://localhost:3000/alice")
  end

  test "explicit runs fail for missing or blank settings instead of silently skipping", %{
    env: env
  } do
    for value <- [nil, "", " \n", <<255>>] do
      input = Map.put(env, @prefix <> "WALLET_ADDRESS", value)

      assert_raise ExUnit.AssertionError, ~r/Set OPEN_PAYMENTS_INTEGRATION_WALLET_ADDRESS/, fn ->
        Interoperability.public_config(getter(input))
      end
    end

    for name <- ~w(READ_KIND RESOURCE_URL PRIVATE_KEY_FILE KEY_ID ACCESS_TOKEN_FILE) do
      assert_raise ExUnit.AssertionError, ~r/Set #{@prefix}#{name}/, fn ->
        Interoperability.signed_config(getter(Map.delete(env, @prefix <> name)))
      end
    end
  end

  test "loads registered-key configuration and a newline-terminated token file", %{
    env: env,
    pem: pem
  } do
    config = Interoperability.signed_config(getter(env))
    assert Client.authenticated?(config.client)
    refute Client.allow_http?(config.client)
    assert Client.wallet_address(config.client) == "https://wallet.example.com/alice"
    assert config.access_token == "public-test-token=="
    assert config.read_kind == "incoming"

    for value <- [
          pem,
          config.access_token,
          env[@prefix <> "PRIVATE_KEY_FILE"],
          config.resource_url
        ] do
      refute inspect(config) =~ value
    end
  end

  test "selects only supported reads and discovers the grant-spent base", %{env: env} do
    config =
      env
      |> Map.put(@prefix <> "READ_KIND", "grant_spent")
      |> Map.delete(@prefix <> "RESOURCE_URL")
      |> getter()
      |> Interoperability.signed_config()

    assert is_nil(config.resource_url)

    assert_raise ExUnit.AssertionError,
                 ~r/READ_KIND must be incoming, quote, outgoing or grant_spent/,
                 fn ->
                   Interoperability.signed_config(
                     getter(Map.put(env, @prefix <> "READ_KIND", "secret-invalid-kind"))
                   )
                 end
  end

  test "rejects unreadable or invalid key and token files without printing contents or paths", %{
    env: env,
    token_file: token_file
  } do
    for name <- ~w(PRIVATE_KEY_FILE ACCESS_TOKEN_FILE) do
      exception =
        assert_raise ExUnit.AssertionError, fn ->
          Interoperability.signed_config(
            getter(Map.put(env, @prefix <> name, "/secret/missing-file"))
          )
        end

      refute Exception.message(exception) =~ "/secret/missing-file"
    end

    for contents <- ["", " \n", "secret-token\nsecond-token", "Bearer secret-token", <<255>>] do
      File.write!(token_file, contents)

      assert_raise ExUnit.AssertionError,
                   ~r/ACCESS_TOKEN_FILE must contain one token68 access token/,
                   fn ->
                     Interoperability.signed_config(getter(env))
                   end
    end

    File.write!(env[@prefix <> "PRIVATE_KEY_FILE"], "secret-invalid-key")

    exception =
      assert_raise ExUnit.AssertionError, fn ->
        Interoperability.signed_config(getter(env))
      end

    refute Exception.message(exception) =~ "secret-invalid-key"
  end

  test "requires both the registered key identifier and public key to match", %{env: env} do
    config = Interoperability.signed_config(getter(env))
    assert Interoperability.registered?(config, %JWKS{keys: [config.public_key]})
    refute Interoperability.registered?(config, %JWKS{keys: []})

    refute Interoperability.registered?(config, %JWKS{keys: [%{config.public_key | kid: "other"}]})

    refute Interoperability.registered?(config, %JWKS{keys: [%{config.public_key | x: "other"}]})
  end

  test "each selected read sends a single signed GET to the intended resource", %{env: env} do
    Process.put({TransportAdapter, :callback}, fn request ->
      send(self(), {:request, request})
      {request, Req.Response.new(status: 401, body: ~s({"error":"invalid_token"}))}
    end)

    for {kind, operation} <- [
          {"incoming", :get_incoming_payment},
          {"quote", :get_quote},
          {"outgoing", :get_outgoing_payment},
          {"grant_spent", :get_outgoing_payment_grant}
        ] do
      config = Interoperability.signed_config(getter(Map.put(env, @prefix <> "READ_KIND", kind)))
      {:ok, key} = Key.from_file(env[@prefix <> "PRIVATE_KEY_FILE"], env[@prefix <> "KEY_ID"])

      {:ok, client} =
        Client.new_authenticated(
          wallet_address: config.wallet_address,
          key: key,
          adapter: TransportAdapter
        )

      wallet = %{resource_server: "https://resource.example.com/discovered-tenant"}

      assert {:error, %Error{kind: :http, status: 401, operation: ^operation}} =
               Interoperability.read(%{config | client: client}, wallet)

      assert_received {:request, request}
      assert request.method == :get
      assert Req.Request.get_header(request, "signature") != []
      assert Req.Request.get_header(request, "authorization") == ["GNAP public-test-token=="]

      expected =
        if kind == "grant_spent",
          do: wallet.resource_server <> "/outgoing-payment-grant",
          else: config.resource_url

      assert URI.to_string(request.url) == expected
      refute_received {:request, _request}
    end
  end

  test "failure reporting omits arbitrary server fields and successful values stay local" do
    assert Interoperability.result!({:ok, :checked}) == :checked

    error = %Error{
      kind: :http,
      status: 401,
      operation: :get_quote,
      code: "secret-code",
      description: "secret-description",
      details: %{"token" => "secret-token"}
    }

    exception =
      assert_raise ExUnit.AssertionError, fn -> Interoperability.result!({:error, error}) end

    assert String.trim(Exception.message(exception)) ==
             "Open Payments check failed: kind=http, status=401, operation=:get_quote"
  end

  defp getter(env), do: &Map.get(env, &1)
end
