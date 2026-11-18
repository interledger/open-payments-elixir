defmodule OpenPayments.Request.Collection do
  @moduledoc false

  alias OpenPayments.{Client, Error}
  alias OpenPayments.Request.URL
  alias OpenPayments.Types.{Pagination, Validation}

  @spec prepare(String.t(), boolean(), String.t(), keyword(), String.t()) ::
          {:ok, String.t(), String.t()} | {:error, Error.t()}
  def prepare(base_url, allow_http, wallet_address, opts, path) do
    with {:ok, token, pagination} <- list_options(opts),
         :ok <- wallet_filter(wallet_address),
         {:ok, url} <- list_url(base_url, allow_http, wallet_address, pagination, path) do
      {:ok, url, token}
    end
  end

  defp list_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(Enum.uniq(Keyword.keys(opts))) == length(opts) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:access_token, :pagination])) do
      with {:ok, token} <- Client.resource_access_token(Keyword.take(opts, [:access_token])),
           {:ok, pagination} <- prepare_pagination(Keyword.get(opts, :pagination, %Pagination{})) do
        {:ok, token, pagination}
      end
    else
      invalid_payment(
        :options,
        "must contain unique access_token and optional pagination options"
      )
    end
  end

  defp list_options(_opts),
    do:
      invalid_payment(
        :options,
        "must be a keyword list with access_token and optional pagination"
      )

  defp prepare_pagination(%Pagination{} = pagination) do
    with :ok <- Pagination.validate(pagination), do: {:ok, pagination}
  end

  defp prepare_pagination(data), do: Pagination.from_map(data)

  defp wallet_filter(value) do
    if Validation.string?(value),
      do: :ok,
      else: invalid_payment(:wallet_address, "must be a string")
  end

  defp list_url(base_url, allow_http, wallet_address, pagination, path) do
    with {:ok, url} <- URL.append_path(base_url, allow_http, path) do
      query =
        pagination
        |> Pagination.to_map()
        |> Enum.sort()
        |> List.insert_at(0, {"wallet-address", wallet_address})
        |> URI.encode_query()
        # URLSearchParams escapes tilde and leaves asterisk literal.
        |> String.replace("~", "%7E")
        |> String.replace("%2A", "*")

      {:ok, url <> "?" <> query}
    end
  end

  defp invalid_payment(field, message),
    do:
      {:error, %Error{kind: :validation, validation_errors: [%{field: field, message: message}]}}
end
