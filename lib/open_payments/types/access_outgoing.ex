defmodule OpenPayments.Types.AccessOutgoing do
  @moduledoc """
  Outgoing-payment permissions in a grant's `access-item` union.

  Requires type `outgoing-payment`, unique action strings from create/read/read-all/
  list/list-all, and an absolute-URI `identifier`. Empty actions are permitted.
  Optional `limits` and `cardAuthorization` decode to typed `OutgoingLimits` and
  `CardAuthorization` structs. Omitted fields become nil; explicit null is invalid.
  The enclosing union forbids extra top-level fields.

  Identifier spelling is preserved without request-target policy or pointer
  conversion. This type does not obtain a grant, process a card or issue payments.
  Inspection omits the identifier and nested payloads; explicit map/JSON export
  includes sensitive card and PIN working-key data when present.

  Validate manually constructed or modified structs with `validate/1`;
  `to_map/1` converts shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.{CardAuthorization, OutgoingLimits, Validation}

  @derive {Inspect, only: [:type, :actions]}
  @enforce_keys [:type, :actions, :identifier]
  defstruct [:type, :actions, :identifier, :limits, :card_authorization]

  @actions ~w(create read read-all list list-all)
  @wire_fields ~w(type actions identifier limits cardAuthorization)

  @type t :: %__MODULE__{
          type: String.t(),
          actions: [String.t()],
          identifier: String.t(),
          limits: OutgoingLimits.t() | nil,
          card_authorization: CardAuthorization.t() | nil
        }

  @doc "Decodes an outgoing-payment access entry and its optional typed payloads."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    with {:ok, limits} <- optional(data, "limits", :limits, &OutgoingLimits.from_map/1),
         {:ok, card} <-
           optional(data, "cardAuthorization", :card_authorization, &CardAuthorization.from_map/1) do
      access = %__MODULE__{
        type: data["type"],
        actions: data["actions"],
        identifier: data["identifier"],
        limits: limits,
        card_authorization: card
      }

      extra_errors =
        if map_size(Map.drop(data, @wire_fields)) == 0,
          do: [],
          else: [
            issue(
              :access_outgoing,
              "must contain only type, actions, identifier, limits and cardAuthorization"
            )
          ]

      case validate_fields(access, extra_errors) do
        :ok -> {:ok, access}
        {:error, error} -> {:error, error}
      end
    end
  end

  def from_map(_data), do: invalid([issue(:access_outgoing, "must be a JSON object")])

  @doc "Validates required fields and revalidates optional typed payloads."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = access), do: validate_fields(access, [])

  @doc "Converts to protocol fields, including nested card data, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = access) do
    fields = %{
      "type" => access.type,
      "actions" => access.actions,
      "identifier" => access.identifier
    }

    fields =
      if is_nil(access.limits),
        do: fields,
        else: Map.put(fields, "limits", OutgoingLimits.to_map(access.limits))

    if is_nil(access.card_authorization),
      do: fields,
      else:
        Map.put(fields, "cardAuthorization", CardAuthorization.to_map(access.card_authorization))
  end

  defp optional(data, wire_field, field, decoder) do
    case Map.fetch(data, wire_field) do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        case decoder.(value) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, error} -> invalid(prefix(error.validation_errors, field))
        end
    end
  end

  defp validate_fields(access, extra_errors) do
    errors =
      Enum.flat_map(
        [
          {access.type == "outgoing-payment", :type, "must be outgoing-payment"},
          {Validation.unique_enum_array?(access.actions, @actions), :actions,
           "must be an array of unique outgoing-payment actions"},
          {Validation.absolute_uri?(access.identifier), :identifier, "must be an absolute URI"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    case errors ++
           limits_errors(access.limits) ++ card_errors(access.card_authorization) ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp limits_errors(nil), do: []

  defp limits_errors(%OutgoingLimits{} = limits),
    do: validation_errors(OutgoingLimits.validate(limits), :limits)

  defp limits_errors(_limits),
    do: [issue(:limits, "must be an OutgoingLimits struct when present")]

  defp card_errors(nil), do: []

  defp card_errors(%CardAuthorization{} = card),
    do: validation_errors(CardAuthorization.validate(card), :card_authorization)

  defp card_errors(_card),
    do: [issue(:card_authorization, "must be a CardAuthorization struct when present")]

  defp validation_errors(:ok, _parent), do: []
  defp validation_errors({:error, error}, parent), do: prefix(error.validation_errors, parent)

  defp prefix(errors, parent) do
    Enum.map(errors, fn %{field: field} = error ->
      %{error | field: if(field == parent, do: parent, else: "#{parent}.#{field}")}
    end)
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments outgoing-payment access",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.AccessOutgoing do
  def encode(access, opts) do
    access |> OpenPayments.Types.AccessOutgoing.to_map() |> Jason.Encode.map(opts)
  end
end
