defmodule OpenPayments.Types.CardAuthorization do
  @moduledoc """
  Card authorization credentials or results carried on outgoing-payment access.

  The pinned schema requires string `tlvData` and `requestId` fields. Optional
  string `pinBlock` requires typed `pwk` PIN working-key data whenever present;
  `pwk` may also be supplied without a PIN block. Additional fields are forbidden.
  Omitted optional fields become nil; explicit JSON null is rejected.

  Field strings are preserved without TLV parsing, hex/length checks, UUID
  requirements or PIN cryptography. Request-ID generation and replay correlation
  belong to the operation layer. This data codec makes no network requests.

  Inspection omits all values. Explicit `to_map/1` and JSON encoding contain
  sensitive card/key data; validation errors retain only safe field paths.
  Validate manually constructed or modified structs with `validate/1`;
  `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{PINWorkingKey, Validation}

  @derive {Inspect, only: []}
  @enforce_keys [:tlv_data, :request_id]
  defstruct [:tlv_data, :request_id, :pin_block, :pwk]

  @wire_fields ~w(tlvData requestId pinBlock pwk)

  @type t :: %__MODULE__{
          tlv_data: String.t(),
          request_id: String.t(),
          pin_block: String.t() | nil,
          pwk: PINWorkingKey.t() | nil
        }

  @doc "Decodes card authorization JSON and enforces the pinBlock-to-pwk dependency."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, pwk} <- decode_pwk(data) do
      card = %__MODULE__{
        tlv_data: data["tlvData"],
        request_id: data["requestId"],
        pin_block: data["pinBlock"],
        pwk: pwk
      }

      extra_errors =
        if map_size(Map.drop(data, @wire_fields)) == 0,
          do: [],
          else: [
            issue(:card_authorization, "must contain only tlvData, requestId, pinBlock and pwk")
          ]

      case validate_fields(card, Map.has_key?(data, "pinBlock"), extra_errors) do
        :ok -> {:ok, card}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:card_authorization, "must be a JSON object")])

  @doc "Validates a struct, treating nil optional fields as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = card),
    do: validate_fields(card, not is_nil(card.pin_block), [])

  @doc "Converts to protocol fields, including sensitive payload data, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = card) do
    fields = %{"tlvData" => card.tlv_data, "requestId" => card.request_id}

    fields =
      if is_nil(card.pin_block), do: fields, else: Map.put(fields, "pinBlock", card.pin_block)

    if is_nil(card.pwk), do: fields, else: Map.put(fields, "pwk", PINWorkingKey.to_map(card.pwk))
  end

  defp decode_pwk(data) do
    case Map.fetch(data, "pwk") do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        case PINWorkingKey.from_map(value) do
          {:ok, pwk} -> {:ok, pwk}
          {:error, error} -> invalid(prefix(error.validation_errors))
        end
    end
  end

  defp validate_fields(card, pin_present?, extra_errors) do
    errors =
      Enum.flat_map(
        [
          {Validation.string?(card.tlv_data), :tlv_data, "must be a string"},
          {Validation.string?(card.request_id), :request_id, "must be a string"},
          {not pin_present? or Validation.string?(card.pin_block), :pin_block,
           "must be a string when present"},
          {not pin_present? or not is_nil(card.pwk), :pwk, "must be provided with pinBlock"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    case errors ++ pwk_errors(card.pwk) ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp pwk_errors(nil), do: []

  defp pwk_errors(%PINWorkingKey{} = pwk) do
    case PINWorkingKey.validate(pwk) do
      :ok -> []
      {:error, error} -> prefix(error.validation_errors)
    end
  end

  defp pwk_errors(_pwk), do: [issue(:pwk, "must be a PINWorkingKey struct when present")]

  defp prefix(errors) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == :pin_working_key, do: :pwk, else: "pwk.#{field}")}
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments card authorization data",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.CardAuthorization do
  def encode(card, opts) do
    card |> OpenPayments.Types.CardAuthorization.to_map() |> Jason.Encode.map(opts)
  end
end
