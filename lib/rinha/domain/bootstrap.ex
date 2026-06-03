defmodule Rinha.Domain.Bootstrap do
  @moduledoc """
  Domain bootstrap pipeline for API mode startup.
  """

  require Logger

  @spec boot_api!() :: :ok
  def boot_api! do
    Rinha.Domain.ReferenceData.load!()
    Logger.info("Using XGBoost scoring model")
    :ok = Rinha.XGBoostStore.build()

    Logger.info("Warming up scoring with bundled fixtures...")
    warmup!()
    :ok
  end

  @spec warmup!() :: :ok
  def warmup! do
    fixture_vectors = fixture_vectors()
    synthetic = synthetic_vectors(100)
    vectors = fixture_vectors ++ synthetic

    Enum.each(vectors, fn vector ->
      _ = Rinha.Domain.Models.XGBoost.score(vector)
    end)

    Logger.info("Warmup done (#{length(vectors)} queries, model=xgboost)")
    :ok
  end

  @spec ensure_reference_dataset!() :: :ok
  def ensure_reference_dataset! do
    path = reference_dataset_path()

    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        Logger.info("Reference dataset found at #{path} (#{size} bytes)")
        :ok

      {:ok, _} ->
        raise "reference dataset is empty at #{path}"

      {:error, reason} ->
        raise "reference dataset missing at #{path} (#{inspect(reason)})"
    end
  end

  @spec reference_dataset_path() :: String.t()
  def reference_dataset_path do
    configured =
      Application.get_env(:rinha, :references_path) ||
        System.get_env("REFERENCES_PATH")

    default = default_reference_path()

    cond do
      is_binary(configured) and configured != "" ->
        Path.expand(configured)

      File.exists?(default) ->
        default

      true ->
        Path.expand(Path.join(["resources", "references.json.gz"]))
    end
  end

  defp default_reference_path do
    Path.join([:code.priv_dir(:rinha), "resources", "references.json.gz"])
  end

  defp fixture_vectors do
    fixtures_dir = Path.join([:code.priv_dir(:rinha), "resources", "fixtures"])

    if File.dir?(fixtures_dir) do
      for name <- ~w(legit fraud borderline),
          path = Path.join(fixtures_dir, "#{name}.json"),
          File.exists?(path) do
        path
        |> File.read!()
        |> Jason.decode!()
        |> Rinha.Domain.Vectorization.transform()
      end
    else
      []
    end
  end

  defp synthetic_vectors(count) do
    1..count
    |> Enum.map(fn _ ->
      {_shape, payload} = Rinha.Domain.Simulation.generate()
      Rinha.Domain.Vectorization.transform(payload)
    end)
  end
end
