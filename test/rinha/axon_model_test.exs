defmodule Rinha.AxonModelTest do
  use ExUnit.Case, async: false

  setup do
    old_path = Application.get_env(:rinha, :axon_model_path)

    on_exit(fn ->
      if old_path == nil do
        Application.delete_env(:rinha, :axon_model_path)
      else
        Application.put_env(:rinha, :axon_model_path, old_path)
      end
    end)

    :ok
  end

  test "loads Axon model payload and scores 16-dim vectors" do
    path =
      Path.join(System.tmp_dir!(), "rinha-model-test-#{System.unique_integer([:positive])}.axon")

    config = Rinha.Domain.Models.Axon.default_config()
    model = Rinha.Domain.Models.Axon.model(config)
    {init_fn, _predict_fn} = Axon.build(model, mode: :inference)

    params = init_fn.(Nx.template({1, config.input_size}, :f32), Axon.ModelState.empty())
    payload = %{format_version: 1, config: config, params: params}
    File.write!(path, Nx.serialize(payload))

    on_exit(fn -> File.rm(path) end)

    Application.put_env(:rinha, :axon_model_path, path)
    :ok = Rinha.AxonStore.build(path: path)

    assert Rinha.Domain.Models.Axon.score(List.duplicate(0, 16)) in 0..5
    assert Rinha.Domain.Models.Axon.score(List.duplicate(8192, 16)) in 0..5
  end
end
