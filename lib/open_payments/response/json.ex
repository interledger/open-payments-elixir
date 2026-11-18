defmodule OpenPayments.Response.JSON do
  @moduledoc false

  alias OpenPayments.{Error, Response}

  @spec decode(Response.t(), [integer()], atom()) :: {:ok, term()} | {:error, Error.t()}
  def decode(%Response{} = response, success_statuses, operation) do
    cond do
      response.status in success_statuses -> decode_success(response, operation)
      response.status in 200..299 -> decoding_error(response, operation, "unexpected_status")
      true -> http_error(response, operation)
    end
  end

  # Like Node's DELETE requestor, successful no-content operations use the status
  # without interpreting a response body or content coding.
  @spec expect_no_content(Response.t(), [integer()], atom()) :: :ok | {:error, Error.t()}
  def expect_no_content(%Response{} = response, success_statuses, operation) do
    cond do
      response.status in success_statuses -> :ok
      response.status in 200..299 -> decoding_error(response, operation, "unexpected_status")
      true -> http_error(response, operation)
    end
  end

  defp decode_success(response, operation) do
    encoding = for {"content-encoding", value} <- response.headers, do: String.downcase(value)

    if Enum.all?(encoding, &(&1 == "identity")) do
      case Jason.decode(response.body) do
        {:ok, data} -> {:ok, data}
        {:error, _error} -> decoding_error(response, operation, "invalid_json")
      end
    else
      decoding_error(response, operation, "unsupported_content_encoding")
    end
  end

  defp http_error(response, operation) do
    fields =
      case Jason.decode(response.body) do
        {:ok, %{"error" => error}} when is_map(error) ->
          error

        {:ok, %{"error" => code} = data} when is_binary(code) ->
          %{"code" => code, "description" => data["error_description"]}

        _other ->
          %{}
      end

    {:error,
     %Error{
       kind: :http,
       status: response.status,
       operation: operation,
       code: string(fields["code"]),
       description: string(fields["description"]) || "Open Payments HTTP request failed",
       details: if(is_map(fields["details"]), do: fields["details"], else: nil)
     }}
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp decoding_error(response, operation, code),
    do:
      {:error,
       %Error{
         kind: :decoding,
         status: response.status,
         code: code,
         operation: operation,
         description:
           if(code == "unexpected_status",
             do: "Unexpected Open Payments response status",
             else: "Invalid Open Payments JSON response"
           )
       }}
end
