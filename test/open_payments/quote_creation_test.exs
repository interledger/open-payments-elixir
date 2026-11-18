defmodule OpenPayments.QuoteCreationTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, Key, Quote, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}
  alias OpenPayments.Types.{AccessToken, ContinuationToken, CreateQuote}
  alias OpenPayments.Types.Quote, as: QuoteData

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @url "https://resource.example.com/tenant"
  @payload %{
    "walletAddress" => "https://wallet.example.com/alice",
    "receiver" => "https://receiver.example.com/incoming-payments/payment-1",
    "method" => "ilp"
  }
  @debit %{"value" => "2500", "assetCode" => "USD", "assetScale" => 2}
  @receive %{"value" => "2198", "assetCode" => "EUR", "assetScale" => 2}
  @quote Map.merge(@payload, %{
           "id" => "https://resource.example.com/quotes/quote-1",
           "debitAmount" => @debit,
           "receiveAmount" => @receive,
           "createdAt" => "2026-11-18T09:20:50Z"
         })

  test "matches pinned POST/201 and round trips all official request variants and response examples" do
    operation = Enum.find(Specification.operations(), &(&1.id == "create-quote"))
    assert operation.method == :post and operation.server == :resource
    assert operation.success_statuses == [201]
    spec = Specification.document(:resource)["paths"]["/quotes"]["post"]
    assert spec["requestBody"]["required"]

    assert spec["responses"]["201"]["content"]["application/json"]["schema"] == %{
             "$ref" => "#/components/schemas/quote"
           }

    requests = spec["requestBody"]["content"]["application/json"]["examples"]
    responses = spec["responses"]["201"]["content"]["application/json"]["examples"]
    assert map_size(requests) == 3 and map_size(responses) > 0

    for {_name, %{"value" => payload}} <- requests, {_name, %{"value" => wire}} <- responses do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert Jason.decode!(request.body) == payload
        {request, Req.Response.new(status: 201, body: Jason.encode!(wire))}
      end)

      assert {:ok, quote} =
               Quote.create(client(adapter: TransportAdapter), @url, payload,
                 access_token: token()
               )

      assert QuoteData.to_map(quote) == wire
    end
  end

  test "signs exact JSON bytes and auth for every map/typed amount variant without extra lookups" do
    base = HTTPServer.start(fn _ -> {201, [], Jason.encode!(@quote)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "quote-create-1"})
    original = client
    debit = Map.put(@debit, "custom", %{"memo" => "café", "values" => [true, nil]})

    for payload <- [
          @payload,
          Map.put(@payload, "debitAmount", debit),
          Map.put(@payload, "receiveAmount", @receive)
        ],
        {supplied, typed?, suffix} <- [
          {"test-resource-token", false, "/tenant%2falpha"},
          {token(), true, "/tenant%2falpha/"}
        ] do
      request = if typed?, do: typed_payload(payload), else: payload
      assert {:ok, quote} = Quote.create(client, base <> suffix, request, access_token: supplied)
      assert QuoteData.to_map(quote) == @quote
      assert_receive {:http_request, wire}
      assert wire.method == "POST" and wire.target == "/tenant%2falpha/quotes"
      assert Jason.decode!(wire.body) == payload
      headers = Map.new(wire.headers)
      assert headers["authorization"] == "GNAP test-resource-token"
      assert headers["content-type"] == "application/json"
      assert headers["content-length"] == Integer.to_string(byte_size(wire.body))
      assert headers["accept"] == "application/json" and headers["accept-encoding"] == "identity"
      assert headers["x-request-id"] == "quote-create-1"
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
          {"https://RESOURCE.example.com", "https://resource.example.com/quotes"},
          {"https://resource.example.com/", "https://resource.example.com/quotes"},
          {"https://resource.example.com:8443/tenant/",
           "https://resource.example.com:8443/tenant/quotes"},
          {"https://resource.example.com/tenant//", "https://resource.example.com/tenant//quotes"}
        ] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert URI.to_string(request.url) == expected
        {request, Req.Response.new(status: 201, body: Jason.encode!(@quote))}
      end)

      assert {:ok, _} =
               Quote.create(client(adapter: TransportAdapter), base, @payload,
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
          "/quotes",
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
                operation: :create_quote,
                validation_errors: [%{field: :url}]
              }} =
               Quote.create(client(adapter: TransportAdapter), url, @payload,
                 access_token: "test-token"
               )
    end
  end

  test "requires an authenticated client and unique supported per-call token options" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for invalid <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :create_quote}} =
               Quote.create(invalid, @url, @payload, access_token: "test-token")
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
      assert {:error, %Error{kind: :validation, operation: :create_quote} = error} =
               Quote.create(client, @url, @payload, opts)

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
                operation: :create_quote,
                validation_errors: [%{field: ^field}]
              } = error} =
               Quote.create(client(adapter: TransportAdapter), @url, @payload,
                 access_token: supplied
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "validates map payloads and modified typed children before HTTP" do
    no_request()
    typed = typed_payload(Map.put(@payload, "debitAmount", @debit))

    for {payload, field} <- [
          {nil, :create_quote},
          {%{}, :wallet_address},
          {Map.put(@payload, "metadata", "private-memo"), :create_quote},
          {Map.put(@payload, "receiveAmount", nil), :receive_amount},
          {Map.merge(@payload, %{"debitAmount" => @debit, "receiveAmount" => @receive}),
           :create_quote},
          {%{typed | receiver: "private-relative"}, :receiver},
          {%{typed | receive_amount: typed.debit_amount}, :create_quote},
          {%{typed | debit_amount: @debit}, :debit_amount},
          {%{typed | debit_amount: %{typed.debit_amount | value: "private-amount"}},
           "debit_amount.value"}
        ] do
      assert {:error, %Error{kind: :validation, operation: :create_quote} = error} =
               Quote.create(client(adapter: TransportAdapter), @url, payload,
                 access_token: "test-token"
               )

      assert Enum.any?(error.validation_errors, &(&1.field == field))
      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "leaves receiver amount inference to the server and retains its 400 response" do
    Process.put({TransportAdapter, :callback}, fn request ->
      assert Jason.decode!(request.body) == @payload
      send(self(), :attempt)

      {request,
       Req.Response.new(
         status: 400,
         body: ~s({"error":{"code":"invalid_request","description":"No receiver amount"}})
       )}
    end)

    assert {:error,
            %Error{kind: :http, status: 400, code: "invalid_request", operation: :create_quote}} =
             Quote.create(client(adapter: TransportAdapter), @url, @payload,
               access_token: "test-token"
             )

    assert_received :attempt
    refute_received :attempt
  end

  test "requires 201 and a strict typed response with safe JSON/status/encoding/schema errors" do
    for {status, body, headers, code} <- [
          {200, Jason.encode!(@quote), [], "unexpected_status"},
          {204, "", [], "unexpected_status"},
          {201, "private-invalid-json", [], "invalid_json"},
          {201, "null", [], "invalid_response"},
          {201, Jason.encode!(Map.delete(@quote, "receiveAmount")), [], "invalid_response"},
          {201, Jason.encode!(Map.put(@quote, "sentAmount", @debit)), [], "invalid_response"},
          {201, Jason.encode!(@quote), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"}
        ] do
      respond(status, body, headers)

      assert {:error,
              %Error{kind: :decoding, status: ^status, code: ^code, operation: :create_quote} =
                error} =
               Quote.create(client(adapter: TransportAdapter), @url, @payload,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end

    respond(
      201,
      Jason.encode!(%{@quote | "receiveAmount" => %{@receive | "value" => "private-amount"}})
    )

    assert {:error,
            %Error{
              kind: :decoding,
              status: 201,
              code: "invalid_response",
              validation_errors: [%{field: "receive_amount.value"}]
            } = error} =
             Quote.create(client(adapter: TransportAdapter), @url, @payload,
               access_token: "test-token"
             )

    refute inspect(Map.from_struct(error)) =~ "private-amount"
  end

  test "does not add response/request equality, FX, fee, positivity or local expiry checks" do
    wire =
      Map.merge(@quote, %{
        "walletAddress" => "https://other.example.com/private-wallet",
        "debitAmount" => %{@debit | "value" => "0000"},
        "expiresAt" => "private-expiry"
      })

    respond(201, Jason.encode!(wire))

    assert {:ok, quote} =
             Quote.create(
               client(adapter: TransportAdapter),
               @url,
               Map.put(@payload, "receiveAmount", @receive),
               access_token: %{token() | expires_in: -1}
             )

    assert QuoteData.to_map(quote) == wire
    refute inspect(quote) =~ "private-"
  end

  test "preserves HTTP errors without raw bodies or credential refresh" do
    for status <- [401, 403, 409, 422] do
      respond(status, ~s({"error":{"code":"denied","description":"Not permitted"}}))

      assert {:error,
              %Error{kind: :http, status: ^status, code: "denied", operation: :create_quote}} =
               Quote.create(client(adapter: TransportAdapter), @url, @payload,
                 access_token: "test-token"
               )
    end

    respond(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             Quote.create(client(adapter: TransportAdapter), @url, @payload,
               access_token: "test-token"
             )

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not follow redirects or replay creation on server errors or dropped connections" do
    base =
      HTTPServer.start(fn request ->
        case request.target do
          "/redirect/quotes" -> {307, [{"location", "/other"}], ""}
          "/unavailable/quotes" -> {503, [], "failed"}
          "/dropped/quotes" -> :close
        end
      end)

    for {prefix, kind, status} <- [
          {"/redirect", :http, 307},
          {"/unavailable", :http, 503},
          {"/dropped", :transport, nil}
        ] do
      assert {:error, %Error{kind: ^kind, status: ^status, operation: :create_quote}} =
               Quote.create(client(allow_http: true), base <> prefix, @payload,
                 access_token: "test-token"
               )

      target = prefix <> "/quotes"
      assert_receive {:http_request, %{method: "POST", target: ^target}}
      refute_receive {:http_request, _}, 30
    end
  end

  test "reports timeout once without replaying an ambiguous creation" do
    Process.put({TransportAdapter, :callback}, fn request ->
      send(self(), :attempt)
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, %Error{kind: :transport, code: "timeout", operation: :create_quote}} =
             Quote.create(client(adapter: TransportAdapter), @url, @payload,
               access_token: "test-token"
             )

    assert_received :attempt
    refute_received :attempt
  end

  test "isolates per-call tokens and JSON payloads during concurrent creations" do
    base =
      HTTPServer.start(fn request ->
        wallet = Jason.decode!(request.body)["walletAddress"]
        {201, [], Jason.encode!(%{@quote | "walletAddress" => wallet})}
      end)

    client = client(allow_http: true)

    tasks =
      for value <- ["token-a", "token-b"] do
        payload = %{@payload | "walletAddress" => "https://wallet.example.com/" <> value}
        {value, Task.async(fn -> Quote.create(client, base, payload, access_token: value) end)}
      end

    for {value, task} <- tasks do
      assert {:ok, quote} = Task.await(task)
      assert quote.wallet_address == "https://wallet.example.com/" <> value
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
          {"POST", "/quotes"} ->
            id = "http://" <> Map.new(request.headers)["host"] <> "/quotes/created-1"
            wire = %{@quote | "id" => id}
            Process.put(:created_quote, wire)
            {201, [], Jason.encode!(wire)}

          {"GET", "/quotes/created-1"} ->
            {200, [], Jason.encode!(Process.get(:created_quote))}
        end
      end)

    client = client(allow_http: true)
    assert {:ok, created} = Quote.create(client, base, @payload, access_token: token())
    assert_receive {:http_request, %{method: "POST", target: "/quotes"} = wire}
    assert verify_wire(wire)
    refute_receive {:http_request, _}, 30
    assert {:ok, fetched} = Quote.get(client, created.id, access_token: token())
    assert fetched == created
    assert_receive {:http_request, %{method: "GET", target: "/quotes/created-1", body: ""}}
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
    {:ok, request} = CreateQuote.from_map(data)
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
