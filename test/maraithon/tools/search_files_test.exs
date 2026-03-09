defmodule Maraithon.Tools.SearchFilesTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.SearchFiles

  @test_dir Path.join(System.tmp_dir!(), "maraithon_search_files_test")

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    File.write!(Path.join(@test_dir, "file1.txt"), "Hello World\nThis is a test\nGoodbye World")
    File.write!(Path.join(@test_dir, "file2.txt"), "No matches here\nJust some text")

    File.write!(
      Path.join(@test_dir, "code.ex"),
      "defmodule Test do\n  def hello, do: :world\nend"
    )

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "execute/1" do
    test "searches files for pattern" do
      {:ok, result} = SearchFiles.execute(%{"path" => @test_dir, "pattern" => "World"})

      assert result.count == 2
      assert Enum.all?(result.matches, fn m -> String.contains?(m.line, "World") end)
    end

    test "returns match with line number and context" do
      {:ok, result} = SearchFiles.execute(%{"path" => @test_dir, "pattern" => "Hello"})

      match = hd(result.matches)
      assert match.line_num == 1
      assert is_binary(match.context)
      assert String.contains?(match.file, "file1.txt")
    end

    test "filters by file pattern" do
      {:ok, result} =
        SearchFiles.execute(%{
          "path" => @test_dir,
          "pattern" => "def",
          "file_pattern" => "*.ex"
        })

      assert result.count > 0
      assert Enum.all?(result.matches, fn m -> String.ends_with?(m.file, ".ex") end)
    end

    test "returns error when pattern is missing" do
      {:error, message} = SearchFiles.execute(%{"path" => @test_dir})

      assert message == "pattern is required"
    end

    test "returns error for invalid regex" do
      {:error, message} = SearchFiles.execute(%{"path" => @test_dir, "pattern" => "["})

      assert String.contains?(message, "Invalid regex")
    end

    test "uses default path when not specified" do
      {:ok, result} = SearchFiles.execute(%{"pattern" => "defmodule"})

      assert result.base_path == "."
    end

    test "returns empty matches for no results" do
      {:ok, result} =
        SearchFiles.execute(%{
          "path" => @test_dir,
          "pattern" => "NONEXISTENT_PATTERN_12345"
        })

      assert result.count == 0
      assert result.matches == []
    end
  end
end
