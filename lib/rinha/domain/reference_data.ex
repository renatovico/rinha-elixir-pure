defmodule Rinha.Domain.ReferenceData do
  @moduledoc """
  Domain access to static reference datasets.
  """

  @spec load!() :: :ok
  def load!, do: Rinha.Resources.load!()

  @spec normalization() :: %{atom() => float()}
  def normalization, do: Rinha.Resources.normalization()

  @spec mcc_risk() :: %{String.t() => float()}
  def mcc_risk, do: Rinha.Resources.mcc_risk()
end
