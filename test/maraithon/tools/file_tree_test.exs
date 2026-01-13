defmodule Maraithon.Tools.FileTreeTest do
  use ExUnit.Case, async: true

  alias Maraithon.Tools.FileTree

  @test_dir Path.join(System.tmp_dir!(), "maraithon_file_tree_test")

  setup do
    # Create a test directory structure
    File.rm_rf!(@test_dir)
    File.mkdir_p!(Path.join(@test_dir, "subdir/nested"))
    File.write!(Path.join(@test_dir, "file1.txt"), "content1")
    File.write!(Path.join(@test_dir, "file2.txt"), "content2")
    File.write!(Path.join(@test_dir, "subdir/file3.txt"), "content3")
    File.write!(Path.join(@test_dir, "subdir/nested/file4.txt"), "content4")

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "execute/1" do
    test "returns directory tree" do
      {:ok, result} = FileTree.execute(%{"path" => @test_dir})

      assert result.path == @test_dir
      assert is_binary(result.tree)
      assert String.contains?(result.tree, "file1.txt")
      assert String.contains?(result.tree, "subdir/")
      assert result.entries > 0
    end

    test "uses current directory by default" do
      {:ok, result} = FileTree.execute(%{})

      assert is_binary(result.tree)
    end

    test "respects max depth" do
      {:ok, result} = FileTree.execute(%{"path" => @test_dir, "depth" => 1})

      assert is_binary(result.tree)
      # Should not include deeply nested files when depth is 1
    end

    test "returns error for non-directory path" do
      file_path = Path.join(@test_dir, "file1.txt")
      {:error, message} = FileTree.execute(%{"path" => file_path})

      assert String.contains?(message, "Not a directory")
    end

    test "returns error for non-existent path" do
      {:error, _message} = FileTree.execute(%{"path" => "/nonexistent/path"})
    end
  end
end
