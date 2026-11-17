defmodule OpenPayments.Types.AccessQuote do
  @moduledoc """
  Quote permissions in a grant's `access-item` union.

  Required `type` is `quote`; required `actions` is an array of unique strings from
  create, read and read-all. Empty actions are allowed by the pinned schema.
  Action order is preserved. The enclosing access-item union forbids fields other
  than type and actions, including identifier, limits and extension metadata.

  This type describes permissions without obtaining a grant or issuing a quote.
  Struct literals can bypass validation. Call `validate/1` after constructing or
  modifying a struct; `to_map/1` converts its shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @enforce_keys [:type, :actions]
  defstruct [:type, :actions]

  @actions ~w(create read read-all)
  @wire_fields ~w(type actions)

  @type t :: %__MODULE__{type: String.t(), actions: [String.t()]}

  @doc "Decodes a quote grant access entry using the union's field rules."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    access = %__MODULE__{type: data["type"], actions: data["actions"]}

    extra_errors =
      if map_size(Map.drop(data, @wire_fields)) == 0,
        do: [],
        else: [issue(:access_quote, "must contain only type and actions")]

    case validate_fields(access, extra_errors) do
      :ok -> {:ok, access}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:access_quote, "must be a JSON object")])

  @doc "Validates a quote access struct against the grant access contract."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = access), do: validate_fields(access, [])

  @doc "Converts to protocol fields without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = access), do: %{"type" => access.type, "actions" => access.actions}

  defp validate_fields(access, extra_errors) do
    errors =
      Enum.flat_map(
        [
          {access.type == "quote", :type, "must be quote"},
          {Validation.unique_enum_array?(access.actions, @actions), :actions,
           "must be an array of unique quote actions"}
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
         description: "Invalid Open Payments quote access",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.AccessQuote do
  def encode(access, opts) do
    access |> OpenPayments.Types.AccessQuote.to_map() |> Jason.Encode.map(opts)
  end
end
