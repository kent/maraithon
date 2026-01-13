defmodule Maraithon.Tools.TimeTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.Time

  describe "execute/1" do
    test "returns current time in UTC and Unix format" do
      {:ok, result} = Time.execute(%{})

      assert is_binary(result.utc)
      assert is_integer(result.unix)

      # Verify UTC format is ISO8601
      {:ok, parsed, _} = DateTime.from_iso8601(result.utc)
      assert DateTime.diff(DateTime.utc_now(), parsed) < 2
    end
  end
end
