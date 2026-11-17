defmodule OpenPayments.Types.ClientDisplay do
  @moduledoc """
  Self-asserted client information shown by an authorization server during consent.

  The pinned `client-display` schema permits optional `name`, `uri` and `logo_uri`
  fields and forbids other fields. Omitted fields become nil and are omitted on
  encoding; explicit JSON nulls are invalid. An empty display object is permitted.

  URI fields follow the schema's absolute-URI format. Their spelling is preserved,
  including `data:` image URIs. This type does not fetch an image, verify ownership,
  or restrict URI schemes to HTTP. The wire field is `logo_uri`, not `logoUri`.

  Struct literals can bypass validation. Call `validate/1` after constructing or
  modifying a struct; `to_map/1` converts its shape without validating it.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  defstruct [:name, :uri, :logo_uri]

  @fields ~w(name uri logo_uri)a
  @wire_fields Enum.map(@fields, &Atom.to_string/1)

  @type t :: %__MODULE__{
          name: String.t() | nil,
          uri: String.t() | nil,
          logo_uri: String.t() | nil
        }

  @doc "Decodes and validates client-display JSON without fetching its URIs."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    display = %__MODULE__{name: data["name"], uri: data["uri"], logo_uri: data["logo_uri"]}
    present = Enum.filter(@fields, &Map.has_key?(data, Atom.to_string(&1)))

    extra_errors =
      if map_size(Map.drop(data, @wire_fields)) == 0,
        do: [],
        else: [issue(:client_display, "must contain only name, uri and logo_uri")]

    case validate_fields(display, present, extra_errors) do
      :ok -> {:ok, display}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:client_display, "must be a JSON object")])

  @doc "Validates a struct, treating nil fields as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = display) do
    present = Enum.reject(@fields, &is_nil(Map.fetch!(display, &1)))
    validate_fields(display, present, [])
  end

  @doc "Converts to protocol fields, omitting nil values, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = display) do
    Enum.reduce(@fields, %{}, fn field, fields ->
      case Map.fetch!(display, field) do
        nil -> fields
        value -> Map.put(fields, Atom.to_string(field), value)
      end
    end)
  end

  defp validate_fields(display, present, extra_errors) do
    errors =
      Enum.flat_map(present, fn field ->
        if valid?(field, Map.fetch!(display, field)),
          do: [],
          else: [issue(field, message(field))]
      end)

    case errors ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp valid?(:name, value), do: Validation.string?(value)
  defp valid?(_uri_field, value), do: Validation.absolute_uri?(value)
  defp message(:name), do: "must be a string when present"
  defp message(_uri_field), do: "must be an absolute URI when present"
  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments client display information",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.ClientDisplay do
  def encode(display, opts) do
    display |> OpenPayments.Types.ClientDisplay.to_map() |> Jason.Encode.map(opts)
  end
end
