defmodule Maraithon.Runtime.DbResilienceTest do
  use ExUnit.Case, async: true

  alias Maraithon.Runtime.DbResilience

  test "with_database/2 returns an error tuple for database exceptions" do
    assert {:error, %DBConnection.ConnectionError{message: "queue timeout"}} =
             DbResilience.with_database("test operation", fn ->
               raise DBConnection.ConnectionError, message: "queue timeout"
             end)
  end

  test "with_database/2 catches nested database exits" do
    assert {:error, %DBConnection.ConnectionError{message: "queue timeout"}} =
             DbResilience.with_database("test operation", fn ->
               exit({{%DBConnection.ConnectionError{message: "queue timeout"}, []}, []})
             end)
  end

  test "backoff_ms/3 doubles and caps the retry interval" do
    assert DbResilience.backoff_ms(1_000, 0, 10_000) == 1_000
    assert DbResilience.backoff_ms(1_000, 1, 10_000) == 2_000
    assert DbResilience.backoff_ms(1_000, 3, 10_000) == 8_000
    assert DbResilience.backoff_ms(1_000, 5, 10_000) == 10_000
  end
end
