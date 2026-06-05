defmodule Rinha.Domain.Bootstrap do
  @moduledoc """
  Domain bootstrap pipeline for API mode startup.
  """

  require Logger

  @spec boot_api!() :: :ok
  def boot_api! do
    Rinha.Domain.ReferenceData.load!()
    Logger.info("Using Axon scoring model")
    :ok = Rinha.AxonStore.build()

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
      _ = Rinha.Domain.Models.Axon.score(vector)
    end)

    Logger.info("Warmup done (#{length(vectors)} queries, model=axon)")
    :ok
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
