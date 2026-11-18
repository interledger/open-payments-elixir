defmodule PackageConsumerTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Grant, Key, OutgoingPayment, Specification, WalletAddress}
  alias OpenPayments.Types.{AccessToken, Amount, CreateOutgoingPayment, CreateQuote, JWK}
  alias PackageConsumer.Adapter

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @wallet "https://wallet.example.com/alice"

  test "bundled specifications retain provenance, checksums and all operation data" do
    directory =
      :open_payments_elixir |> :code.priv_dir() |> List.to_string() |> Path.join("specifications")

    source = directory |> Path.join("SOURCE.json") |> File.read!() |> Jason.decode!()
    assert Specification.version() == source["version"]
    assert Specification.revision() == source["commit"]
    assert length(Specification.operations()) == 17

    for filename <- source["files"] do
      bytes = directory |> Path.join(filename) |> File.read!()

      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
               source["sha256"][filename]
    end

    assert Specification.document(:resource)["paths"]["/outgoing-payment-grant"]
  end

  test "the consumer has runtime dependencies without SDK development dependencies or checkout files" do
    dependencies = Map.keys(Mix.Project.deps_paths())

    for app <- [:open_payments_elixir, :req, :jason, :message_signatures],
        do: assert(app in dependencies)

    for app <- [:credo, :dialyxir, :ex_doc, :stream_data, :bandit, :plug],
        do: refute(app in dependencies)

    refute Code.ensure_loaded?(OpenPayments.Test.HTTPServer)
    source = Path.expand("../vendor/open_payments_elixir", __DIR__)
    refute File.dir?(Path.join(source, ".git"))
    refute File.dir?(Path.join(source, "test"))
    refute File.dir?(Path.join(source, "deps"))
    refute File.exists?(Path.join(source, "mix.lock"))
  end

  test "packaged public operation modules load from the dependency" do
    for {module, functions} <- [
          {WalletAddress, [get: 2, get_keys: 2]},
          {Grant, [request: 3, continue: 2, continue: 3, cancel: 2]},
          {OpenPayments.Token, [rotate: 2, revoke: 2]},
          {OpenPayments.IncomingPayment,
           [get_public: 2, get: 3, create: 4, complete: 3, list: 4]},
          {OpenPayments.Quote, [get: 3, create: 4]},
          {OutgoingPayment, [get: 3, create: 4, list: 4, get_grant_spent_amounts: 3]}
        ] do
      Code.ensure_loaded!(module)
      for {function, arity} <- functions, do: assert(function_exported?(module, function, arity))
    end
  end

  test "typed request encoders work after consumer protocol consolidation" do
    {:ok, amount} = Amount.new("0001", "USD", 2)

    quote = %CreateQuote{
      wallet_address: @wallet,
      receiver: "https://receiver.example.com/incoming-payments/in-1",
      method: "ilp",
      debit_amount: amount
    }

    payment = %CreateOutgoingPayment{
      wallet_address: @wallet,
      incoming_payment: quote.receiver,
      debit_amount: amount,
      metadata: %{"memo" => "café"}
    }

    assert Jason.decode!(Jason.encode!(quote))["debitAmount"]["value"] == "0001"
    assert Jason.decode!(Jason.encode!(payment))["metadata"] == %{"memo" => "café"}
  end

  test "OTP signing works with independent public-key verification and no private JSON export" do
    key = key()

    assert key |> Key.public_jwk() |> JWK.to_map() |> Map.fetch!("x") ==
             Base.url_encode64(@public, padding: false)

    {:ok, signature} = Key.sign(key, "package consumer")
    assert :crypto.verify(:eddsa, :none, "package consumer", signature, [@public, :ed25519])
    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(key) end
  end

  test "public discovery uses the consumer's adapter and remains unsigned" do
    Process.put({Adapter, :reply}, fn request ->
      assert URI.to_string(request.url) == @wallet
      assert Req.Request.get_header(request, "signature") == []
      assert Req.Request.get_header(request, "authorization") == []

      {request,
       Req.Response.new(
         body:
           Jason.encode!(%{
             "id" => @wallet,
             "assetCode" => "USD",
             "assetScale" => 2,
             "authServer" => "https://auth.example.com/tenant",
             "resourceServer" => "https://resource.example.com/tenant"
           })
       )}
    end)

    {:ok, client} = Client.new_public(adapter: Adapter)
    assert {:ok, wallet} = WalletAddress.get(client, @wallet)
    assert wallet.resource_server == "https://resource.example.com/tenant"
  end

  test "signed grant and resource requests work using only packaged runtime code" do
    {:ok, client} =
      Client.new_authenticated(wallet_address: @wallet, key: key(), adapter: Adapter)

    Process.put({Adapter, :reply}, fn request ->
      assert request.method == :post
      assert Req.Request.get_header(request, "authorization") == []
      assert Jason.decode!(request.body)["client"] == @wallet
      verify_signature(request)

      {request,
       Req.Response.new(
         body:
           Jason.encode!(%{
             "continue" => %{
               "uri" => "https://auth.example.com/continue/id",
               "access_token" => %{"value" => "continue-token"}
             },
             "access_token" => %{
               "value" => "resource-token",
               "manage" => "https://auth.example.com/manage/id",
               "access" => []
             }
           })
       )}
    end)

    {:ok, grant} =
      Grant.request(client, "https://auth.example.com/tenant", %{
        "access_token" => %{"access" => [%{"type" => "quote", "actions" => ["create"]}]}
      })

    assert %AccessToken{} = grant.access_token

    Process.put({Adapter, :reply}, fn request ->
      assert request.method == :get

      assert URI.to_string(request.url) ==
               "https://resource.example.com/tenant/outgoing-payment-grant"

      assert Req.Request.get_header(request, "authorization") == ["GNAP resource-token"]
      assert request.body == nil
      verify_signature(request)
      {request, Req.Response.new(body: ~s({"spentReceiveAmount":null,"spentDebitAmount":null}))}
    end)

    resource_server = "https://resource.example.com/tenant"

    assert {:ok, spent} =
             OutgoingPayment.get_grant_spent_amounts(
               client,
               resource_server,
               access_token: grant.access_token
             )

    assert Jason.decode!(Jason.encode!(spent)) == %{
             "spentReceiveAmount" => nil,
             "spentDebitAmount" => nil
           }
  end

  defp key do
    {:ok, key} = Key.from_seed(@seed, "consumer-key")
    key
  end

  defp verify_signature(request) do
    auth =
      if Req.Request.get_header(request, "authorization") == [], do: [], else: ["authorization"]

    content =
      if is_nil(request.body), do: [], else: ["content-digest", "content-length", "content-type"]

    components = ["@method", "@target-uri"] ++ auth ++ content
    ["sig1=" <> params] = Req.Request.get_header(request, "signature-input")

    prefix =
      "(" <> Enum.map_join(components, " ", &~s("#{&1}")) <> ~s|);keyid="consumer-key";created=|

    assert String.starts_with?(params, prefix)

    if content != [] do
      assert Req.Request.get_header(request, "content-digest") == [
               "sha-512=:#{Base.encode64(:crypto.hash(:sha512, request.body))}:"
             ]

      assert Req.Request.get_header(request, "content-length") == [
               Integer.to_string(byte_size(request.body))
             ]
    end

    base =
      Enum.map_join(components, "\n", fn
        "@method" -> ~s("@method": #{request.method |> Atom.to_string() |> String.upcase()})
        "@target-uri" -> ~s("@target-uri": #{URI.to_string(request.url)})
        name -> ~s("#{name}": #{hd(Req.Request.get_header(request, name))})
      end) <> "\n" <> ~s("@signature-params": #{params})

    [signature] = Req.Request.get_header(request, "signature")
    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, signature)
    assert :crypto.verify(:eddsa, :none, base, Base.decode64!(encoded), [@public, :ed25519])
  end
end
