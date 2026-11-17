defmodule OpenPayments.Types.Access do
  @moduledoc """
  A grant access array containing typed incoming-payment, outgoing-payment or
  quote entries.

  `from_list/1` decodes JSON objects to their corresponding structs. The pinned
  schema permits an empty array and at most three unique objects. Distinct objects
  of the same resource type are allowed. Entry and action order are preserved;
  uniqueness compares complete JSON values, independent of object-key order.

  The result is an ordinary Elixir list of typed structs.
  Jason encodes the list directly; `to_list/1` explicitly converts entries to wire
  maps. Those exports can include sensitive card data. Entry inspection omits it.
  Errors include safe indexed paths such as `access[1].card_authorization.pwk.key`.

  `validate/1` revalidates modified typed lists. These functions do not obtain a
  grant, process a card, track spending or make network requests.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{AccessIncoming, AccessOutgoing, AccessQuote}

  @type item :: AccessIncoming.t() | AccessOutgoing.t() | AccessQuote.t()
  @type t :: [item()]

  @doc "Decodes up to three unique access JSON objects into an ordered typed list."
  @spec from_list(list()) :: {:ok, t()} | {:error, Error.t()}
  def from_list(values), do: convert(values, &decode_item/1)

  @doc "Validates a list of typed access entries and its cardinality/uniqueness."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(values) do
    case convert(values, &validate_item/1) do
      {:ok, _items} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc "Converts typed entries to wire maps without validating, including card payloads."
  @spec to_list(t()) :: [map()]
  def to_list(items), do: Enum.map(items, &to_map/1)

  defp convert(values, decoder) when is_list(values) and length(values) <= 3 do
    {items, errors} =
      values
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {value, index}, {items, errors} ->
        case decoder.(value) do
          {:ok, item} -> {[item | items], errors}
          {:error, error} -> {items, [prefix(error.validation_errors, index) | errors]}
        end
      end)

    finish(Enum.reverse(items), errors |> Enum.reverse() |> List.flatten())
  end

  defp convert(values, _decoder) when is_list(values),
    do: invalid([issue(:access, "must contain at most three access entries")])

  defp convert(_values, _decoder), do: invalid([issue(:access, "must be an array")])

  defp finish(items, []) do
    wire = to_list(items)

    duplicate? =
      wire
      |> Enum.with_index()
      |> Enum.any?(fn {entry, index} -> Enum.any?(Enum.drop(wire, index + 1), &(&1 == entry)) end)

    if duplicate?,
      do: invalid([issue(:access, "must contain unique access objects")]),
      else: {:ok, items}
  end

  defp finish(_items, errors), do: invalid(errors)

  defp decode_item(%{"type" => "incoming-payment"} = data), do: AccessIncoming.from_map(data)
  defp decode_item(%{"type" => "outgoing-payment"} = data), do: AccessOutgoing.from_map(data)
  defp decode_item(%{"type" => "quote"} = data), do: AccessQuote.from_map(data)

  defp decode_item(data) when is_map(data) and not is_struct(data),
    do: invalid([issue(:type, "must be incoming-payment, outgoing-payment or quote")])

  defp decode_item(_value), do: invalid([issue(:access_item, "must be an access JSON object")])

  defp validate_item(%AccessIncoming{} = item), do: checked(item, AccessIncoming.validate(item))
  defp validate_item(%AccessOutgoing{} = item), do: checked(item, AccessOutgoing.validate(item))
  defp validate_item(%AccessQuote{} = item), do: checked(item, AccessQuote.validate(item))
  defp validate_item(_item), do: invalid([issue(:access_item, "must be a typed access struct")])

  defp checked(item, :ok), do: {:ok, item}
  defp checked(_item, {:error, error}), do: {:error, error}

  defp to_map(%AccessIncoming{} = item), do: AccessIncoming.to_map(item)
  defp to_map(%AccessOutgoing{} = item), do: AccessOutgoing.to_map(item)
  defp to_map(%AccessQuote{} = item), do: AccessQuote.to_map(item)

  defp prefix(errors, index) do
    Enum.map(errors, fn %{field: field} = error ->
      path =
        if field in [:access_incoming, :access_outgoing, :access_quote, :access_item],
          do: "access[#{index}]",
          else: "access[#{index}].#{field}"

      %{error | field: path}
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments access array",
         validation_errors: errors
       }}
end
