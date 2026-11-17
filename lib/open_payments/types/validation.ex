defmodule OpenPayments.Types.Validation do
  @moduledoc false

  @spec string?(term()) :: boolean()
  def string?(value), do: is_binary(value) and String.valid?(value)

  @spec asset_scale?(term()) :: boolean()
  def asset_scale?(value), do: is_integer(value) and value in 0..255

  @spec unique_enum_array?(term(), [String.t()]) :: boolean()
  def unique_enum_array?(values, allowed) when is_list(values),
    do: Enum.all?(values, &(&1 in allowed)) and length(Enum.uniq(values)) == length(values)

  def unique_enum_array?(_values, _allowed), do: false

  @spec absolute_uri?(term()) :: boolean()
  def absolute_uri?(value) when is_binary(value) do
    if Regex.match?(~r/\A[\x21-\x7E]+\z/, value) and
         not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value) do
      valid_absolute_uri?(:uri_string.parse(value))
    else
      false
    end
  end

  def absolute_uri?(_value), do: false

  @spec date_time?(term()) :: boolean()
  def date_time?(value) when is_binary(value) do
    pattern =
      ~r/\A([0-9]{4}-[0-9]{2}-[0-9]{2})[Tt]([0-9]{2}:[0-9]{2}:)([0-9]{2})(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})\z/

    case Regex.run(pattern, value, capture: :all_but_first) do
      [date, time, second, fraction, offset] ->
        # DateTime cannot represent leap seconds. Validate their preceding second
        # and UTC minute without truncating or normalizing the stored wire value.
        normalized_second = if second == "60", do: "59", else: second
        normalized_offset = if offset == "-00:00", do: "Z", else: String.upcase(offset)
        parsed = date <> "T" <> time <> normalized_second <> fraction <> normalized_offset

        case DateTime.from_iso8601(parsed) do
          {:ok, datetime, _offset} ->
            second != "60" or leap_second_slot?(datetime)

          {:error, _reason} ->
            false
        end

      nil ->
        false
    end
  end

  def date_time?(_value), do: false

  defp leap_second_slot?(datetime) do
    datetime.hour == 23 and datetime.minute == 59 and
      datetime.day == Date.days_in_month(DateTime.to_date(datetime))
  end

  @spec extensions?(term(), [String.t()]) :: boolean()
  def extensions?(extensions, reserved) when is_map(extensions) and not is_struct(extensions) do
    Enum.all?(Map.keys(extensions), fn key ->
      is_binary(key) and key not in reserved
    end) and match?({:ok, _}, Jason.encode(extensions))
  end

  def extensions?(_extensions, _reserved), do: false

  defp valid_absolute_uri?(%{scheme: scheme} = parts) when is_binary(scheme) do
    if String.downcase(scheme) in ["http", "https"] do
      host = Map.get(parts, :host)
      is_binary(host) and host != ""
    else
      true
    end
  end

  defp valid_absolute_uri?(_result), do: false
end
