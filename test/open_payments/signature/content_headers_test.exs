defmodule OpenPayments.Signature.ContentHeadersTest do
  use ExUnit.Case, async: true

  alias OpenPayments.Error
  alias OpenPayments.Signature.ContentHeaders

  @fixtures File.read!(Path.expand("../../fixtures/signatures/content-headers.json", __DIR__))
            |> Jason.decode!()

  test "reproduces the published SHA-512 digest from RFC 9530 Appendix D" do
    # https://www.rfc-editor.org/rfc/rfc9530.html#appendix-D
    digest =
      "WZDPaVn/7XgHaAy8pmojAkGWoRx2UFChF41A2svX+TaPm+" <>
        "AbwAgBWnrIiYllu7BNNyealdVLvRwEmTHWXvJwew=="

    assert {:ok,
            %{
              "content-digest" => "sha-512=:#{digest}:",
              "content-length" => "18",
              "content-type" => "application/json"
            }} == ContentHeaders.build(~s({"hello": "world"}))
  end

  test "matches independent Node crypto digests and Buffer byte lengths" do
    for fixture <- @fixtures["cases"] do
      body = Base.decode64!(fixture["body_base64"])
      assert ContentHeaders.build(body) == {:ok, fixture["headers"]}, fixture["name"]
    end
  end

  test "distinguishes no body from an explicit empty body and JSON null" do
    assert {:ok, absent} = ContentHeaders.build(nil)
    assert map_size(absent) == 0

    assert {:ok, empty} = ContentHeaders.build("")
    assert empty["content-length"] == "0"
    assert empty["content-type"] == "application/json"
    assert String.starts_with?(empty["content-digest"], "sha-512=:")

    assert {:ok, json_null} = ContentHeaders.build("null")
    assert json_null["content-length"] == "4"
    refute json_null["content-digest"] == empty["content-digest"]
  end

  test "hashes the exact JSON bytes including whitespace, property order and line endings" do
    pairs = [
      {~s({"hello":"world"}), ~s({"hello": "world"})},
      {~s({"a":1,"b":2}), ~s({"b":2,"a":1})},
      {"{\n\"a\":1\n}", "{\r\n\"a\":1\r\n}"},
      {~s({"message":"🌍"}), ~S({"message":"\ud83c\udf0d"})}
    ]

    for {first, second} <- pairs do
      assert Jason.decode!(first) == Jason.decode!(second)
      assert {:ok, first_headers} = ContentHeaders.build(first)
      assert {:ok, second_headers} = ContentHeaders.build(second)
      refute first_headers["content-digest"] == second_headers["content-digest"]
    end
  end

  test "counts Unicode bytes rather than characters" do
    body = ~s({"message":"Café 🌍"})
    assert {:ok, headers} = ContentHeaders.build(body)
    assert headers["content-length"] == "24"
    assert String.length(body) < 24
  end

  test "leaves JSON validation to the caller without decoding or rewriting body bytes" do
    for body <- ["not JSON", <<0, 255, 13, 10, 128, 1>>] do
      assert {:ok, headers} = ContentHeaders.build(body)
      assert headers["content-length"] == Integer.to_string(byte_size(body))
    end
  end

  test "rejects unencoded values and iodata without coercion or retaining rejected contents" do
    for body <- [%{}, ["private-body-must-not-leak"], :body, 123, false, <<1::1>>] do
      assert {:error, %Error{kind: :validation, validation_errors: [%{field: :body}]} = error} =
               ContentHeaders.build(body)

      assert error.details == nil
      refute inspect(Map.from_struct(error)) =~ "private-body-must-not-leak"
    end
  end
end
