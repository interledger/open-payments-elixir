defmodule OpenPayments.ClientTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Test.TransportAdapter

  test "constructs a public client without network access" do
    assert {:ok, client} = Client.new_public()
    refute Client.allow_http?(client)
    assert {:ok, local} = Client.new_public(allow_http: true)
    assert Client.allow_http?(local)
  end

  test "validates options, timeouts and adapters during construction" do
    for opts <- [
          nil,
          %{},
          [:bad],
          [allow_http: true, allow_http: false],
          [unknown: true],
          [private_key: "private-key-must-not-leak"]
        ] do
      assert {:error, %Error{kind: :configuration} = error} = Client.new_public(opts)
      refute inspect(Map.from_struct(error)) =~ "private-key-must-not-leak"
    end

    for {opts, field} <- [
          {[allow_http: "true"], :allow_http},
          {[receive_timeout: 0], :receive_timeout},
          {[adapter: "bad"], :adapter},
          {[headers: %{"Authorization" => "secret"}], :headers},
          {[headers: %{"Accept" => "text/html"}], :headers},
          {[headers: %{"Accept-Encoding" => "gzip"}], :headers}
        ] do
      assert {:error, %Error{kind: :configuration, validation_errors: [%{field: ^field}]}} =
               Client.new_public(opts)
    end
  end

  test "propagates fixed headers and timeouts without mutating the client" do
    Process.put({TransportAdapter, :callback}, fn request ->
      assert Req.Request.get_header(request, "accept") == ["application/json"]
      assert Req.Request.get_header(request, "accept-encoding") == ["identity"]
      assert Req.Request.get_header(request, "x-request-id") == ["test-id"]
      assert Req.Request.get_header(request, "authorization") == []
      assert Req.Request.get_header(request, "signature") == []
      assert request.options.receive_timeout == 123
      {request, Req.Response.new(body: "{}")}
    end)

    {:ok, client} =
      Client.new_public(
        adapter: TransportAdapter,
        receive_timeout: 123,
        headers: %{"X-Request-ID" => "test-id"}
      )

    original = client
    assert {:ok, _} = Client.request(client, :get, "https://wallet.example.com/alice")
    assert client == original
  end

  test "client HTTP policy cannot be overridden by internal per-request options" do
    {:ok, client} = Client.new_public(adapter: TransportAdapter)

    assert {:error, %Error{validation_errors: [%{field: :url}]}} =
             Client.request(client, :get, "http://localhost:3000/alice", allow_http: true)
  end

  test "inspection excludes arbitrary custom header data" do
    {:ok, client} =
      Client.new_public(headers: %{"X-Diagnostic" => "private-header-must-not-leak"})

    refute inspect(client) =~ "private-header-must-not-leak"
  end
end
