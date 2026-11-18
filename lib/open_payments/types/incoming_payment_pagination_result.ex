defmodule OpenPayments.Types.IncomingPaymentPaginationResult do
  @moduledoc """
  One page of detailed incoming-payment results and typed pagination metadata.

  Required pagination becomes `PageInfo`; required result becomes an ordered list
  of `IncomingPayment` structs, including an empty list. Requiring both fields
  matches Node's public PaginationResult contract and is stricter than the pinned
  response schema, which declares the properties without marking them required.
  Missing or null fields are invalid and are never filled with defaults.

  The list item schema adds additionalProperties false beside an allOf reference.
  As with completion, this codec interprets that restriction over the combined
  detailed fields, rejecting methods and other unknown item fields. Arbitrary
  metadata and permitted nested amount extensions remain valid; the standalone
  `IncomingPayment` codec continues preserving its own extensions. Additional
  JSON fields on the page wrapper are retained in extensions.

  Item order and duplicates are preserved. Page flags/cursors are not compared
  with items, IDs, counts or ordering. Both completed and incomplete payments are
  valid. Asset, amount and time consistency checks belong to resource operations.
  This codec makes no HTTP requests or automatic page traversal.

  Inspection omits all payload data. Explicit map/JSON exports include cursors,
  metadata and extensions. Errors contain safe indexed paths without rejected
  values. Validate modified structs with `validate/1`; `to_map/1` converts without
  validating.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{IncomingPayment, PageInfo, Validation}

  @derive {Inspect, only: []}
  @enforce_keys [:pagination, :result]
  defstruct [:pagination, :result, extensions: %{}]

  @wire_fields ~w(pagination result)

  @type t :: %__MODULE__{
          pagination: PageInfo.t(),
          result: [IncomingPayment.t()],
          extensions: %{optional(String.t()) => term()}
        }

  @doc "Decodes required pagination metadata and every detailed payment in a page."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    {pagination, page_errors} = page_info(data["pagination"], &PageInfo.from_map/1)
    {result, item_errors} = items(data["result"], &decode_item/1)

    response = %__MODULE__{
      pagination: pagination,
      result: result,
      extensions: Map.drop(data, @wire_fields)
    }

    case page_errors ++ item_errors ++ extension_errors(response.extensions) do
      [] -> {:ok, response}
      errors -> invalid(errors)
    end
  end

  def from_map(_data),
    do: invalid([issue(:incoming_payment_pagination_result, "must be a JSON object")])

  @doc "Revalidates typed metadata, each typed payment, item field restrictions and extensions."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = response) do
    {_pagination, page_errors} = page_info(response.pagination, &validate_page/1)
    {_result, item_errors} = items(response.result, &validate_item/1)

    case page_errors ++ item_errors ++ extension_errors(response.extensions) do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  @doc "Exports protocol data, including cursors and metadata, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = response) do
    response.extensions
    |> Map.drop(@wire_fields)
    |> Map.merge(%{
      "pagination" => PageInfo.to_map(response.pagination),
      "result" => Enum.map(response.result, &IncomingPayment.to_map/1)
    })
  end

  defp page_info(value, decoder) do
    case decoder.(value) do
      {:ok, page} -> {page, []}
      {:error, error} -> {nil, prefix(error.validation_errors, :pagination, :page_info)}
    end
  end

  defp validate_page(%PageInfo{} = page) do
    with :ok <- PageInfo.validate(page), do: {:ok, page}
  end

  defp validate_page(_page), do: invalid([issue(:page_info, "must be a PageInfo struct")])

  defp items(values, decoder), do: items(values, decoder, 0, [], [])

  defp items([], _decoder, _index, converted, errors),
    do: {Enum.reverse(converted), errors |> Enum.reverse() |> List.flatten()}

  defp items([value | tail], decoder, index, converted, errors) do
    case decoder.(value) do
      {:ok, payment} ->
        items(tail, decoder, index + 1, [payment | converted], errors)

      {:error, error} ->
        indexed = prefix(error.validation_errors, "result[#{index}]", :incoming_payment)
        items(tail, decoder, index + 1, converted, [indexed | errors])
    end
  end

  # Also rejects improper tails supplied directly outside JSON decoding.
  defp items(_values, _decoder, _index, _converted, _errors),
    do: {[], [issue(:result, "must be an array")]}

  defp decode_item(data) do
    with {:ok, payment} <- IncomingPayment.from_map(data),
         :ok <- closed_item(payment) do
      {:ok, payment}
    end
  end

  defp validate_item(%IncomingPayment{} = payment) do
    with :ok <- IncomingPayment.validate(payment),
         :ok <- closed_item(payment) do
      {:ok, payment}
    end
  end

  defp validate_item(_payment),
    do: invalid([issue(:incoming_payment, "must be an IncomingPayment struct")])

  defp closed_item(payment) do
    if map_size(payment.extensions) == 0,
      do: :ok,
      else:
        invalid([issue(:incoming_payment, "must contain only detailed incoming-payment fields")])
  end

  defp extension_errors(extensions) do
    if Validation.extensions?(extensions, @wire_fields),
      do: [],
      else: [
        issue(:extensions, "must be a JSON object with string keys and no reserved page fields")
      ]
  end

  defp prefix(errors, parent, root) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == root, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments incoming-payment page",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.IncomingPaymentPaginationResult do
  def encode(response, opts) do
    response
    |> OpenPayments.Types.IncomingPaymentPaginationResult.to_map()
    |> Jason.Encode.map(opts)
  end
end
