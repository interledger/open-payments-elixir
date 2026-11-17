defmodule OpenPayments.Response.JSONTest do
  use ExUnit.Case, async: true

  alias OpenPayments.{Error, Response}
  alias OpenPayments.Response.JSON

  @operation :get_wallet_address

  test "decodes JSON without relying on media-type headers or creating atoms" do
    assert {:ok, %{"custom-new-key" => [true, nil, 1]}} =
             JSON.decode(response(200, ~s({"custom-new-key":[true,null,1]})), [200], @operation)
  end

  test "classifies malformed JSON, empty bodies and unsupported success statuses" do
    for body <- ["", "<html>private-body</html>", <<255>>, "{broken"] do
      assert {:error, %Error{kind: :decoding, status: 200, code: "invalid_json"} = error} =
               JSON.decode(response(200, body), [200], @operation)

      assert error.operation == @operation
      refute inspect(Map.from_struct(error)) =~ "private-body"
    end

    assert {:error, %Error{kind: :decoding, status: 204, code: "unexpected_status"}} =
             JSON.decode(response(204, ""), [200], @operation)
  end

  test "rejects unnegotiated content codings before interpreting the body" do
    resp = %{response(200, "{}") | headers: [{"content-encoding", "gzip"}]}

    assert {:error, %Error{code: "unsupported_content_encoding"}} =
             JSON.decode(resp, [200], @operation)

    assert {:ok, %{}} =
             JSON.decode(%{resp | headers: [{"content-encoding", "Identity"}]}, [200], @operation)
  end

  test "extracts typed Open Payments nested errors and details" do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "invalid_request",
          "description" => "Rejected",
          "details" => %{"field" => "assetCode"}
        },
        "unrelated" => "private-extra"
      })

    assert {:error,
            %Error{
              kind: :http,
              status: 400,
              code: "invalid_request",
              description: "Rejected",
              details: %{"field" => "assetCode"}
            } = error} =
             JSON.decode(response(400, body), [200], @operation)

    assert error.operation == @operation
    refute inspect(error) =~ "Rejected"
    refute inspect(Map.from_struct(error)) =~ "private-extra"
  end

  test "recognizes flat GNAP errors and ignores incorrectly typed fields" do
    assert {:error, %Error{code: "request_denied", description: "Denied"}} =
             JSON.decode(
               response(403, ~s({"error":"request_denied","error_description":"Denied"})),
               [200],
               @operation
             )

    assert {:error,
            %Error{code: nil, description: "Open Payments HTTP request failed", details: nil}} =
             JSON.decode(
               response(400, ~s({"error":{"code":1,"description":false,"details":[]}})),
               [200],
               @operation
             )
  end

  test "retains HTTP status for redirects, empty and non-JSON error bodies without copying them" do
    for {status, body} <- [
          {302, "private-redirect"},
          {404, ""},
          {502, "private-html-body"},
          {500, ~s({"private":"extra-body"})},
          {503, "null"}
        ] do
      assert {:error, %Error{kind: :http, status: ^status, details: nil} = error} =
               JSON.decode(response(status, body), [200], @operation)

      refute inspect(Map.from_struct(error)) =~ "private-"
    end
  end

  defp response(status, body),
    do: %Response{status: status, body: body, headers: [], trailers: []}
end
