defmodule OpenPayments.Types.PageInfo do
  @moduledoc """
  Pagination metadata shared by incoming- and outgoing-payment lists.

  Follows the pinned `page-info` schema: required boolean has_next_page and
  has_previous_page, plus optional nonempty string start_cursor and end_cursor.
  No additional fields are permitted. Missing cursors become nil and are omitted
  on export; explicit JSON null and empty strings are invalid. Page flags are
  never defaulted.

  Cursors are opaque UTF-8 strings whose spelling is preserved. This codec does
  not require UUIDs, URLs, a particular encoding, both cursors together or a
  relationship between cursors and page flags. It does not fetch pages, validate
  pagination request arguments, infer ordering or compare cursors with results.

  Inspection exposes only the page flags. Explicit map/JSON exports include
  cursors. Errors contain safe field paths without rejected values. Validate
  modified structs with `validate/1`; `to_map/1` converts without validating.
  """

  alias OpenPayments.Error
  alias OpenPayments.Types.Validation

  @derive {Inspect, only: [:has_next_page, :has_previous_page]}
  @enforce_keys [:has_next_page, :has_previous_page]
  defstruct [:has_next_page, :has_previous_page, :start_cursor, :end_cursor]

  @wire_fields ~w(hasNextPage hasPreviousPage startCursor endCursor)

  @type t :: %__MODULE__{
          has_next_page: boolean(),
          has_previous_page: boolean(),
          start_cursor: String.t() | nil,
          end_cursor: String.t() | nil
        }

  @doc "Decodes strict pagination metadata without supplying missing flags or cursors."
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(data) when is_map(data) and not is_struct(data) do
    page = %__MODULE__{
      has_next_page: data["hasNextPage"],
      has_previous_page: data["hasPreviousPage"],
      start_cursor: data["startCursor"],
      end_cursor: data["endCursor"]
    }

    extra_errors =
      if map_size(Map.drop(data, @wire_fields)) == 0,
        do: [],
        else: [issue(:page_info, "must contain only the declared pagination fields")]

    case validate_fields(
           page,
           Map.has_key?(data, "startCursor"),
           Map.has_key?(data, "endCursor"),
           extra_errors
         ) do
      :ok -> {:ok, page}
      {:error, error} -> {:error, error}
    end
  end

  def from_map(_data), do: invalid([issue(:page_info, "must be a JSON object")])

  @doc "Revalidates flags and cursors, treating nil optional cursors as omitted."
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{} = page),
    do: validate_fields(page, not is_nil(page.start_cursor), not is_nil(page.end_cursor), [])

  @doc "Converts to protocol fields, including cursors, without validating."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = page) do
    fields = %{
      "hasNextPage" => page.has_next_page,
      "hasPreviousPage" => page.has_previous_page
    }

    fields =
      if is_nil(page.start_cursor),
        do: fields,
        else: Map.put(fields, "startCursor", page.start_cursor)

    if is_nil(page.end_cursor), do: fields, else: Map.put(fields, "endCursor", page.end_cursor)
  end

  defp validate_fields(page, start_present?, end_present?, extra_errors) do
    checks = [
      {is_boolean(page.has_next_page), :has_next_page, "must be a boolean"},
      {is_boolean(page.has_previous_page), :has_previous_page, "must be a boolean"},
      {not start_present? or cursor?(page.start_cursor), :start_cursor,
       "must be a nonempty string when present"},
      {not end_present? or cursor?(page.end_cursor), :end_cursor,
       "must be a nonempty string when present"}
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

  defp cursor?(value), do: Validation.string?(value) and value != ""

  defp issue(field, message), do: %{field: field, message: message}

  defp invalid(errors),
    do:
      {:error,
       %Error{
         kind: :validation,
         description: "Invalid Open Payments pagination metadata",
         validation_errors: errors
       }}
end

defimpl Jason.Encoder, for: OpenPayments.Types.PageInfo do
  def encode(page, opts) do
    page |> OpenPayments.Types.PageInfo.to_map() |> Jason.Encode.map(opts)
  end
end
