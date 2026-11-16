defmodule OpenPayments.Request.Headers do
  @moduledoc false

  alias OpenPayments.Error

  @reserved ~w(authorization content-digest content-length content-type signature signature-input host connection transfer-encoding content-encoding trailer upgrade te proxy-authorization)

  @spec normalize(map()) :: {:ok, %{String.t() => String.t()}} | {:error, Error.t()}
  def normalize(headers) when is_map(headers) and not is_struct(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      if valid_name?(name) and valid_value?(value) do
        put_header(acc, String.downcase(name), value)
      else
        {:halt, invalid()}
      end
    end)
  end

  def normalize(_headers), do: invalid()

  defp put_header(headers, name, value) do
    if name in @reserved or Map.has_key?(headers, name),
      do: {:halt, invalid()},
      else: {:cont, {:ok, Map.put(headers, name, value)}}
  end

  defp valid_name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, name)

  defp valid_name?(_name), do: false

  defp valid_value?(value) when is_binary(value),
    do: Regex.match?(~r/\A[\t\x20-\x7E]*\z/, value)

  defp valid_value?(_value), do: false

  defp invalid do
    {:error,
     %Error{
       kind: :validation,
       description: "Invalid Open Payments request headers",
       validation_errors: [
         %{
           field: :headers,
           message:
             "must be a map of unique ASCII header names and values without reserved signing or transport headers"
         }
       ]
     }}
  end
end
