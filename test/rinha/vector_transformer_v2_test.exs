defmodule Rinha.VectorTransformerV2Test do
  use ExUnit.Case, async: false

  alias Rinha.VectorTransformerV2, as: V

  setup_all do
    Rinha.Resources.load!()
    :ok
  end

  @legit %{
    "transaction" => %{"amount" => 41.12, "installments" => 2, "requested_at" => "2026-03-11T18:45:53Z"},
    "customer" => %{"avg_amount" => 82.24, "tx_count_24h" => 3, "known_merchants" => ["MERC-003", "MERC-016"]},
    "merchant" => %{"id" => "MERC-016", "mcc" => "5411", "avg_amount" => 60.25},
    "terminal" => %{"is_online" => false, "card_present" => true, "km_from_home" => 29.23},
    "last_transaction" => nil
  }

  test "stride and scale are stable" do
    assert V.stride() == 16
    assert V.scale() == 8192
  end

  test "output is always 16 ints" do
    out = V.transform(@legit)
    assert length(out) == 16
    assert Enum.all?(out, &is_integer/1)
  end

  test "lanes 14 and 15 are zero pads" do
    out = V.transform(@legit)
    assert Enum.at(out, 14) == 0
    assert Enum.at(out, 15) == 0
  end

  test "nil last_transaction => lanes 5 and 6 are -scale" do
    out = V.transform(@legit)
    assert Enum.at(out, 5) == -8192
    assert Enum.at(out, 6) == -8192
  end

  test "amount lane (0) matches q(amount/max_amount)" do
    out = V.transform(@legit)
    # 41.12/10000 = 0.004112, q = round(0.004112*8192) = 34
    assert Enum.at(out, 0) == 34
  end

  test "hour lookup (lane 3) for hour=18" do
    out = V.transform(@legit)
    # hour=18, q = round(18/23 * 8192) = 6411
    assert Enum.at(out, 3) == 6411
  end

  test "day_of_week lookup (lane 4) Wednesday=2 zero-based" do
    out = V.transform(@legit)
    # 2026-03-11 is Wednesday => dow=2 zero-based, q = round(2/6 * 8192) = 2731
    assert Enum.at(out, 4) == 2731
  end

  test "known merchant => unknown_merchant lane (11) is 0" do
    out = V.transform(@legit)
    assert Enum.at(out, 11) == 0
  end

  test "unknown merchant => unknown_merchant lane (11) is scale" do
    payload = put_in(@legit, ["customer", "known_merchants"], ["OTHER"])
    out = V.transform(payload)
    assert Enum.at(out, 11) == 8192
  end

  test "is_online=true and card_present=true => lanes 9, 10 are scale" do
    payload =
      @legit
      |> put_in(["terminal", "is_online"], true)
      |> put_in(["terminal", "card_present"], true)

    out = V.transform(payload)
    assert Enum.at(out, 9) == 8192
    assert Enum.at(out, 10) == 8192
  end

  test "unknown MCC => lane 12 falls back to 0.5 (q=4096)" do
    payload = put_in(@legit, ["merchant", "mcc"], "9999")
    out = V.transform(payload)
    assert Enum.at(out, 12) == 4096
  end

  test "known MCC 5411 => lane 12 is q(0.15)=1229" do
    out = V.transform(@legit)
    assert Enum.at(out, 12) == 1229
  end

  test "with last_transaction => lanes 5,6 are clamped quantized values" do
    payload = put_in(@legit, ["last_transaction"], %{"timestamp" => "2026-03-11T18:00:00Z", "km_from_current" => 12.0})
    out = V.transform(payload)
    # 45min 53s / 1440 = 0.0319 => q = round(0.0319*8192) = 261
    assert Enum.at(out, 5) == 261
    # 12km/1000 = 0.012 => q = round(0.012*8192) = 98
    assert Enum.at(out, 6) == 98
  end

  test "extreme amount clamps to scale (lane 0 = 8192)" do
    payload = put_in(@legit, ["transaction", "amount"], 1_000_000.0)
    out = V.transform(payload)
    assert Enum.at(out, 0) == 8192
  end

  test "fixtures parse and produce well-formed vectors" do
    for name <- ~w(legit fraud borderline) do
      payload =
        Path.join([:code.priv_dir(:rinha), "resources", "fixtures", "#{name}.json"])
        |> File.read!()
        |> Jason.decode!()

      out = V.transform(payload)
      assert length(out) == 16
      assert Enum.at(out, 14) == 0
      assert Enum.at(out, 15) == 0
      assert Enum.all?(out, &(&1 in -32_768..32_767))
    end
  end
end
