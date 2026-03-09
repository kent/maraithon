defmodule Maraithon.Tools.ListFilesTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.ListFiles

  @test_dir Path.join(System.tmp_dir!(), "maraithon_list_files_test")

  setup do
    # Create test files
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    File.write!(Path.join(@test_dir, "file1.txt"), "content1")
    File.write!(Path.join(@test_dir, "file2.ex"), "content2")
    File.write!(Path.join(@test_dir, "readme.md"), "content3")

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "execute/1" do
    test "lists all files in directory" do
      {:ok, result} = ListFiles.execute(%{"path" => @test_dir})

      assert result.count == 3
      assert length(result.files) == 3
      paths = Enum.map(result.files, & &1.path)
      assert Enum.any?(paths, &String.contains?(&1, "file1.txt"))
    end

    test "respects file pattern" do
      {:ok, result} = ListFiles.execute(%{"path" => @test_dir, "pattern" => "*.txt"})

      assert result.count == 1
      assert hd(result.files).path =~ "file1.txt"
    end

    test "returns file metadata" do
      {:ok, result} = ListFiles.execute(%{"path" => @test_dir})

      file = hd(result.files)
      assert is_binary(file.path)
      assert is_integer(file.size)
      assert is_binary(file.modified)
    end

    test "uses current directory by default" do
      {:ok, result} = ListFiles.execute(%{})

      assert result.base_path == "."
    end

    test "returns error for path outside allowed roots" do
      {:error, message} = ListFiles.execute(%{"path" => "/nonexistent/deeply/nested"})
      assert message == "path is outside allowed roots"
    end
  end
end
