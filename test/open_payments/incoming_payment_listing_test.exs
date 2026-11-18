defmodule OpenPayments.IncomingPaymentListingTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error, IncomingPayment, Key, Specification}
  alias OpenPayments.Test.{HTTPServer, TransportAdapter}

  alias OpenPayments.Types.{
    AccessToken,
    ContinuationToken,
    IncomingPaymentPaginationResult,
    PageInfo,
    Pagination
  }

  @seed Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @base "https://resource.example.com/tenant"
  @wallet "https://wallet.example.com/alice"
  @amount %{"value" => "250", "assetCode" => "USD", "assetScale" => 2}
  @payment %{
    "id" => "https://resource.example.com/incoming-payments/payment-1",
    "walletAddress" => @wallet,
    "completed" => false,
    "receivedAmount" => @amount,
    "incomingAmount" => @amount,
    "createdAt" => "2026-11-18T09:20:50Z"
  }
  @page %{
    "pagination" => %{"hasNextPage" => false, "hasPreviousPage" => false},
    "result" => [@payment]
  }
  @fixture Path.expand("../fixtures/queries/node-query.json", __DIR__)

  test "matches the pinned list operation and decodes every official forward/backward example" do
    operation = Enum.find(Specification.operations(), &(&1.id == "list-incoming-payments"))
    assert operation.method == :get and operation.server == :resource
    assert operation.success_statuses == [200]
    spec = Specification.document(:resource)["paths"]["/incoming-payments"]["get"]
    assert %{"$ref" => "#/components/parameters/wallet-address"} in spec["parameters"]
    examples = spec["responses"]["200"]["content"]["application/json"]["examples"]
    assert map_size(examples) == 2

    for {_name, %{"value" => wire}} <- examples do
      respond(200, Jason.encode!(wire))

      assert {:ok, %IncomingPaymentPaginationResult{pagination: %PageInfo{}} = page} =
               IncomingPayment.list(client(adapter: TransportAdapter), @base, @wallet,
                 access_token: token()
               )

      assert IncomingPaymentPaginationResult.to_map(page) == wire
    end
  end

  test "matches independent Node form vectors on the signed wire without requiring Node at test time" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["provenance"]["generator"] =~ "URLSearchParams"
    base = HTTPServer.start(fn _ -> {200, [], Jason.encode!(@page)} end)
    client = client(allow_http: true, headers: %{"X-Request-ID" => "list-1"})
    original = client

    for %{"input" => input, "query" => query} <- fixture["vectors"],
        {supplied, pagination, suffix} <- [
          {"test-resource-token", input["pagination"], "/tenant%2falpha"},
          {token(), typed_pagination(input["pagination"]), "/tenant%2falpha/"}
        ] do
      assert {:ok, page} =
               IncomingPayment.list(client, base <> suffix, input["wallet_address"],
                 access_token: supplied,
                 pagination: pagination
               )

      assert IncomingPaymentPaginationResult.to_map(page) == @page
      assert_receive {:http_request, wire}
      assert wire.method == "GET" and wire.body == ""
      assert wire.target == "/tenant%2falpha/incoming-payments?" <> query
      headers = Map.new(wire.headers)
      assert headers["authorization"] == "GNAP test-resource-token"
      assert headers["accept"] == "application/json"
      assert headers["accept-encoding"] == "identity"
      assert headers["x-request-id"] == "list-1"
      refute Map.has_key?(headers, "content-type")
      refute Map.has_key?(headers, "content-digest")
      assert verify_wire(wire)
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

  test "encodes only supplied query arguments and preserves root/tenant bases and HTTPS ports" do
    for {base, collection} <- [
          {"https://RESOURCE.example.com", "https://resource.example.com/incoming-payments"},
          {"https://resource.example.com:8443/tenant/",
           "https://resource.example.com:8443/tenant/incoming-payments"}
        ],
        pagination <- [
          :omitted,
          %Pagination{},
          %{},
          %Pagination{first: 1},
          %{"last" => 100},
          %Pagination{cursor: "cursor-only"}
        ] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert request.url.scheme <> "://" <> request.url.authority <> request.url.path ==
                 collection

        query = URI.decode_query(request.url.query)
        expected = if pagination == :omitted, do: %{}, else: pagination_map(pagination)

        assert query ==
                 Map.new(Map.put(expected, "wallet-address", @wallet), fn {key, value} ->
                   {key, to_string(value)}
                 end)

        {request, Req.Response.new(body: Jason.encode!(@page))}
      end)

      opts = [access_token: "test-token"]
      opts = if pagination == :omitted, do: opts, else: Keyword.put(opts, :pagination, pagination)

      assert {:ok, _} =
               IncomingPayment.list(client(adapter: TransportAdapter), base, @wallet, opts)
    end
  end

  test "requires a string wallet filter without imposing discovery rules or substituting client identity" do
    no_request()

    for invalid <- [nil, false, 1, [], %{}, <<255>>] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :list_incoming_payments,
                validation_errors: [%{field: :wallet_address}]
              }} =
               IncomingPayment.list(client(adapter: TransportAdapter), @base, invalid,
                 access_token: "test-token"
               )
    end

    for wallet <- ["", "$wallet.example.com/alice", "urn:example:wallet", "  wallet value  "] do
      Process.put({TransportAdapter, :callback}, fn request ->
        assert URI.decode_query(request.url.query) == %{"wallet-address" => wallet}
        {request, Req.Response.new(body: Jason.encode!(@page))}
      end)

      assert {:ok, _} =
               IncomingPayment.list(client(adapter: TransportAdapter), @base, wallet,
                 access_token: "test-token"
               )
    end
  end

  test "rejects invalid base URLs and any query marker before appending the collection" do
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
          @base <> "#fragment",
          @base <> "?",
          @base <> "?existing=1",
          "https://resource.example.com:65536"
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :list_incoming_payments,
                validation_errors: [%{field: :url}]
              }} =
               IncomingPayment.list(client(adapter: TransportAdapter), url, @wallet,
                 access_token: "test-token"
               )
    end
  end

  test "requires a valid authenticated client and strictly supported unique list options" do
    no_request()
    client = client(adapter: TransportAdapter)
    {:ok, public} = Client.new_public(adapter: TransportAdapter)

    for invalid <- [nil, public, %{client | key: :invalid}] do
      assert {:error, %Error{kind: :configuration, operation: :list_incoming_payments}} =
               IncomingPayment.list(invalid, @base, @wallet, access_token: "test-token")
    end

    {:ok, continuation} = ContinuationToken.from_map(%{"value" => "private-token"})

    for opts <- [
          nil,
          %{},
          [:bad],
          [],
          [pagination: %{}],
          [access_token: nil],
          [access_token: continuation],
          [access_token: %{"value" => "private-token"}],
          [access_token: "test", access_token: "other"],
          [access_token: "test", pagination: %{}, pagination: %{}],
          [access_token: "test", headers: %{}],
          [access_token: "test", key: "private-key"],
          [access_token: "test", first: 10],
          [access_token: "test", "wallet-address": @wallet],
          [access_token: "test", json: %{}]
        ] do
      assert {:error, %Error{kind: :validation, operation: :list_incoming_payments} = error} =
               IncomingPayment.list(client, @base, @wallet, opts)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "validates map pagination and revalidates typed pagination before sending" do
    no_request()

    for {pagination, field} <- [
          {nil, :pagination},
          {[], :pagination},
          {%{"first" => "25"}, :first},
          {%{"last" => nil}, :last},
          {%{"first" => 10, "last" => 10}, :pagination},
          {%{"cursor" => ""}, :cursor},
          {%{"wallet-address" => "private-wallet"}, :pagination},
          {%Pagination{first: 0}, :first},
          {%Pagination{last: 101}, :last},
          {%Pagination{first: 1, last: 1}, :pagination},
          {%Pagination{cursor: <<255>>}, :cursor}
        ] do
      assert {:error,
              %Error{
                kind: :validation,
                operation: :list_incoming_payments,
                validation_errors: [%{field: ^field}]
              } = error} =
               IncomingPayment.list(client(adapter: TransportAdapter), @base, @wallet,
                 access_token: "test-token",
                 pagination: pagination
               )

      refute inspect(Map.from_struct(error)) =~ "private-wallet"
    end
  end

  test "revalidates typed tokens and token68 without retaining rejected values" do
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
                operation: :list_incoming_payments,
                validation_errors: [%{field: ^field}]
              } = error} =
               IncomingPayment.list(client(adapter: TransportAdapter), @base, @wallet,
                 access_token: supplied
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "checks every payment's asset identity beyond the standalone page codec" do
    for incoming <- [%{@amount | "assetCode" => "EUR"}, %{@amount | "assetScale" => 3}] do
      wire = %{@page | "result" => [@payment, %{@payment | "incomingAmount" => incoming}]}
      assert {:ok, _} = IncomingPaymentPaginationResult.from_map(wire)
      respond(200, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                status: 200,
                code: "invalid_response",
                operation: :list_incoming_payments,
                validation_errors: [%{field: "result[1].incoming_amount"}]
              } = error} =
               IncomingPayment.list(client(adapter: TransportAdapter), @base, @wallet,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "EUR"
    end
  end

  test "preserves empty pages, duplicates and independent server metadata without extra business checks" do
    metadata = %{
      "hasNextPage" => true,
      "hasPreviousPage" => true,
      "startCursor" => "z",
      "endCursor" => "a"
    }

    payment =
      @payment
      |> Map.delete("incomingAmount")
      |> Map.put("walletAddress", "https://another.example.com/wallet")
      |> Map.put("completed", true)
      |> Map.put("expiresAt", "2020-01-01T00:00:00Z")

    for results <- [[], [payment, @payment, payment]] do
      wire = %{
        "pagination" => metadata,
        "result" => results,
        "next" => "https://other.example.com/private-next"
      }

      respond(200, Jason.encode!(wire))

      assert {:ok, page} =
               IncomingPayment.list(client(adapter: TransportAdapter), @base, @wallet,
                 access_token: %{token() | expires_in: -1},
                 pagination: %Pagination{first: 1}
               )

      assert IncomingPaymentPaginationResult.to_map(page) == wire
      refute inspect(page) =~ "private-next"
    end
  end

  test "requires the typed list contract with safe nested schema and closed-item errors" do
    for {wire, field} <- [
          {Map.delete(@page, "pagination"), :pagination},
          {Map.delete(@page, "result"), :result},
          {put_in(@page, ["pagination", "endCursor"], ""), "pagination.end_cursor"},
          {%{
             @page
             | "result" => [
                 %{@payment | "receivedAmount" => %{@amount | "value" => "private-amount"}}
               ]
           }, "result[0].received_amount.value"},
          {%{@page | "result" => [Map.put(@payment, "methods", [])]}, "result[0]"}
        ] do
      respond(200, Jason.encode!(wire))

      assert {:error,
              %Error{
                kind: :decoding,
                status: 200,
                code: "invalid_response",
                operation: :list_incoming_payments,
                validation_errors: [%{field: ^field}]
              } = error} =
               IncomingPayment.list(client(adapter: TransportAdapter), @base, @wallet,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "private-amount"
    end
  end

  test "classifies invalid JSON, success statuses and content encoding errors" do
    for {status, body, headers, code} <- [
          {200, "private-invalid-json", [], "invalid_json"},
          {201, Jason.encode!(@page), [], "unexpected_status"},
          {204, "", [], "unexpected_status"},
          {200, "null", [], "invalid_response"},
          {200, Jason.encode!(@page), [{"content-encoding", "gzip"}],
           "unsupported_content_encoding"}
        ] do
      respond(status, body, headers)

      assert {:error,
              %Error{
                kind: :decoding,
                status: ^status,
                code: ^code,
                operation: :list_incoming_payments
              } = error} =
               IncomingPayment.list(client(adapter: TransportAdapter), @base, @wallet,
                 access_token: "test-token"
               )

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  test "preserves HTTP errors without raw bodies or automatic token refresh" do
    for status <- [401, 403, 404] do
      respond(status, ~s({"error":{"code":"denied","description":"Not permitted"}}))

      assert {:error,
              %Error{
                kind: :http,
                status: ^status,
                code: "denied",
                operation: :list_incoming_payments
              }} =
               IncomingPayment.list(client(adapter: TransportAdapter), @base, @wallet,
                 access_token: "test-token"
               )
    end

    respond(500, "private-raw-body")

    assert {:error, %Error{kind: :http, status: 500, details: nil} = error} =
             IncomingPayment.list(client(adapter: TransportAdapter), @base, @wallet,
               access_token: "test-token"
             )

    refute inspect(Map.from_struct(error)) =~ "private-raw-body"
  end

  test "does not redirect, retry server failures or replay timeout/dropped connections" do
    base =
      HTTPServer.start(fn request ->
        path = URI.parse(request.target).path

        case path do
          "/redirect/incoming-payments" -> {302, [{"location", "/other"}], ""}
          "/unavailable/incoming-payments" -> {503, [], "failed"}
          "/dropped/incoming-payments" -> :close
        end
      end)

    for {prefix, kind, status} <- [
          {"/redirect", :http, 302},
          {"/unavailable", :http, 503},
          {"/dropped", :transport, nil}
        ] do
      assert {:error, %Error{kind: ^kind, status: ^status, operation: :list_incoming_payments}} =
               IncomingPayment.list(client(allow_http: true), base <> prefix, @wallet,
                 access_token: "test-token"
               )

      assert_receive {:http_request, %{method: "GET"}}
      refute_receive {:http_request, _}, 30
    end

    Process.put({TransportAdapter, :callback}, fn request ->
      send(self(), :attempt)
      {request, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, %Error{kind: :transport, code: "timeout", operation: :list_incoming_payments}} =
             IncomingPayment.list(client(adapter: TransportAdapter), @base, @wallet,
               access_token: "test-token"
             )

    assert_received :attempt
    refute_received :attempt
  end

  test "fetches forward/backward pages only on explicit calls with fresh credentials and no cache" do
    base =
      HTTPServer.start(fn request ->
        query = URI.decode_query(URI.parse(request.target).query)

        wire = %{
          @page
          | "pagination" => %{
              "hasNextPage" => true,
              "hasPreviousPage" => true,
              "startCursor" => "previous+/~*",
              "endCursor" => "next+/~*"
            }
        }

        wire =
          Map.put(wire, "echo", %{
            "query" => query,
            "authorization" => Map.new(request.headers)["authorization"]
          })

        {200, [], Jason.encode!(wire)}
      end)

    client = client(allow_http: true)

    assert {:ok, first} =
             IncomingPayment.list(client, base, @wallet,
               access_token: "first-token",
               pagination: %Pagination{first: 2}
             )

    assert first.extensions["echo"]["authorization"] == "GNAP first-token"
    assert_receive {:http_request, _}
    refute_receive {:http_request, _}, 30

    assert {:ok, second} =
             IncomingPayment.list(client, base, @wallet,
               access_token: "second-token",
               pagination: %Pagination{first: 2, cursor: first.pagination.end_cursor}
             )

    assert second.extensions["echo"] == %{
             "query" => %{"wallet-address" => @wallet, "first" => "2", "cursor" => "next+/~*"},
             "authorization" => "GNAP second-token"
           }

    assert_receive {:http_request, _}
    refute_receive {:http_request, _}, 30

    assert {:ok, back} =
             IncomingPayment.list(client, base, @wallet,
               access_token: "third-token",
               pagination: %Pagination{last: 2, cursor: second.pagination.start_cursor}
             )

    assert back.extensions["echo"]["query"] == %{
             "wallet-address" => @wallet,
             "last" => "2",
             "cursor" => "previous+/~*"
           }

    assert_receive {:http_request, wire}
    assert verify_wire(wire)
    refute_receive {:http_request, _}, 30
  end

  test "isolates tokens, wallet filters and pagination for concurrent calls on a shared client" do
    base =
      HTTPServer.start(fn request ->
        wire =
          Map.put(@page, "echo", %{
            "query" => URI.decode_query(URI.parse(request.target).query),
            "auth" => Map.new(request.headers)["authorization"]
          })

        {200, [], Jason.encode!(wire)}
      end)

    client = client(allow_http: true)

    tasks =
      for value <- ["token-a", "token-b"] do
        {value,
         Task.async(fn ->
           IncomingPayment.list(client, base, "https://wallet.example.com/" <> value,
             access_token: value,
             pagination: %Pagination{last: 1, cursor: value <> "+/"}
           )
         end)}
      end

    for {value, task} <- tasks do
      assert {:ok, page} = Task.await(task)

      assert page.extensions["echo"] == %{
               "query" => %{
                 "wallet-address" => "https://wallet.example.com/" <> value,
                 "last" => "1",
                 "cursor" => value <> "+/"
               },
               "auth" => "GNAP " <> value
             }
    end

    for _ <- 1..2 do
      assert_receive {:http_request, wire}
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

  defp typed_pagination(data) do
    {:ok, pagination} = Pagination.from_map(data)
    pagination
  end

  defp pagination_map(%Pagination{} = pagination), do: Pagination.to_map(pagination)
  defp pagination_map(data), do: data

  defp no_request,
    do: Process.put({TransportAdapter, :callback}, fn _ -> flunk("unexpected HTTP request") end)

  defp respond(status, body, headers \\ []) do
    Process.put({TransportAdapter, :callback}, fn request ->
      {request, Req.Response.new(status: status, body: body, headers: headers)}
    end)
  end

  # Verify the exact encoded target and authorization independently from wire bytes.
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
