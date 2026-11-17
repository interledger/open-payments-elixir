defmodule OpenPayments.WalletAddressTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Specification, WalletAddress}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.WalletAddress, as: WalletData

  @wallet %{
    "id" => "https://wallet.example.com/alice",
    "assetCode" => "USD",
    "assetScale" => 2,
    "authServer" => "https://auth.wallet.example.com/tenant",
    "resourceServer" => "https://wallet.example.com/tenant"
  }

  test "matches the pinned wallet operation's success contract" do
    operation = Enum.find(Specification.operations(), &(&1.id == "get-wallet-address"))
    assert operation.method == :get
    assert operation.server == :wallet_address
    assert operation.success_statuses == [200]
  end

  test "discovers an unsigned wallet over a real local connection" do
    wire_body = Map.merge(@wallet, %{"publicName" => "Alice", "custom" => %{"value" => nil}})

    base =
      HTTPServer.start(fn _ ->
        {200, [{"content-type", "application/json"}], Jason.encode!(wire_body)}
      end)

    {:ok, client} = Client.new_public(allow_http: true)
    assert {:ok, %WalletData{} = wallet} = WalletAddress.get(client, base <> "/accounts/alice")
    assert WalletData.to_map(wallet) == wire_body
    assert_receive {:http_request, request}
    assert request.method == "GET"
    assert request.target == "/accounts/alice"
    headers = Map.new(request.headers)
    assert headers["accept"] == "application/json"
    assert headers["accept-encoding"] == "identity"
    refute Map.has_key?(headers, "signature")
    refute Map.has_key?(headers, "authorization")
  end

  test "accepts root and path pointers with standard discovery resolution" do
    Process.put({TransportAdapter, :callback}, fn request ->
      send(self(), {:requested, URI.to_string(request.url)})
      {request, Req.Response.new(body: Jason.encode!(@wallet))}
    end)

    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for {input, expected} <- [
          {"$wallet.example.com", "https://wallet.example.com/.well-known/pay"},
          {"$wallet.example.com/", "https://wallet.example.com/.well-known/pay"},
          {"$wallet.example.com/alice%20account", "https://wallet.example.com/alice%20account"},
          {"https://Wallet.Example.COM", "https://wallet.example.com/"}
        ] do
      assert {:ok, _wallet} = WalletAddress.get(client, input)
      assert_received {:requested, ^expected}
    end
  end

  test "validates discovery identifiers before making a request" do
    Process.put({TransportAdapter, :callback}, fn _ ->
      flunk("invalid identifiers must not be requested")
    end)

    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for input <- [
          nil,
          [],
          "",
          "wallet.example.com/alice",
          "http://localhost:3000/alice",
          "https://wallet.example.com:443/alice",
          "https://wallet.example.com:8443/alice",
          "https://alice@wallet.example.com/alice",
          "https://wallet.example.com/alice?",
          "https://wallet.example.com/alice?x=1",
          "https://wallet.example.com/alice#",
          "$wallet.example.com:443/alice"
        ] do
      assert {:error, %Error{kind: :validation, operation: :get_wallet_address}} =
               WalletAddress.get(client, input)
    end

    assert {:error, %Error{kind: :configuration, operation: :get_wallet_address}} =
             WalletAddress.get(nil, "https://wallet.example.com")
  end

  test "keeps response-model URI validation independent of discovery URL policy" do
    wire =
      Map.merge(@wallet, %{
        "id" => "http://localhost:3000/accounts/alice",
        "authServer" => "http://localhost:3006/tenant",
        "resourceServer" => "https://wallet.example.com:8443/tenant?x=1"
      })

    respond(200, Jason.encode!(wire))
    {:ok, client} = Client.new_public(adapter: TransportAdapter)
    assert {:ok, wallet} = WalletAddress.get(client, "https://wallet.example.com/alice")
    assert WalletData.to_map(wallet) == wire
  end

  test "reports malformed and schema-invalid successes as decoding errors" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    for body <- [
          "",
          "not-json",
          "null",
          "[]",
          "{}",
          Jason.encode!(Map.put(@wallet, "assetScale", 256))
        ] do
      respond(200, body)

      assert {:error, %Error{kind: :decoding, status: 200, operation: :get_wallet_address}} =
               WalletAddress.get(client, "https://wallet.example.com/alice")
    end

    respond(200, Jason.encode!(Map.delete(@wallet, "resourceServer")))

    assert {:error, %Error{validation_errors: [%{field: :resource_server}]}} =
             WalletAddress.get(client, "https://wallet.example.com/alice")

    respond(204, "")

    assert {:error, %Error{kind: :decoding, code: "unexpected_status"}} =
             WalletAddress.get(client, "https://wallet.example.com/alice")
  end

  test "retains transport operation context and HTTP error fields" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)
    respond(404, ~s({"error":{"code":"not_found","description":"No wallet"}}))

    assert {:error,
            %Error{kind: :http, status: 404, code: "not_found", operation: :get_wallet_address}} =
             WalletAddress.get(client, "https://wallet.example.com/alice")

    Process.put({TransportAdapter, :callback}, fn request ->
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, %Error{kind: :transport, code: "timeout", operation: :get_wallet_address}} =
             WalletAddress.get(client, "https://wallet.example.com/alice")
  end

  test "does not follow a wallet redirect" do
    base = HTTPServer.start(fn _ -> {302, [{"location", "/other-wallet"}], "redirect"} end)
    {:ok, client} = Client.new_public(allow_http: true)

    assert {:error, %Error{kind: :http, status: 302}} =
             WalletAddress.get(client, base <> "/alice")

    assert_receive {:http_request, %{target: "/alice"}}
    refute_receive {:http_request, _}, 30
  end

  defp respond(status, body) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body)}
    end)
  end
end
