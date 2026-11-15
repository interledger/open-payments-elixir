defmodule OpenPayments do
  @moduledoc """
  An Elixir client for the Open Payments wallet address, authorization, and
  resource server APIs.

  The library uses immutable clients, typed protocol data, and explicit per-call
  access tokens. Applications own persistence and interaction scheduling.
  """

  @spec specification_version() :: String.t()
  def specification_version, do: OpenPayments.Specification.version()
end
