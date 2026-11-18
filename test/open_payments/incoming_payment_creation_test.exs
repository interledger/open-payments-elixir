defmodule OpenPayments.IncomingPaymentCreationTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, IncomingPayment, Key, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}

  alias OpenPayments.Types.{
    AccessToken,
    CreateIncomingPayment,
    IncomingPaymentWithMethods
  }

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @url "https://resource.example.com/tenant"
  @amount %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @payload %{"walletAddress" => "https://wallet.example.com/alice", "incomingAmount" => @amount}
  @method %{"type" => "ilp", "ilpAddress" => "g.example.alice", "sharedSecret" => "test-secret"}
  @payment %{
    "id" => "https://resource.example.com/incoming-payments/payment-1",
    "walletAddress" => "https://wallet.example.com/alice",
    "completed" => false,
    "receivedAmount" => %{@amount | "value" => "0"},
    "incomingAmount" => @amount,
    "createdAt" => "2026-11-18T09:20:50Z",
    "methods" => [@method]
  }

  test "matches the pinned creation operation and roundtrips its official examples" do
    operation = Enum.find(Specification.operations(), &(&1.id == "create-incoming-payment"))
    assert operation.method == :post and operation.server == :resource
    assert operation.success_statuses == [201]
    spec = Specification.document(:resource)["paths"]["/incoming-payments"]["post"]
    assert spec["requestBody"]["required"]

    assert spec["responses"]["201"]["content"]["application/json"]["schema"] ==
             %{"$ref" => "#/components/schemas/incoming-payment-with-access-token"}

    requests = spec["requestBody"]["content"]["application/json"]["examples"]
    responses = spec["responses"]["201"]["content"]["application/json"]["examples"]
    assert map_size(requests) > 0 and map_size(responses) > 0

    for {_name, %{"value" => payload}} <- requests,
        {_name, %{"value" => wire}} <- responses do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert Jason.decode!(request.body) == payload
        {request, Req.Response.new(status: 201, body: Jason.encode!(wire))}
      end)

      assert {:ok, payment} =
               IncomingPayment.create(client(adapter: TransportAdapter), @url, payload,
                 access_token: "test-token"
               )

      assert IncomingPaymentWithMethods.to_map(payment) == wire
    end
  end

  test "signs the exact POST body, authorization and tenant URL for typed or map payloads" do
    payload =
      Map.merge(@payload, %{
        "expiresAt" => "2020-01-01T01:00:00+01:00",
        "metadata" => %{"memo" => "café", "items" => [1, true, nil]}
      })

    {:ok, typed} = CreateIncomingPayment.from_map(payload)
    base = HTTPServer.start(fn _ -> {201, [], Jason.encode!(@payment)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "create-1"})
    original = client

    for {request, supplied, suffix} <- [
          {payload, "test-resource-token", "/tenant%2falpha"},
          {typed, token(), "/tenant%2falpha/"}
        ] do
      assert {:ok, %IncomingPaymentWithMethods{} = payment} =
               IncomingPayment.create(client, base <> suffix, request, access_token: supplied)

      assert IncomingPaymentWithMethods.to_map(payment) == @payment
      assert_receive {:http_request, wire}
      assert wire.method == "POST" and wire.target == "/tenant%2falpha/incoming-payments"
      assert Jason.decode!(wire.body) == payload
      headers = Map.new(wire.headers)
      assert headers["authorization"] == "GNAP test-resource-token"
      assert headers["content-type"] == "application/json"
      assert headers["content-length"] == Integer.to_string(byte_size(wire.body))
      assert headers["x-request-id"] == "create-1"
      assert headers["accept"] == "application/json"
      assert headers["accept-encoding"] == "identity"
      assert verify_wire(wire)
      refute verify_wire(%{wire | body: wire.body <> " "})
      refute verify_wire(%{wire | target: wire.target <> "tampered"})

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

      refute inspect(payment) =~ "test-secret"
    end

    assert client == original
  end

  test "appends once for root, trailing slash and HTTPS port bases without replacing path prefixes" do
    client = client(adapter: TransportAdapter)

    for {base, expected} <- [
          {"https://RESOURCE.example.com", "https://resource.example.com/incoming-payments"},
          {"https://resource.example.com/", "https://resource.example.com/incoming-payments"},
          {"https://resource.example.com:8443/tenant",
           "https://resource.example.com:8443/tenant/incoming-payments"},
          {"https://resource.example.com/tenant//",
           "https://resource.example.com/tenant//incoming-payments"}
        ] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert URI.to_string(request.url) == expected
        {request, Req.Response.new(status: 201, body: Jason.encode!(@payment))}
      end)

      assert {:ok, _} = IncomingPayment.create(client, base, @payload, access_token: "test-token")
    end
  end

  test "rejects invalid base URLs and queries before sending" do
    no_request()

    for url <- [
          nil,
          [],
          "",
          "/tenant",
          "$wallet.example.com/alice",
          "urn:example:server",
          "http://localhost:3000",
          "ftp://resource.example.com",
          "https://user@resource.example.com",
          "https://resource.example.com/#part",
          "https://resource.example.com:65536",
          @url <> "?part=1",
          @url <> "?"
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :create_incoming_payment,
                validation_errors: [%{field: :url}]
              }} =
               IncomingPayment.create(client(adapter: TransportAdapter), url, @payload,
                 access_token: "test-token"
               )
    end
  end

  test "requires an authenticated client and revalidates key and per-call token options" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for invalid <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :create_incoming_payment}} =
               IncomingPayment.create(invalid, @url, @payload, access_token: "test-token")
    end

    for opts <- [
          nil,
          %{},
          [],
          [access_token: nil],
          [access_token: %{"value" => "private-token"}],
          [access_token: "test", access_token: "other"],
          [access_token: "test", headers: %{}],
          [access_token: "test", key: "private-key"],
          [access_token: "private-token\r\n"],
          [access_token: %{token() | manage: "private-relative"}]
        ] do
      assert {:error, %Error{kind: :validation, operation: :create_incoming_payment} = error} =
               IncomingPayment.create(client, @url, @payload, opts)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "validates raw payloads and revalidates modified typed nested fields before HTTP" do
    no_request()
    {:ok, typed} = CreateIncomingPayment.from_map(@payload)

    for {payload, field} <- [
          {nil, :create_incoming_payment},
          {%{}, :wallet_address},
          {%{"wallet_address" => "private-wallet"}, :wallet_address},
          {Map.put(@payload, "extra", "private-metadata"), :create_incoming_payment},
          {Map.put(@payload, "metadata", nil), :metadata},
          {%{typed | wallet_address: "private-relative"}, :wallet_address},
          {%{typed | incoming_amount: %{typed.incoming_amount | value: "private-amount"}},
           "incoming_amount.value"},
          {%{typed | incoming_amount: @amount}, :incoming_amount},
          {%{typed | metadata: %{"private" => self()}}, :metadata}
        ] do
      assert {:error, %Error{kind: :validation, operation: :create_incoming_payment} = error} =
               IncomingPayment.create(client(adapter: TransportAdapter), @url, payload,
                 access_token: "test-token"
               )

      assert Enum.any?(error.validation_errors, &(&1.field == field))
      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "sends minimal payloads without defaults and preserves zero amounts and past expiry" do
    client = client(adapter: TransportAdapter)

    for payload <- [
          Map.take(@payload, ["walletAddress"]),
          Map.merge(@payload, %{
            "incomingAmount" => %{@amount | "value" => "0000"},
            "metadata" => %{},
            "expiresAt" => "2020-01-01T00:00:00Z"
          })
        ] do
      wire = @payment |> Map.delete("incomingAmount") |> Map.put("methods", [])

      Process.put({TransportAdapter, :callback}, fn request ->
        assert Jason.decode!(request.body) == payload
        {request, Req.Response.new(status: 201, body: Jason.encode!(wire))}
      end)

      assert {:ok, payment} =
               IncomingPayment.create(client, @url, payload, access_token: "test-token")

      assert payment.incoming_amount == nil and payment.methods == []
    end
  end

  test "enforces Node's creation postconditions after schema decoding" do
    client = client(adapter: TransportAdapter)

    for {wire, field} <- [
          {%{@payment | "receivedAmount" => @amount}, "received_amount.value"},
          {%{@payment | "completed" => true}, :completed},
          {%{@payment | "incomingAmount" => %{@amount | "assetCode" => "EUR"}}, :incoming_amount},
          {%{@payment | "receivedAmount" => %{@amount | "value" => "0", "assetScale" => 3}},
           :incoming_amount}
        ] do
      assert {:ok, _} = IncomingPaymentWithMethods.from_map(wire)
      respond(201, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                status: 201,
                code: "invalid_response",
                operation: :create_incoming_payment,
                validation_errors: [%{field: ^field}]
              } = error} =
               IncomingPayment.create(client, @url, @payload, access_token: "test-token")

      refute inspect(Map.from_struct(error)) =~ "EUR"
    end
  end

  test "accepts leading-zero received funds and server values independent of request and client identity" do
    wire =
      Map.merge(@payment, %{
        "receivedAmount" => %{@amount | "value" => "0000"},
        "walletAddress" => "https://another.example.com/wallet",
        "incomingAmount" => %{@amount | "value" => "3000"},
        "metadata" => %{"server" => true}
      })

    respond(201, Jason.encode!(wire))

    assert {:ok, payment} =
             IncomingPayment.create(client(adapter: TransportAdapter), @url, @payload,
               access_token: %{token() | expires_in: -1}
             )

    assert IncomingPaymentWithMethods.to_map(payment) == wire
  end

  test "requires 201 and a complete authenticated schema with safe JSON and encoding errors" do
    client = client(adapter: TransportAdapter)

    for {status, body, headers, code} <- [
          {200, Jason.encode!(@payment), [], "unexpected_status"},
          {204, "", [], "unexpected_status"},
          {201, "private-invalid-json", [], "invalid_json"},
          {201, Jason.encode!(@payment), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"},
          {201, "null", [], "invalid_response"},
          {201, Jason.encode!(Map.delete(@payment, "methods")), [], "invalid_response"},
          {201, Jason.encode!(Map.delete(@payment, "completed")), [], "invalid_response"},
          {201,
           Jason.encode!(
             @payment
             |> Map.delete("walletAddress")
             |> Map.put("authServer", "https://auth.example.com")
           ), [], "invalid_response"}
        ] do
      respond(status, body, headers)

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: ^code,
                operation: :create_incoming_payment
              } = error} =
               IncomingPayment.create(client, @url, @payload, access_token: "test-token")

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    respond(
      201,
      Jason.encode!(%{@payment | "methods" => [%{@method | "sharedSecret" => "private-secret="}]})
    )

    assert {:error, %Error{validation_errors: [%{field: "methods[0].shared_secret"}]} = error} =
             IncomingPayment.create(client, @url, @payload, access_token: "test-token")

    refute inspect(Map.from_struct(error)) =~ "private-secret"
  end

  test "preserves server errors without raw bodies or automatic grant refresh" do
    client = client(adapter: TransportAdapter)

    for status <- [401, 403, 409, 422] do
      respond(status, ~s({"error":{"code":"denied","description":"Not permitted"}}))

      assert {:error,
              %Error{
                kind: :http,
                status: ^status,
                code: "denied",
                operation: :create_incoming_payment
              }} =
               IncomingPayment.create(client, @url, @payload, access_token: "test-token")
    end

    respond(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             IncomingPayment.create(client, @url, @payload, access_token: "test-token")

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not follow redirects or replay creation on server errors or dropped connections" do
    base =
      HTTPServer.start(fn request ->
        case request.target do
          "/redirect/incoming-payments" -> {307, [{"location", "/other"}], ""}
          "/unavailable/incoming-payments" -> {503, [], "failed"}
          "/dropped/incoming-payments" -> :close
        end
      end)

    client = client(allow_http: true)

    for {prefix, kind, status} <- [
          {"/redirect", :http, 307},
          {"/unavailable", :http, 503},
          {"/dropped", :transport, nil}
        ] do
      assert {:error, %Error{kind: ^kind, status: ^status, operation: :create_incoming_payment}} =
               IncomingPayment.create(client, base <> prefix, @payload,
                 access_token: "test-token"
               )

      target = prefix <> "/incoming-payments"
      assert_receive {:http_request, %{method: "POST", target: ^target}}
      refute_receive {:http_request, _}, 30
    end
  end

  test "reports timeout once without replaying an ambiguous creation" do
    Process.put({TransportAdapter, :callback}, fn request ->
      send(self(), :attempt)
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error,
            %Error{kind: :transport, code: "timeout", operation: :create_incoming_payment}} =
             IncomingPayment.create(client(adapter: TransportAdapter), @url, @payload,
               access_token: "test-token"
             )

    assert_received :attempt
    refute_received :attempt
  end

  test "isolates credentials and payloads for concurrent creations with a shared client" do
    base =
      HTTPServer.start(fn request ->
        body = Jason.decode!(request.body)

        wire =
          Map.put(@payment, "metadata", %{
            "authorization" => Map.new(request.headers)["authorization"],
            "request" => body["metadata"]
          })

        {201, [], Jason.encode!(wire)}
      end)

    client = client(allow_http: true)

    tasks =
      for value <- ["token-a", "token-b"] do
        {value,
         Task.async(fn ->
           IncomingPayment.create(
             client,
             base,
             Map.put(@payload, "metadata", %{"value" => value}),
             access_token: value
           )
         end)}
      end

    for {value, task} <- tasks do
      assert {:ok, payment} = Task.await(task)

      assert payment.metadata == %{
               "authorization" => "GNAP " <> value,
               "request" => %{"value" => value}
             }
    end

    for _ <- 1..2 do
      assert_receive {:http_request, wire}
      value = Jason.decode!(wire.body)["metadata"]["value"]
      assert Map.new(wire.headers)["authorization"] == "GNAP " <> value
      assert verify_wire(wire)
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

  defp token do
    {:ok, token} =
      AccessToken.from_map(%{
        "value" => "test-resource-token",
        "manage" => "https://auth.example.com/manage/id",
        "access" => []
      })

    token
  end

  defp no_request,
    do: Process.put({TransportAdapter, :callback}, fn _ -> flunk("unexpected HTTP request") end)

  defp respond(status, body, headers \\ []) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body, headers: headers)}
    end)
  end

  # Verify body digest and signature independently against actual wire bytes.
  defp verify_wire(wire) do
    headers = Map.new(wire.headers)
    digest = "sha-512=:" <> Base.encode64(:crypto.hash(:sha512, wire.body)) <> ":"
    "sig1=" <> params = headers["signature-input"]

    assert String.starts_with?(
             params,
             ~s|("@method" "@target-uri" "authorization" "content-digest" "content-length" "content-type");keyid="example-key-1";created=|
           )

    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, headers["signature"])

    base =
      Enum.join(
        [
          ~s("@method": #{wire.method}),
          ~s("@target-uri": http://#{headers["host"]}#{wire.target}),
          ~s("authorization": #{headers["authorization"]}),
          ~s("content-digest": #{headers["content-digest"]}),
          ~s("content-length": #{headers["content-length"]}),
          ~s("content-type": #{headers["content-type"]}),
          ~s("@signature-params": #{params})
        ],
        "\n"
      )

    digest == headers["content-digest"] and
      :crypto.verify(:eddsa, :none, base, Base.decode64!(encoded), [@public, :ed25519])
  end
end
