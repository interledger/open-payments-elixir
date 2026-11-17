defmodule OpenPayments.Types.AccessIncoming do
  @moduledoc """
  Incoming-payment permissions in a grant's `access-item` union.

  Required `type` is `incoming-payment`; required `actions` is an array of unique
  strings from create, complete, read, read-all, list and list-all. Empty actions
  are allowed by the pinned schema. Optional `identifier` is an absolute URI:
  omission becomes nil, while explicit JSON null is invalid. Its spelling is
  preserved without HTTP request-target validation or payment-pointer conversion.

  The enclosing access-item union forbids extra fields. This grant-facing type
  enforces that rule even though the standalone access-incoming branch does not
  repeat it. Inspection omits the identifier; explicit map/JSON export includes it.
  Decoding permissions does not obtain a grant or authorize a network request.

  Struct literals can bypass validation. Call `validate/1` after constructing or
  modifying a struct; `to_map/1` converts its shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @derive {Inspect, only: [:type, :actions]}
  @enforce_keys [:type, :actions]
  defstruct [:type, :actions, :identifier]

  @actions ~w(create complete read read-all list list-all)
  @wire_fields ~w(type actions identifier)

  @type t :: %__MODULE__{
          type: String.t(),
          actions: [String.t()],
          identifier: String.t() | nil
        }

  @doc "Decodes an incoming-payment grant access entry using the union's field rules."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    access = %__MODULE__{
      type: data["type"],
      actions: data["actions"],
      identifier: data["identifier"]
    }

    extra_errors =
      if map_size(Map.drop(data, @wire_fields)) == 0,
        do: [],
        else: [issue(:access_incoming, "must contain only type, actions and identifier")]

    case validate_fields(access, Map.has_key?(data, "identifier"), extra_errors) do
      :ok -> {:ok, access}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:access_incoming, "must be a JSON object")])

  @doc "Validates a struct, treating a nil identifier as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = access),
    do: validate_fields(access, not is_nil(access.identifier), [])

  @doc "Converts to protocol fields, omitting a nil identifier, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = access) do
    fields = %{"type" => access.type, "actions" => access.actions}

    if is_nil(access.identifier),
      do: fields,
      else: Map.put(fields, "identifier", access.identifier)
  end

  defp validate_fields(access, identifier_present?, extra_errors) do
    errors =
      Enum.flat_map(
        [
          {access.type == "incoming-payment", :type, "must be incoming-payment"},
          {Validation.unique_enum_array?(access.actions, @actions), :actions,
           "must be an array of unique incoming-payment actions"},
          {not identifier_present? or Validation.absolute_uri?(access.identifier), :identifier,
           "must be an absolute URI when present"}
        ],
        fn
          {true, _field, _message} -> []
          {false, field, message} -> [issue(field, message)]
        end
      )

    case errors ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments incoming-payment access",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.AccessIncoming do
  def encode(access, opts) do
    access |> OpenPayments.Types.AccessIncoming.to_map() |> Jason.Encode.map(opts)
  end
end
