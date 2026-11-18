defmodule OpenPayments.IncomingPaymentCompletionTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, IncomingPayment, Key, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{AccessToken, ContinuationToken, IncomingPaymentWithMethods}
  alias OpenPayments.Types.IncomingPayment, as: IncomingPaymentData

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @url "https://resource.example.com/tenant/incoming-payments/payment-1"
  @amount %{"value" => "250", "assetCode" => "USD", "assetScale" => 2}
  @payment %{
    "id" => @url,
    "walletAddress" => "https://wallet.example.com/alice",
    "completed" => true,
    "receivedAmount" => @amount,
    "incomingAmount" => @amount,
    "createdAt" => "2026-11-18T09:20:50Z"
  }
  @method %{"type" => "ilp", "ilpAddress" => "g.example.alice", "sharedSecret" => "test-secret"}

  test "matches the pinned bodyless completion operation and decodes its official example" do
    operation = Enum.find(Specification.operations(), &(&1.id == "complete-incoming-payment"))
    assert operation.method == :post and operation.server == :resource
    assert operation.success_statuses == [200]
    spec = Specification.document(:resource)["paths"]["/incoming-payments/{id}/complete"]["post"]
    refute Map.has_key?(spec, "requestBody")
    content = spec["responses"]["200"]["content"]["application/json"]

    assert content["schema"] == %{
             "$ref" => "#/components/schemas/incoming-payment",
             "additionalProperties" => false
           }

    assert map_size(content["examples"]) > 0

    for {_name, %{"value" => wire}} <- content["examples"] do
      respond(200, Jason.encode!(wire))

      assert {:ok, payment} =
               IncomingPayment.complete(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )

      assert IncomingPaymentData.to_map(payment) == wire
    end
  end

  test "sends signed bodyless POSTs with raw or typed tokens and an appended complete path" do
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(@payment)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "complete-1"})
    original = client

    for {supplied, suffix} <- [
          {"test-resource-token", "/tenant/opaque%2fresource/../payment"},
          {token(), "/tenant/opaque%2fresource/../payment/"}
        ] do
      assert {:ok, %IncomingPaymentData{} = payment} =
               IncomingPayment.complete(client, base <> suffix, access_token: supplied)

      assert IncomingPaymentData.to_map(payment) == @payment
      assert_receive {:http_request, wire}

      assert wire.method == "POST" and
               wire.target == "/tenant/opaque%2fresource/../payment/complete"

      assert wire.body == ""
      headers = Map.new(wire.headers)
      assert headers["authorization"] == "GNAP test-resource-token"
      assert headers["accept"] == "application/json"
      assert headers["accept-encoding"] == "identity"
      assert headers["x-request-id"] == "complete-1"
      refute Map.has_key?(headers, "content-digest")
      refute Map.has_key?(headers, "content-type")
      assert verify_wire(wire)
      refute verify_wire(%{wire | method: "GET"})
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
    end

    assert client == original
  end

  test "preserves HTTPS ports and opaque paths without guessing provider layout" do
    for {url, expected} <- [
          {"https://RESOURCE.example.com:8443/tenant/opaque",
           "https://resource.example.com:8443/tenant/opaque/complete"},
          {"https://resource.example.com/tenant//opaque//",
           "https://resource.example.com/tenant//opaque//complete"}
        ] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert URI.to_string(request.url) == expected
        {request, Req.Response.new(body: Jason.encode!(@payment))}
      end)

      assert {:ok, _} =
               IncomingPayment.complete(client(adapter: TransportAdapter), url,
                 access_token: "test-token"
               )
    end
  end

  test "rejects invalid payment URLs and all query markers before HTTP" do
    no_request()

    for url <- [
          nil,
          [],
          "",
          "/incoming-payments/id",
          "$wallet.example.com/alice",
          "urn:example:payment",
          "http://localhost:3000/id",
          "ftp://resource.example.com/id",
          "https://user@resource.example.com/id",
          @url <> "#fragment",
          "https://resource.example.com:65536/id",
          @url <> "?part=1",
          @url <> "?"
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :complete_incoming_payment,
                validation_errors: [%{field: :url}]
              }} =
               IncomingPayment.complete(client(adapter: TransportAdapter), url,
                 access_token: "test-token"
               )
    end
  end

  test "requires an authenticated client and strictly supported per-call token options" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for invalid <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :complete_incoming_payment}} =
               IncomingPayment.complete(invalid, @url, access_token: "test-token")
    end

    {:ok, continuation} = ContinuationToken.from_map(%{"value" => "private-token"})

    for opts <- [
          nil,
          %{},
          [:bad],
          [],
          [access_token: nil],
          [access_token: continuation],
          [access_token: %{"value" => "private-token"}],
          [access_token: "test", access_token: "other"],
          [access_token: "test", key: "private-key"],
          [access_token: "test", headers: %{}],
          [access_token: "test", json: %{}]
        ] do
      assert {:error, %Error{kind: :validation, operation: :complete_incoming_payment} = error} =
               IncomingPayment.complete(client, @url, opts)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "revalidates typed tokens and token68 before HTTP without leaking rejected data" do
    no_request()

    for {supplied, field} <- [
          {%{token() | value: nil}, "access_token.value"},
          {%{token() | manage: "private-relative"}, "access_token.manage"},
          {%{token() | access: nil}, "access_token.access"},
          {"private-token\r\n", :access_token}
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :complete_incoming_payment,
                validation_errors: [%{field: ^field}]
              } = error} =
               IncomingPayment.complete(client(adapter: TransportAdapter), @url,
                 access_token: supplied
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "requires completed true beyond the standalone data codec and retains response status" do
    wire = %{@payment | "completed" => false}
    assert {:ok, _} = IncomingPaymentData.from_map(wire)
    respond(200, Jason.encode!(wire))

    assert {:error,
            %Error{
              kind: :decoding,
              status: 200,
              code: "invalid_response",
              operation: :complete_incoming_payment,
              validation_errors: [%{field: :completed}]
            }} =
             IncomingPayment.complete(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )
  end

  test "enforces incoming and received asset consistency for completion responses" do
    for incoming <- [%{@amount | "assetCode" => "EUR"}, %{@amount | "assetScale" => 3}] do
      wire = %{@payment | "incomingAmount" => incoming}
      assert {:ok, _} = IncomingPaymentData.from_map(wire)
      respond(200, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                status: 200,
                code: "invalid_response",
                operation: :complete_incoming_payment,
                validation_errors: [%{field: :incoming_amount}]
              } = error} =
               IncomingPayment.complete(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "EUR"
    end
  end

  test "permits absent incoming amount, partial and zero receipts, past expiry and nested extensions" do
    client = client(adapter: TransportAdapter)
    supplied_token = %{token() | expires_in: -1}

    for wire <- [
          Map.delete(@payment, "incomingAmount"),
          %{@payment | "receivedAmount" => %{@amount | "value" => "001"}},
          Map.merge(@payment, %{
            "receivedAmount" =>
              Map.put(%{@amount | "value" => "000"}, "custom", %{"nested" => true}),
            "expiresAt" => "2020-01-01T00:00:00Z",
            "metadata" => %{"private-memo" => "private-value"}
          })
        ] do
      respond(200, Jason.encode!(wire))

      assert {:ok, payment} =
               IncomingPayment.complete(client, "https://alias.example.com/opaque",
                 access_token: supplied_token
               )

      assert IncomingPaymentData.to_map(payment) == wire
      refute inspect(payment) =~ "private-"
    end
  end

  test "applies endpoint closure to combined detail fields while leaving the standalone codec extensible" do
    for {key, value} <- [
          {"custom-private-field", "private-value"},
          {"methods", [@method]},
          {"authServer", "https://auth.example.com"}
        ] do
      wire = Map.put(@payment, key, value)
      assert {:ok, _} = IncomingPaymentData.from_map(wire)
      respond(200, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                status: 200,
                code: "invalid_response",
                operation: :complete_incoming_payment,
                validation_errors: [%{field: :incoming_payment}]
              } = error} =
               IncomingPayment.complete(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
      refute inspect(Map.from_struct(error)) =~ "test-secret"
    end
  end

  test "classifies malformed or wrong-status success responses and nested schema errors safely" do
    for {status, body, headers, code} <- [
          {201, Jason.encode!(@payment), [], "unexpected_status"},
          {204, "", [], "unexpected_status"},
          {200, "private-invalid-json", [], "invalid_json"},
          {200, Jason.encode!(@payment), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"},
          {200, "null", [], "invalid_response"},
          {200, Jason.encode!(Map.delete(@payment, "completed")), [], "invalid_response"},
          {200, Jason.encode!(Map.delete(@payment, "walletAddress")), [], "invalid_response"},
          {200, Jason.encode!(Map.put(@payment, "metadata", nil)), [], "invalid_response"}
        ] do
      respond(status, body, headers)

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: ^code,
                operation: :complete_incoming_payment
              } = error} =
               IncomingPayment.complete(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    respond(
      200,
      Jason.encode!(%{@payment | "receivedAmount" => %{@amount | "value" => "private-amount"}})
    )

    assert {:error, %Error{validation_errors: [%{field: "received_amount.value"}]} = error} =
             IncomingPayment.complete(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )

    refute inspect(Map.from_struct(error)) =~ "private-amount"
  end

  test "retains HTTP errors without raw bodies or refreshing credentials" do
    for status <- [401, 403, 404, 409] do
      respond(status, ~s({"error":{"code":"denied","description":"Not permitted"}}))

      assert {:error,
              %Error{
                kind: :http,
                status: ^status,
                code: "denied",
                operation: :complete_incoming_payment
              }} =
               IncomingPayment.complete(client(adapter: TransportAdapter), @url,
                 access_token: "test-token"
               )
    end

    respond(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             IncomingPayment.complete(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not redirect, retry server failures or replay ambiguous transport outcomes" do
    base =
      HTTPServer.start(fn request ->
        case request.target do
          "/redirect/complete" -> {307, [{"location", "/other"}], ""}
          "/unavailable/complete" -> {503, [], "failed"}
          "/dropped/complete" -> :close
        end
      end)

    client = client(allow_http: true)

    for {prefix, kind, status} <- [
          {"/redirect", :http, 307},
          {"/unavailable", :http, 503},
          {"/dropped", :transport, nil}
        ] do
      assert {:error, %Error{kind: ^kind, status: ^status, operation: :complete_incoming_payment}} =
               IncomingPayment.complete(client, base <> prefix, access_token: "test-token")

      target = prefix <> "/complete"
      assert_receive {:http_request, %{method: "POST", target: ^target}}
      refute_receive {:http_request, _}, 30
    end

    Process.put({TransportAdapter, :callback}, fn request ->
      send(self(), :attempt)
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error,
            %Error{kind: :transport, code: "timeout", operation: :complete_incoming_payment}} =
             IncomingPayment.complete(client(adapter: TransportAdapter), @url,
               access_token: "test-token"
             )

    assert_received :attempt
    refute_received :attempt
  end

  test "isolates credentials and resource URLs during concurrent completion" do
    base =
      HTTPServer.start(fn request ->
        {200, [],
         Jason.encode!(
           Map.put(@payment, "metadata", %{
             "auth" => Map.new(request.headers)["authorization"],
             "path" => request.target
           })
         )}
      end)

    client = client(allow_http: true)

    tasks =
      for value <- ["token-a", "token-b"] do
        {value,
         Task.async(fn ->
           IncomingPayment.complete(client, base <> "/" <> value, access_token: value)
         end)}
      end

    for {value, task} <- tasks do
      assert {:ok, payment} = Task.await(task)

      assert payment.metadata == %{
               "auth" => "GNAP " <> value,
               "path" => "/" <> value <> "/complete"
             }
    end

    for _ <- 1..2 do
      assert_receive {:http_request, wire}

      assert wire.target ==
               "/" <>
                 String.replace_prefix(Map.new(wire.headers)["authorization"], "GNAP ", "") <>
                 "/complete"

      assert verify_wire(wire)
    end
  end

  test "creates, completes and reads fresh state through the public SDK without implicit extra calls" do
    created =
      Map.merge(@payment, %{
        "completed" => false,
        "receivedAmount" => %{@amount | "value" => "0"},
        "methods" => [@method]
      })

    base =
      HTTPServer.start(fn request ->
        case {request.method, request.target} do
          {"POST", "/incoming-payments"} ->
            {201, [], Jason.encode!(created)}

          {"POST", "/incoming-payments/payment-1/complete"} ->
            Process.put(:payment_completed, true)
            {200, [], Jason.encode!(@payment)}

          {"GET", "/incoming-payments/payment-1"} ->
            wire = Map.put(created, "completed", Process.get(:payment_completed, false))
            {200, [], Jason.encode!(wire)}
        end
      end)

    client = client(allow_http: true)
    payload = %{"walletAddress" => @payment["walletAddress"]}
    resource = base <> "/incoming-payments/payment-1"

    assert {:ok, %IncomingPaymentWithMethods{completed: false}} =
             IncomingPayment.create(client, base, payload, access_token: token())

    assert {:ok, %IncomingPaymentData{completed: true}} =
             IncomingPayment.complete(client, resource, access_token: token())

    assert {:ok, %IncomingPaymentWithMethods{completed: true}} =
             IncomingPayment.get(client, resource, access_token: token())

    assert_receive {:http_request, %{method: "POST", target: "/incoming-payments"}}

    assert_receive {:http_request,
                    %{method: "POST", target: "/incoming-payments/payment-1/complete"} = wire}

    assert verify_wire(wire)

    assert_receive {:http_request,
                    %{method: "GET", target: "/incoming-payments/payment-1"} = wire}

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

  # Independently reconstruct the signature base from actual bodyless wire requests.
  defp verify_wire(wire) do
    headers = Map.new(wire.headers)
    "sig1=" <> params = headers["signature-input"]

    assert String.starts_with?(
             params,
             ~s|("@method" "@target-uri" "authorization");keyid="example-key-1";created=|
           )

    [_, encoded] = Regex.run(~r/\Asig1=:([^:]+):\z/, headers["signature"])

    base =
      Enum.join(
        [
          ~s("@method": #{wire.method}),
          ~s("@target-uri": http://#{headers["host"]}#{wire.target}),
          ~s("authorization": #{headers["authorization"]}),
          ~s("@signature-params": #{params})
        ],
        "\n"
      )

    :crypto.verify(:eddsa, :none, base, Base.decode64!(encoded), [@public, :ed25519])
  end
end
