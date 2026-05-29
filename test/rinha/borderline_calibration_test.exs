defmodule Rinha.BorderlineCalibrationTest do
  use ExUnit.Case, async: false

  alias Rinha.Domain.Models.BorderlineCalibration

  test "demotes n=3 to n=2 for legit borderline profile" do
    vector = [400, 0, 0, 4630, 0, 420, 0, 0, 0, 0, 8192, 0, 1229, 0, 0, 0]

    assert BorderlineCalibration.adjust(vector, 3) == 2
  end

  test "keeps score unchanged outside n=3" do
    vector = [400, 0, 0, 4630, 0, 420, 0, 0, 0, 0, 8192, 0, 1229, 0, 0, 0]

    assert BorderlineCalibration.adjust(vector, 2) == 2
    assert BorderlineCalibration.adjust(vector, 4) == 4
  end

  test "does not demote when profile is outside calibrated window" do
    vector = [600, 0, 0, 4630, 0, 420, 0, 0, 0, 0, 8192, 0, 1229, 0, 0, 0]

    assert BorderlineCalibration.adjust(vector, 3) == 3
  end

  test "can be disabled via application env" do
    previous = Application.get_env(:rinha, :n3_borderline_calibration)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:rinha, :n3_borderline_calibration)
      else
        Application.put_env(:rinha, :n3_borderline_calibration, previous)
      end
    end)

    Application.put_env(:rinha, :n3_borderline_calibration, false)

    vector = [400, 0, 0, 4630, 0, 420, 0, 0, 0, 0, 8192, 0, 1229, 0, 0, 0]
    assert BorderlineCalibration.adjust(vector, 3) == 3
  end
end
