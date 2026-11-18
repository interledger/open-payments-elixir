defmodule OpenPayments.Types.Pagination do
  @moduledoc """
  Pagination query arguments shared by payment-list operations.

  Optional first and last are integers from 1 through 100, following the pinned
  query parameters. At most one may be supplied, matching Node's forward/backward
  pagination union; this exclusivity is an SDK rule beyond the independent
  parameter schemas. Optional cursor is a nonempty UTF-8 string. All fields may
  be omitted; no page size or direction is defaulted.

  Map input accepts only the string keys first, last and cursor. Numeric strings,
  floats, explicit null and unknown fields are invalid. Missing fields become nil
  and are omitted on export. Typed nil fields also mean omission. Wallet filters,
  credentials and resource-server URLs belong to the list operation separately.

  Cursors are opaque and retain their exact spelling without UUID/URL/base64
  checks, trimming, decoding or comparison with page metadata. Exports retain
  integer counts and raw cursor strings; they do not percent-encode a query.
  This type makes no requests and performs no automatic traversal.

  Inspection exposes only counts. Explicit map/JSON exports include the cursor.
  Errors contain safe field paths without rejected values. Validate constructed
  or modified structs with `validate/1`; `to_map/1` converts without validating.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @derive {Inspect, only: [:first, :last]}
  defstruct [:first, :last, :cursor]

  @wire_fields ~w(first last cursor)

  @type t :: %__MODULE__{
          first: 1..100 | nil,
          last: 1..100 | nil,
          cursor: String.t() | nil
        }

  @doc "Decodes strict pagination arguments without coercing values or applying defaults."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    pagination = %__MODULE__{first: data["first"], last: data["last"], cursor: data["cursor"]}

    extra_errors =
      if map_size(Map.drop(data, @wire_fields)) == 0,
        do: [],
        else: [issue(:pagination, "must contain only first, last and cursor")]

    case validate_fields(pagination, &Map.has_key?(data, &1), extra_errors) do
      :ok -> {:ok, pagination}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:pagination, "must be a JSON object")])

  @doc "Revalidates typed pagination arguments, treating nil fields as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = pagination),
    do: validate_fields(pagination, &(not is_nil(Map.fetch!(pagination, field(&1)))), [])

  @doc "Exports present protocol arguments without validation or query encoding."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = pagination) do
    for name <- @wire_fields,
        value = Map.fetch!(pagination, field(name)),
        not is_nil(value),
        into: %{},
        do: {name, value}
  end

  defp validate_fields(pagination, present?, extra_errors) do
    checks = [
      {not present?.("first") or count?(pagination.first), :first,
       "must be an integer from 1 through 100 when present"},
      {not present?.("last") or count?(pagination.last), :last,
       "must be an integer from 1 through 100 when present"},
      {not present?.("cursor") or cursor?(pagination.cursor), :cursor,
       "must be a nonempty string when present"},
      {not (present?.("first") and present?.("last")), :pagination,
       "must not supply both first and last"}
    ]

    errors =
      Enum.flat_map(checks, fn
        {true, _field, _message} -> []
        {false, field, message} -> [issue(field, message)]
      end)

    case errors ++ extra_errors do
      [] -> :ok
      errors -> invalid(errors)
    end
  end

  defp field("first"), do: :first
  defp field("last"), do: :last
  defp field("cursor"), do: :cursor

  defp count?(value), do: is_integer(value) and value in 1..100
  defp cursor?(value), do: Validation.string?(value) and value != ""

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments pagination query arguments",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.Pagination do
  def encode(pagination, opts) do
    pagination |> OpenPayments.Types.Pagination.to_map() |> Jason.Encode.map(opts)
  end
end
