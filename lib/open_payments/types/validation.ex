defmodule OpenPayments.Types.Validation do
  @moduledoc false

  @spec string?(term()) :: boolean()
  def string?(value), do: is_binary(value) and String.valid?(value)

  @spec asset_scale?(term()) :: boolean()
  def asset_scale?(value), do: is_integer(value) and value in 0..255

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
