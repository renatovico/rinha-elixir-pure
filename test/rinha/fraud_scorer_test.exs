defmodule Rinha.DomainDecisionTest do
  use ExUnit.Case, async: true

  describe "responses" do
    test "fraud_count 0 → approved, score 0.0" do
      response = Jason.decode!(fraud_response(0))
      assert response["approved"] == true
      assert response["fraud_score"] == 0.0
    end

    test "fraud_count 1 → approved, score 0.2" do
      response = Jason.decode!(fraud_response(1))
      assert response["approved"] == true
      assert response["fraud_score"] == 0.2
    end

    test "fraud_count 2 → approved, score 0.4" do
      response = Jason.decode!(fraud_response(2))
      assert response["approved"] == true
      assert response["fraud_score"] == 0.4
    end

    test "fraud_count 3 → denied, score 0.6" do
      response = Jason.decode!(fraud_response(3))
      assert response["approved"] == false
      assert response["fraud_score"] == 0.6
    end

    test "fraud_count 4 → denied, score 0.8" do
      response = Jason.decode!(fraud_response(4))
      assert response["approved"] == false
      assert response["fraud_score"] == 0.8
    end

    test "fraud_count 5 → denied, score 1.0" do
      response = Jason.decode!(fraud_response(5))
      assert response["approved"] == false
      assert response["fraud_score"] == 1.0
    end

    test "threshold: < 0.6 is approved, >= 0.6 is denied" do
      for count <- 0..5 do
        response = Jason.decode!(fraud_response(count))
        fraud_score = count / 5

        if fraud_score < 0.6 do
          assert response["approved"] == true, "count=#{count} should be approved"
        else
          assert response["approved"] == false, "count=#{count} should be denied"
        end
      end
    end
  end

  # Use the domain decision policy directly
  defp fraud_response(count) do
    Rinha.Domain.Decision.response_for(count)
  end
end
