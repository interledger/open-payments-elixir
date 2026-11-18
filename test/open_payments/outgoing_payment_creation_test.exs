defmodule OpenPayments.OutgoingPaymentCreationTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Key, OutgoingPayment, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{AccessToken, ContinuationToken, CreateOutgoingPayment}
  alias OpenPayments.Types.OutgoingPayment, as: PaymentDetails
  alias OpenPayments.Types.OutgoingPaymentWithSpentAmounts, as: PaymentData

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @url "https://resource.example.com/tenant"
  @payload %{
    "walletAddress" => "https://wallet.example.com/alice",
    "quoteId" => "https://resource.example.com/quotes/payment-1"
  }
  @debit %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @receive %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2}
  @direct %{
    "walletAddress" => "https://wallet.example.com/alice",
    "incomingPayment" => "https://receiver.example.com/incoming-payments/payment-1",
    "debitAmount" => @debit
  }
  @payment %{
    "id" => "https://resource.example.com/outgoing-payments/payment-1",
    "walletAddress" => "https://wallet.example.com/alice",
    "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
    "debitAmount" => @debit,
    "receiveAmount" => @receive,
    "sentAmount" => %{"value" => "0", "assetCode" => "USD", "assetScale" => 2},
    "failed" => false,
    "grantSpentDebitAmount" => @debit,
    "createdAt" => "2026-11-18T09:20:50Z"
  }

  test "matches pinned POST/201 and round trips all official request variants and response examples" do
    operation = Enum.find(Specification.operations(), &(&1.id == "create-outgoing-payment"))
    assert operation.method == :post and operation.server == :resource
    assert operation.success_statuses == [201]
    spec = Specification.document(:resource)["paths"]["/outgoing-payments"]["post"]
    assert spec["requestBody"]["required"]

    assert spec["responses"]["201"]["content"]["application/json"]["schema"] == %{
             "$ref" => "#/components/schemas/outgoing-payment-with-spent-amounts"
           }

    requests = spec["requestBody"]["content"]["application/json"]["examples"]
    responses = spec["responses"]["201"]["content"]["application/json"]["examples"]
    assert map_size(requests) == 2 and map_size(responses) > 0

    for {_name, %{"value" => payload}} <- requests, {_name, %{"value" => wire}} <- responses do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert Jason.decode!(request.body) == payload
        {request, Req.Response.new(status: 201, body: Jason.encode!(wire))}
      end)

      assert {:ok, payment} =
               OutgoingPayment.create(client(adapter: TransportAdapter), @url, payload,
                 access_token: token()
               )

      assert PaymentData.to_map(payment) == wire
    end
  end

  test "signs exact JSON bytes and auth for both map/typed request forms without extra lookups" do
    base = HTTPServer.start(fn _ -> {201, [], Jason.encode!(@payment)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "payment-create-1"})
    original = client
    debit = Map.put(@debit, "custom", %{"memo" => "café", "values" => [true, nil]})

    for payload <- [
          @payload,
          Map.put(@direct, "debitAmount", debit)
        ],
        {supplied, typed?, suffix} <- [
          {"test-resource-token", false, "/tenant%2falpha"},
          {token(), true, "/tenant%2falpha/"}
        ] do
      request = if typed?, do: typed_payload(payload), else: payload

      assert {:ok, payment} =
               OutgoingPayment.create(client, base <> suffix, request, access_token: supplied)

      assert PaymentData.to_map(payment) == @payment
      assert_receive {:http_request, wire}
      assert wire.method == "POST" and wire.target == "/tenant%2falpha/outgoing-payments"
      assert Jason.decode!(wire.body) == payload
      headers = Map.new(wire.headers)
      assert headers["authorization"] == "GNAP test-resource-token"
      assert headers["content-type"] == "application/json"
      assert headers["content-length"] == Integer.to_string(byte_size(wire.body))
      assert headers["accept"] == "application/json" and headers["accept-encoding"] == "identity"
      assert headers["x-request-id"] == "payment-create-1"
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

      refute_receive {:http_request, _}, 20
    end

    assert client == original
  end

  test "preserves root and tenant paths, trailing separators and HTTPS ports" do
    for {base, expected} <- [
          {"https://RESOURCE.example.com", "https://resource.example.com/outgoing-payments"},
          {"https://resource.example.com/", "https://resource.example.com/outgoing-payments"},
          {"https://resource.example.com:8443/tenant/",
           "https://resource.example.com:8443/tenant/outgoing-payments"},
          {"https://resource.example.com/tenant//",
           "https://resource.example.com/tenant//outgoing-payments"}
        ] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert URI.to_string(request.url) == expected
        {request, Req.Response.new(status: 201, body: Jason.encode!(@payment))}
      end)

      assert {:ok, _} =
               OutgoingPayment.create(client(adapter: TransportAdapter), base, @payload,
                 access_token: "test-token"
               )
    end
  end

  test "rejects invalid bases and any query marker before appending the collection" do
    no_request()

    for url <- [
          nil,
          [],
          "",
          "/outgoing-payments",
          "$wallet.example.com/alice",
          "urn:example:server",
          "http://localhost:3000",
          "ftp://resource.example.com",
          "https://user@resource.example.com",
          @url <> "#fragment",
          @url <> "?",
          @url <> "?part=1",
          "https://resource.example.com:65536"
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :create_outgoing_payment,
                validation_errors: [%{field: :url}]
              }} =
               OutgoingPayment.create(client(adapter: TransportAdapter), url, @payload,
                 access_token: "test-token"
               )
    end
  end

  test "requires an authenticated client and unique supported per-call token options" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for invalid <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :create_outgoing_payment}} =
               OutgoingPayment.create(invalid, @url, @payload, access_token: "test-token")
    end

    {:ok, continuation} = ContinuationToken.from_map(%{"value" => "private-token"})

    for opts <- [
          nil,
          %{},
          [],
          [access_token: nil],
          [access_token: continuation],
          [access_token: %{"value" => "private-token"}],
          [access_token: "test", access_token: "other"],
          [access_token: "test", key: "private-key"],
          [access_token: "test", headers: %{}],
          [access_token: "test", json: %{}]
        ] do
      assert {:error, %Error{kind: :validation, operation: :create_outgoing_payment} = error} =
               OutgoingPayment.create(client, @url, @payload, opts)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "revalidates typed tokens and token68 without exposing rejected values" do
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
                operation: :create_outgoing_payment,
                validation_errors: [%{field: ^field}]
              } = error} =
               OutgoingPayment.create(client(adapter: TransportAdapter), @url, @payload,
                 access_token: supplied
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "validates map payloads and modified typed children before HTTP" do
    no_request()
    typed = typed_payload(@direct)

    for {payload, field} <- [
          {nil, :create_outgoing_payment},
          {%{}, :create_outgoing_payment},
          {Map.delete(@payload, "walletAddress"), :wallet_address},
          {Map.put(@payload, "metadata", "private-memo"), :metadata},
          {Map.put(@payload, "receiveAmount", nil), :create_outgoing_payment},
          {Map.put(@direct, "quoteId", nil), :create_outgoing_payment},
          {Map.put(@direct, "debitAmount", nil), :debit_amount},
          {%{typed | incoming_payment: "private-relative"}, :incoming_payment},
          {%{typed | quote_id: @payload["quoteId"]}, :create_outgoing_payment},
          {%{typed | debit_amount: nil}, :create_outgoing_payment},
          {%{typed | debit_amount: @debit}, :debit_amount},
          {%{typed | debit_amount: %{typed.debit_amount | value: "private-amount"}},
           "debit_amount.value"}
        ] do
      assert {:error, %Error{kind: :validation, operation: :create_outgoing_payment} = error} =
               OutgoingPayment.create(client(adapter: TransportAdapter), @url, payload,
                 access_token: "test-token"
               )

      assert Enum.any?(error.validation_errors, &(&1.field == field))
      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "leaves wallet compatibility and payment validity to the server and retains its 400 response" do
    Process.put({TransportAdapter, :callback}, fn request ->
      assert Jason.decode!(request.body) == @payload
      send(self(), :attempt)

      {request,
       Req.Response.new(
         status: 400,
         body: ~s({"error":{"code":"invalid_request","description":"Quote cannot be used"}})
       )}
    end)

    assert {:error,
            %Error{
              kind: :http,
              status: 400,
              code: "invalid_request",
              operation: :create_outgoing_payment
            }} =
             OutgoingPayment.create(client(adapter: TransportAdapter), @url, @payload,
               access_token: "test-token"
             )

    assert_received :attempt
    refute_received :attempt
  end

  test "requires 201 and a typed response with safe JSON/status/encoding/schema errors" do
    for {status, body, headers, code} <- [
          {200, Jason.encode!(@payment), [], "unexpected_status"},
          {204, "", [], "unexpected_status"},
          {201, "private-invalid-json", [], "invalid_json"},
          {201, "null", [], "invalid_response"},
          {201, Jason.encode!(Map.delete(@payment, "receiveAmount")), [], "invalid_response"},
          {201, Jason.encode!(Map.put(@payment, "grantSpentDebitAmount", nil)), [],
           "invalid_response"},
          {201, Jason.encode!(@payment), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"}
        ] do
      respond(status, body, headers)

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: ^code,
                operation: :create_outgoing_payment
              } =
                error} =
               OutgoingPayment.create(client(adapter: TransportAdapter), @url, @payload,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    respond(
      201,
      Jason.encode!(%{@payment | "receiveAmount" => %{@receive | "value" => "private-amount"}})
    )

    assert {:error,
            %Error{
              kind: :decoding,
              status: 201,
              code: "invalid_response",
              validation_errors: [%{field: "receive_amount.value"}]
            } = error} =
             OutgoingPayment.create(client(adapter: TransportAdapter), @url, @payload,
               access_token: "test-token"
             )

    refute inspect(Map.from_struct(error)) =~ "private-amount"
  end

  test "preserves payment progress, unrelated identities and grant amounts without extra creation postconditions" do
    base =
      Map.merge(@payment, %{
        "walletAddress" => "https://other.example.com/private-wallet",
        "quoteId" => "urn:example:private-reference",
        "metadata" => %{},
        "grantSpentDebitAmount" => %{
          @debit
          | "value" => "18446744073709551615",
            "assetCode" => "JPY"
        },
        "grantSpentReceiveAmount" => %{@receive | "value" => "1", "assetScale" => 0},
        "private-extension" => [true, nil],
        "updatedAt" => "uninterpreted"
      })

    for wire <- [
          base,
          %{base | "sentAmount" => %{@debit | "value" => "1205"}, "failed" => true},
          %{base | "sentAmount" => @debit},
          Map.delete(%{base | "sentAmount" => @debit}, "failed"),
          %{base | "debitAmount" => %{@debit | "value" => "0000"}},
          %{
            base
            | "debitAmount" => %{@debit | "value" => "0005"},
              "sentAmount" => %{@debit | "value" => "5"},
              "failed" => true
          }
        ],
        payload <- [@payload, @direct] do
      respond(201, Jason.encode!(wire), [{"content-type", "text/plain"}])

      assert {:ok, payment} =
               OutgoingPayment.create(client(adapter: TransportAdapter), @url, payload,
                 access_token: %{token() | expires_in: -1}
               )

      assert PaymentData.to_map(payment) == wire
      refute inspect(payment) =~ "private-"
    end
  end

  test "applies the same ordered Node debit/sent checks to creation responses with spent amounts" do
    for {wire, field, message} <- [
          {%{@payment | "sentAmount" => %{@debit | "assetCode" => "GBP"}}, :sent_amount,
           "must use the same asset code and scale as debit_amount"},
          {%{@payment | "sentAmount" => %{@debit | "assetScale" => 3}}, :sent_amount,
           "must use the same asset code and scale as debit_amount"},
          {%{
             @payment
             | "debitAmount" => %{@debit | "value" => "9007199254740992"},
               "sentAmount" => %{@debit | "value" => "9007199254740993"}
           }, :sent_amount, "must not exceed debit_amount"},
          {%{@payment | "sentAmount" => %{@debit | "value" => "18446744073709551615"}},
           :sent_amount, "must not exceed debit_amount"},
          {%{@payment | "sentAmount" => @debit, "failed" => true}, :failed,
           "must not be true when debit and sent value strings match"}
        ] do
      assert {:ok, _payment} = PaymentData.from_map(wire)
      respond(201, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                code: "invalid_response",
                status: 201,
                operation: :create_outgoing_payment,
                validation_errors: [%{field: ^field, message: ^message}]
              } = error} =
               OutgoingPayment.create(client(adapter: TransportAdapter), @url, @payload,
                 access_token: "test-token"
               )

      assert error.description == "Invalid Open Payments outgoing-payment response"
      refute inspect(Map.from_struct(error)) =~ "GBP"
    end
  end

  test "supports optional spent variants and reports safe nested spent paths at status201" do
    for wire <- [
          Map.delete(@payment, "grantSpentDebitAmount"),
          @payment,
          @payment
          |> Map.delete("grantSpentDebitAmount")
          |> Map.put("grantSpentReceiveAmount", @receive),
          Map.put(@payment, "grantSpentReceiveAmount", @receive)
        ] do
      respond(201, Jason.encode!(wire))

      assert {:ok, payment} =
               OutgoingPayment.create(client(adapter: TransportAdapter), @url, @payload,
                 access_token: "test-token"
               )

      assert PaymentData.to_map(payment) == wire
    end

    for {name, parent} <- [
          {"grantSpentDebitAmount", "grant_spent_debit_amount"},
          {"grantSpentReceiveAmount", "grant_spent_receive_amount"}
        ] do
      wire = Map.put(@payment, name, %{@debit | "value" => "private-amount"})
      respond(201, Jason.encode!(wire))
      field = parent <> ".value"

      assert {:error,
              %Error{
                kind: :decoding,
                code: "invalid_response",
                status: 201,
                operation: :create_outgoing_payment,
                validation_errors: [%{field: ^field}]
              } = error} =
               OutgoingPayment.create(client(adapter: TransportAdapter), @url, @payload,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "private-amount"
    end
  end

  test "preserves HTTP errors without raw bodies or credential refresh" do
    for status <- [401, 403, 409, 422] do
      respond(status, ~s({"error":{"code":"denied","description":"Not permitted"}}))

      assert {:error,
              %Error{
                kind: :http,
                status: ^status,
                code: "denied",
                operation: :create_outgoing_payment
              }} =
               OutgoingPayment.create(client(adapter: TransportAdapter), @url, @payload,
                 access_token: "test-token"
               )
    end

    respond(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             OutgoingPayment.create(client(adapter: TransportAdapter), @url, @payload,
               access_token: "test-token"
             )

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not follow redirects or replay creation on server errors or dropped connections" do
    base =
      HTTPServer.start(fn request ->
        case request.target do
          "/redirect/outgoing-payments" -> {307, [{"location", "/other"}], ""}
          "/unavailable/outgoing-payments" -> {503, [], "failed"}
          "/dropped/outgoing-payments" -> :close
        end
      end)

    for {prefix, kind, status} <- [
          {"/redirect", :http, 307},
          {"/unavailable", :http, 503},
          {"/dropped", :transport, nil}
        ] do
      assert {:error, %Error{kind: ^kind, status: ^status, operation: :create_outgoing_payment}} =
               OutgoingPayment.create(client(allow_http: true), base <> prefix, @payload,
                 access_token: "test-token"
               )

      target = prefix <> "/outgoing-payments"
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
            %Error{kind: :transport, code: "timeout", operation: :create_outgoing_payment}} =
             OutgoingPayment.create(client(adapter: TransportAdapter), @url, @payload,
               access_token: "test-token"
             )

    assert_received :attempt
    refute_received :attempt
  end

  test "isolates per-call tokens and JSON payloads during concurrent creations" do
    base =
      HTTPServer.start(fn request ->
        wallet = Jason.decode!(request.body)["walletAddress"]
        {201, [], Jason.encode!(%{@payment | "walletAddress" => wallet})}
      end)

    client = client(allow_http: true)

    tasks =
      for value <- ["token-a", "token-b"] do
        payload = %{@payload | "walletAddress" => "https://wallet.example.com/" <> value}

        {value,
         Task.async(fn -> OutgoingPayment.create(client, base, payload, access_token: value) end)}
      end

    for {value, task} <- tasks do
      assert {:ok, payment} = Task.await(task)
      assert payment.wallet_address == "https://wallet.example.com/" <> value
    end

    for _ <- 1..2 do
      assert_receive {:http_request, wire}
      value = String.replace_prefix(Map.new(wire.headers)["authorization"], "GNAP ", "")
      assert Jason.decode!(wire.body)["walletAddress"] == "https://wallet.example.com/" <> value
      assert verify_wire(wire)
    end
  end

  test "creates then reads the returned resource through public APIs without implicit extra calls" do
    base =
      HTTPServer.start(fn request ->
        case {request.method, request.target} do
          {"POST", "/outgoing-payments"} ->
            id = "http://" <> Map.new(request.headers)["host"] <> "/outgoing-payments/created-1"
            wire = %{@payment | "id" => id}
            Process.put(:created_payment, wire)
            {201, [], Jason.encode!(wire)}

          {"GET", "/outgoing-payments/created-1"} ->
            wire = Map.drop(Process.get(:created_payment), ["grantSpentDebitAmount"])
            {200, [], Jason.encode!(wire)}
        end
      end)

    client = client(allow_http: true)
    assert {:ok, created} = OutgoingPayment.create(client, base, @payload, access_token: token())
    assert_receive {:http_request, %{method: "POST", target: "/outgoing-payments"} = wire}
    assert verify_wire(wire)
    refute_receive {:http_request, _}, 30
    assert {:ok, fetched} = OutgoingPayment.get(client, created.id, access_token: token())

    assert PaymentDetails.to_map(fetched) ==
             Map.delete(PaymentData.to_map(created), "grantSpentDebitAmount")

    assert_receive {:http_request,
                    %{method: "GET", target: "/outgoing-payments/created-1", body: ""}}

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

  defp typed_payload(data) do
    {:ok, request} = CreateOutgoingPayment.from_map(data)
    request
  end

  defp no_request,
    do: Process.put({TransportAdapter, :callback}, fn _ -> flunk("unexpected HTTP request") end)

  defp respond(status, body, headers \\ []) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body, headers: headers)}
    end)
  end

  # Verify digest and signature independently from actual POST bytes.
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
