defmodule Rinha.AxonStore do
  @moduledoc """
  Loads and caches the Axon model payload used by runtime scoring.
  """

  require Logger

  @persistent_key {:rinha, :axon_store}

  @spec build(keyword()) :: :ok
  def build(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:exla)
    {:ok, _} = Application.ensure_all_started(:axon)

    path =
      opts[:path] ||
        Application.get_env(:rinha, :axon_model_path) ||
        default_model_path()

    Logger.info("Loading Axon model from #{path}...")

    payload =
      path
      |> File.read!()
      |> Nx.deserialize()
      |> normalize_payload!()

    model = Rinha.Domain.Models.Axon.model(payload.config)
    {_init_fn, predict_fn} = Axon.build(model, mode: :inference)

    compiled_predict =
      Nx.Defn.compile(
        predict_fn,
        [
          Nx.to_template(payload.params),
          Nx.template({1, payload.config.input_size}, :f32)
        ],
        compiler: EXLA
      )

    store = %{
      config: payload.config,
      params: payload.params,
      predict_fn: compiled_predict
    }

    :persistent_term.put(@persistent_key, store)

    Logger.info(
      "Axon model ready (input=#{payload.config.input_size}, hidden1=#{payload.config.hidden_size_1}, hidden2=#{payload.config.hidden_size_2})"
    )

    :ok
  end

  @spec get() :: map()
  def get do
    case :persistent_term.get(@persistent_key, nil) do
      nil -> raise("Axon model store not initialized. Call Rinha.AxonStore.build/1 first.")
      store -> store
    end
  end

  defp normalize_payload!(payload) when is_map(payload) do
    format = Map.get(payload, :format) || Map.get(payload, "format")

    format_version =
      payload
      |> Map.get(:format_version)
      |> Kernel.||(Map.get(payload, "format_version"))
      |> normalize_int()

    params = Map.get(payload, :params) || Map.get(payload, "params")
    config = Map.get(payload, :config) || Map.get(payload, "config") || %{}

    if is_nil(params) do
      raise("Invalid Axon payload: missing params")
    end

    if format not in [nil, "axon-v1"] or format_version not in [nil, 1] do
      raise(
        "Unsupported Axon payload format: format=#{inspect(format)} version=#{inspect(format_version)}"
      )
    end

    %{
      config: Rinha.Domain.Models.Axon.normalize_config(config),
      params: params
    }
  end

  defp normalize_payload!(other), do: raise("Invalid Axon payload: #{inspect(other)}")

  defp normalize_int(%Nx.Tensor{} = tensor), do: tensor |> Nx.to_number() |> trunc()
  defp normalize_int(value) when is_integer(value), do: value
  defp normalize_int(_), do: nil

  defp default_model_path do
    :rinha
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("model.axon")
  end
end
