defmodule OpenPayments.RequestTest do
  use ExUnit.Case, async: true

  alias MessageSignatures.Message
  alias OpenPayments.{Error, Key, Request}
  alias OpenPayments.Test.TrackedPayload
  alias OpenPayments.Types.Amount

  @keys File.read!(Path.expand("../fixtures/keys/node-pem.json", __DIR__)) |> Jason.decode!()
  @signatures File.read!(Path.expand("../fixtures/signatures/node-signatures.json", __DIR__))
              |> Jason.decode!()
  @created 1_618_884_473
  @url "https://wallet.example.com/tenant"

  test "prepares unsigned public reads without content or authorization headers" do
    assert {:ok, request} = Request.prepare(:get, @url)
    assert request.method == :get
    assert request.url == @url
    assert request.headers == %{"accept" => "application/json"}
    assert request.body == nil
  end

  test "normalizes HTTP method strings without creating atoms" do
    for {input, expected} <- [
          {"GET", :get},
          {"POST", :post},
          {"DELETE", :delete},
          {:get, :get},
          {:post, :post},
          {:delete, :delete}
        ] do
      assert {:ok, %{method: ^expected}} = Request.prepare(input, @url)
    end

    for input <- ["get", "GET\r\n", "PATCH", :patch, nil, 123, <<255>>] do
      assert {:error, %Error{validation_errors: [%{field: :method}]}} =
               Request.prepare(input, @url)
    end
  end

  test "preserves tenant paths, query ordering, percent escapes and non-default ports" do
    for url <- [
          @url <> "/incoming-payments/a%2Fb?cursor=x%2By%3D&first=0&first=1",
          "https://wallet.example.com:8443/tenant/continue/opaque",
          "https://[2001:db8::1]:8443/tenant/quotes/one",
          @url <> "/a/../b?x=%7e"
        ] do
      assert {:ok, %{url: ^url}} = Request.prepare(:get, url)
    end

    assert {:ok, %{url: "https://wallet.example.com/"}} =
             Request.prepare(:get, "HTTPS://Wallet.Example.COM:443")

    assert {:ok, %{url: "https://wallet.example.com/"}} =
             Request.prepare(:get, "https://wallet.example.com?")
  end

  test "requires explicit HTTP opt-in without rewriting supplied server URLs" do
    for url <- [
          "http://localhost:3000/tenant",
          "http://localhost:3006/tenant",
          "http://wallet.example.com/tenant"
        ] do
      assert {:error, %Error{validation_errors: [%{field: :url}]}} = Request.prepare(:get, url)
      assert {:ok, %{url: ^url}} = Request.prepare(:get, url, allow_http: true)
    end

    assert {:ok, %{url: @url}} = Request.prepare(:get, @url, allow_http: true)
  end

  test "rejects non-HTTP, relative, malformed, credential-bearing and fragment URLs" do
    for url <- [
          nil,
          1,
          "",
          "$wallet.example.com/alice",
          "/tenant",
          "//wallet.example.com/tenant",
          "urn:example:tenant",
          "ftp://wallet.example.com/tenant",
          "https://",
          "https://alice:secret@wallet.example.com/tenant",
          "https://@wallet.example.com/tenant",
          @url <> "#",
          @url <> "#fragment",
          @url <> "/%ZZ",
          @url <> "/α",
          @url <> "/\n",
          "https://wallet.example.com:65536/tenant",
          "https://wallet.example.com:bad/tenant"
        ] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: :url}]}} =
               Request.prepare(:get, url)
    end
  end

  test "encodes typed JSON once before digesting and signing the same bytes" do
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")
    payload = %TrackedPayload{recipient: self(), value: "Café 🌍"}

    assert {:ok, request} =
             Request.prepare(:post, @url,
               json: payload,
               key: key,
               access_token: "public-test-token",
               created: @created
             )

    assert_received :payload_encoded
    refute_received :payload_encoded
    assert request.body == ~s({"message":"Café 🌍"})
    assert request.headers["content-length"] == "24"
    assert request.headers["authorization"] == "GNAP public-test-token"
    assert {:ok, _} = verify(request)

    {:ok, amount} = Amount.new("18446744073709551615", "USD", 2)

    assert {:ok, request} =
             Request.prepare(:post, @url, json: amount, key: key, created: @created)

    assert Jason.decode!(request.body)["value"] == "18446744073709551615"
  end

  test "distinguishes omitted body, explicit empty bytes and JSON null or false" do
    assert {:ok, absent} = Request.prepare(:post, @url)
    assert absent.body == nil
    refute Map.has_key?(absent.headers, "content-length")

    for {options, expected} <- [
          {[body: ""], ""},
          {[json: nil], "null"},
          {[json: false], "false"},
          {[json: 0], "0"}
        ] do
      assert {:ok, request} = Request.prepare(:post, @url, options)
      assert request.body == expected
      assert request.headers["content-length"] == Integer.to_string(byte_size(expected))
    end
  end

  test "retains exact pre-encoded body bytes and matches all Node signature fixtures" do
    for fixture <- @signatures["cases"] do
      {:ok, key} = Key.from_pem(@keys["ed25519"], fixture["key_id"])

      token =
        case fixture["headers"]["authorization"] do
          nil -> nil
          "GNAP " <> value -> value
        end

      body =
        if is_nil(fixture["body_base64"]), do: nil, else: Base.decode64!(fixture["body_base64"])

      opts = [
        key: key,
        access_token: token,
        body: body,
        created: fixture["created"],
        allow_http: String.starts_with?(fixture["url"], "http:")
      ]

      assert {:ok, request} = Request.prepare(fixture["method"], fixture["url"], opts)
      assert request.body == body
      assert request.url == fixture["url"]

      assert Map.take(request.headers, ~w(signature signature-input)) ==
               fixture["signature_headers"]
    end
  end

  test "uses SDK-owned headers and rejects case-insensitive duplicate or malformed custom fields" do
    for name <-
          ~w(authorization content-digest content-length content-type signature signature-input host connection transfer-encoding content-encoding trailer upgrade te proxy-authorization) do
      assert {:error, %Error{validation_errors: [%{field: :headers}]}} =
               Request.prepare(:get, @url, headers: %{String.upcase(name) => "value"})
    end

    for headers <- [
          nil,
          [],
          %URI{},
          %{accept: "application/json"},
          %{"X-Flag" => "one", "x-flag" => "two"},
          %{"bad name" => "value"},
          %{"" => "value"},
          %{"x-test" => "bad\r\nvalue"},
          %{"x-test" => "bad\0value"},
          %{"x-test" => "α"},
          %{"x-test" => 123},
          %{<<255>> => "value"}
        ] do
      assert {:error, %Error{validation_errors: [%{field: :headers}]}} =
               Request.prepare(:get, @url, headers: headers)
    end

    assert {:ok, request} =
             Request.prepare(:get, @url,
               headers: %{
                 "X-Request-ID" => "one",
                 "Accept" => "application/json",
                 "X-Empty" => ""
               }
             )

    assert request.headers == %{
             "accept" => "application/json",
             "x-request-id" => "one",
             "x-empty" => ""
           }
  end

  test "validates token68 values and requires a key for key-bound GNAP authorization" do
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")

    for token <- ["abc", "A.Z_0~+/-=="] do
      assert {:ok, request} = Request.prepare(:get, @url, key: key, access_token: token)
      assert request.headers["authorization"] == "GNAP " <> token
    end

    for token <- ["", "=", "abc=def", "a b", "GNAP token", "a\r\nsecret", "α", 1, false] do
      assert {:error, %Error{validation_errors: [%{field: :access_token}]}} =
               Request.prepare(:get, @url, key: key, access_token: token)
    end

    assert {:error, %Error{validation_errors: [%{field: :key}]}} =
             Request.prepare(:get, @url, access_token: "public-test-token")
  end

  test "rejects ambiguous or unknown options and invalid signing configuration" do
    for opts <- [%{}, nil, [:option], [unknown: true], [headers: %{}, headers: %{}]] do
      assert {:error, %Error{validation_errors: [%{field: :options}]}} =
               Request.prepare(:get, @url, opts)
    end

    for {opts, field} <- [
          {[key: "key"], :key},
          {[allow_http: "true"], :allow_http},
          {[created: -1], :created},
          {[created: nil], :created},
          {[json: nil, body: nil], :body},
          {[body: %{}], :body}
        ] do
      assert {:error, %Error{validation_errors: [%{field: ^field}]}} =
               Request.prepare(:post, @url, opts)
    end
  end

  test "JSON encoder failures return safe errors without retaining rejected data" do
    for payload <- [self(), <<255>>, %TrackedPayload{recipient: self(), value: :raise}] do
      assert {:error, %Error{validation_errors: [%{field: :body}]} = error} =
               Request.prepare(:post, @url, json: payload)

      assert error.details == nil
      refute inspect(Map.from_struct(error)) =~ "private-payload-must-not-leak"
    end
  end

  test "prepared request inspection and errors omit URLs, tokens, bodies and keys" do
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-1")

    assert {:ok, request} =
             Request.prepare(:post, @url <> "?private-query-must-not-leak",
               key: key,
               access_token: "private-token-must-not-leak",
               body: "private-body-must-not-leak"
             )

    assert inspect(request) =~ ":post"
    refute inspect(request) =~ "must-not-leak"

    assert {:error, error} = Request.prepare(:get, "https://private-secret@wallet.example.com")
    refute inspect(Map.from_struct(error)) =~ "private-secret"

    assert {:error, error} =
             Request.prepare(:get, @url, key: key, access_token: "private-token\r\n")

    refute inspect(Map.from_struct(error)) =~ "private-token"
  end

  test "reports signing failure without returning an unsigned request" do
    {:ok, key} = Key.from_pem(@keys["ed25519"], "key-α")
    assert {:error, %Error{kind: :signing}} = Request.prepare(:post, @url, key: key, json: %{})
  end

  defp verify(request) do
    public = Base.url_decode64!(@keys["public_jwk"]["x"], padding: false)

    message =
      Message.from_request(
        method: request.method,
        url: request.url,
        headers: Map.to_list(request.headers)
      )

    MessageSignatures.verify(message,
      key_resolver: fn _, _ -> {:ok, {:ed25519, public}} end,
      now: @created,
      policy: [
        required_components:
          ~w(@method @target-uri authorization content-digest content-length content-type)
      ]
    )
  end
end
