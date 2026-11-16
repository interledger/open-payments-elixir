defmodule OpenPayments.PaymentPointerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias OpenPayments.Error
  alias OpenPayments.PaymentPointer

  doctest PaymentPointer

  test "resolves the published specification examples" do
    for {pointer, url} <- [
          {"$example.com", "https://example.com/.well-known/pay"},
          {"$example.com/invoices/12345", "https://example.com/invoices/12345"},
          {"$bob.example.com", "https://bob.example.com/.well-known/pay"},
          {"$example.com/bob", "https://example.com/bob"}
        ] do
      assert {:ok, ^url} = PaymentPointer.to_url(pointer)
    end
  end

  test "uses the well-known path for both omitted and root paths" do
    for pointer <- ["$wallet.example.com", "$wallet.example.com/"] do
      assert {:ok, "https://wallet.example.com/.well-known/pay"} = PaymentPointer.to_url(pointer)
    end
  end

  test "preserves non-root paths, percent escapes, casing, and trailing slashes" do
    for path <- [
          "/alice",
          "/alice/",
          "/Alice%20Account",
          "/%2F",
          "//",
          "/a/../b",
          "/.well-known/pay"
        ] do
      assert {:ok, url} = PaymentPointer.to_url("$Wallet.Example.COM" <> path)
      assert url == "https://Wallet.Example.COM" <> path
    end
  end

  test "supports IPv4 and bracketed IPv6 hosts without adding a port" do
    for {pointer, url} <- [
          {"$192.0.2.1/alice", "https://192.0.2.1/alice"},
          {"$[2001:db8::1]", "https://[2001:db8::1]/.well-known/pay"},
          {"$[2001:db8::1]/", "https://[2001:db8::1]/.well-known/pay"},
          {"$[2001:db8::1]/alice", "https://[2001:db8::1]/alice"}
        ] do
      assert {:ok, ^url} = PaymentPointer.to_url(pointer)
    end
  end

  test "rejects user-info and all explicit ports, including the HTTPS default" do
    for pointer <- [
          "$alice@wallet.example.com",
          "$alice:example-password@wallet.example.com/alice",
          "$@wallet.example.com",
          "$wallet.example.com:443/alice",
          "$wallet.example.com:8443",
          "$wallet.example.com:",
          "$localhost:3000/alice",
          "$[2001:db8::1]:443/alice"
        ] do
      assert_invalid(pointer)
    end
  end

  test "rejects queries and fragments even if empty" do
    for suffix <- ["?", "?invoice=123", "#", "#details", "?x=1#details"],
        path <- ["", "/", "/alice"] do
      assert_invalid("$wallet.example.com" <> path <> suffix)
    end
  end

  test "rejects malformed hosts, percent escapes, whitespace and non-ASCII input" do
    for pointer <- [
          "$",
          "$/",
          "$//wallet.example.com/alice",
          "$https://wallet.example.com/alice",
          "$[broken/alice",
          "$wallet.example.com/%",
          "$wallet.example.com/%0",
          "$wallet.example.com/%ZZ",
          " $wallet.example.com",
          "$wallet.example.com/alice ",
          "$wallet.example.com/\n",
          "$wallet.example.com/α",
          "$wallet.example.com/" <> <<255>>,
          "$wallet.example.com\\alice"
        ] do
      assert_invalid(pointer)
    end
  end

  test "requires dollar-prefixed shorthand and rejects non-string values" do
    for pointer <- [
          "",
          "wallet.example.com/alice",
          "https://wallet.example.com/alice",
          "http://localhost:3000/alice",
          nil,
          123,
          false,
          ["$wallet.example.com"],
          %URI{scheme: "https", host: "wallet.example.com"}
        ] do
      assert_invalid(pointer)
    end
  end

  test "validation errors do not retain rejected input" do
    assert {:error, error} = PaymentPointer.to_url("$alice:example-password@wallet.example.com")
    refute inspect(error) =~ "example-password"
    refute Exception.message(error) =~ "example-password"
    assert error.details == nil
  end

  property "non-root conversion preserves the authority and path and always selects HTTPS" do
    check all(
            label <- string(:alphanumeric, min_length: 1, max_length: 20),
            segment <- string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      host = label <> ".example"
      path = "/" <> segment
      assert {:ok, url} = PaymentPointer.to_url("$" <> host <> path)
      assert url == "https://" <> host <> path

      parts = :uri_string.parse(url)
      assert parts.scheme == "https"
      assert parts.host == host
      assert parts.path == path
      assert Map.keys(parts) |> Enum.sort() == [:host, :path, :scheme]
    end
  end

  defp assert_invalid(pointer) do
    assert {:error,
            %Error{
              kind: :validation,
              validation_errors: [%{field: :payment_pointer}]
            }} = PaymentPointer.to_url(pointer)
  end
end
