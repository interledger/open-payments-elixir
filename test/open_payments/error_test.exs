defmodule OpenPayments.ErrorTest do
  use ExUnit.Case, async: true

  alias OpenPayments.Error

  test "reports a description through the exception interface" do
    error = %Error{kind: :validation, description: "Invalid Open Payments amount"}
    assert Exception.message(error) == "Invalid Open Payments amount"
  end

  test "supplies a useful default message" do
    assert Exception.message(%Error{kind: :transport}) == "Open Payments transport error"
  end

  test "inspection does not expose descriptions or arbitrary error details" do
    error = %Error{
      kind: :http,
      status: 403,
      code: "request_denied",
      description: "private-description",
      details: %{"token" => "private-token"}
    }

    rendered = inspect(error)
    assert rendered =~ ":http"
    assert rendered =~ "403"
    refute rendered =~ "private-description"
    refute rendered =~ "private-token"
  end
end
