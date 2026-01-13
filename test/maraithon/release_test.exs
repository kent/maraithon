defmodule Maraithon.ReleaseTest do
  use ExUnit.Case, async: true

  describe "module functions" do
    # We can't fully test migrate/0 and rollback/2 without side effects,
    # but we can test that the module compiles and the functions exist

    test "Release module is defined" do
      assert Code.ensure_loaded?(Maraithon.Release)
    end

    test "migrate/0 function exists" do
      # Ensure module is loaded
      {:module, _} = Code.ensure_loaded(Maraithon.Release)
      # Check the function is exported
      assert Maraithon.Release.__info__(:functions) |> Enum.member?({:migrate, 0})
    end

    test "rollback/2 function exists" do
      # Ensure module is loaded
      {:module, _} = Code.ensure_loaded(Maraithon.Release)
      # Check the function is exported
      assert Maraithon.Release.__info__(:functions) |> Enum.member?({:rollback, 2})
    end
  end
end
