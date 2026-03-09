defmodule Maraithon.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.ReadFile

  @test_dir Path.join(System.tmp_dir!(), "maraithon_read_file_test")

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    File.write!(Path.join(@test_dir, "test.txt"), "Hello, World!")

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "execute/1" do
    test "reads file content" do
      path = Path.join(@test_dir, "test.txt")
      {:ok, result} = ReadFile.execute(%{"path" => path})

      assert result.path == path
      assert result.content == "Hello, World!"
      assert result.size == 13
    end

    test "returns error when path is missing" do
      {:error, message} = ReadFile.execute(%{})

      assert message == "path is required"
    end

    test "returns error for non-existent file" do
      {:error, message} = ReadFile.execute(%{"path" => "/nonexistent/file.txt"})

      assert String.contains?(message, "not found") or
               String.contains?(message, "not accessible") or
               String.contains?(message, "outside allowed roots")
    end

    test "returns error for file too large" do
      # Create a file larger than 100KB
      large_file = Path.join(@test_dir, "large.txt")
      # Create 100KB of data
      File.write!(large_file, String.duplicate("x", 100_001))

      {:error, message} = ReadFile.execute(%{"path" => large_file})

      assert String.contains?(message, "too large")
    end
  end
end
