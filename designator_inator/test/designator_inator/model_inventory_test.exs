defmodule DesignatorInator.ModelInventoryTest do
  @moduledoc """
  Tests for `DesignatorInator.ModelInventory`.

  ## Testing strategy (HTDP step 6)

  The pure functions (`parse_gguf_filename/1`, `parse_quantization/1`) are
  tested exhaustively without any process or filesystem.

  `scan_directory/1` is tested against a temporary directory we control.

  The GenServer (`list/0`, `get/1`) is tested with the test config pointing
  at the fixtures model directory.
  """

  use ExUnit.Case, async: false

  alias DesignatorInator.ModelInventory
  alias DesignatorInator.Types.Model

  # ── parse_gguf_filename/1 ────────────────────────────────────────────────────

  describe "parse_gguf_filename/1" do
    # HTDP step 3: functional examples articulated as tests

    test "parses a standard mistral filename" do
      # Example from data definition
      assert {:ok, %Model{
        name: "mistral-7b-instruct-v0.3.Q4_K_M",
        size_params_b: 7.0,
        quantization: :q4_k_m
      }} = ModelInventory.parse_gguf_filename("mistral-7b-instruct-v0.3.Q4_K_M.gguf")
    end

    test "parses a codellama filename" do
      assert {:ok, %Model{
        name: "codellama-13b-instruct.Q5_K_M",
        size_params_b: 13.0,
        quantization: :q5_k_m
      }} = ModelInventory.parse_gguf_filename("codellama-13b-instruct.Q5_K_M.gguf")
    end

    test "parses an fp16 filename" do
      assert {:ok, %Model{quantization: :f16}} =
        ModelInventory.parse_gguf_filename("phi-3-mini-4k-instruct-fp16.gguf")
    end

    test "returns :unrecognized_format for non-gguf files" do
      assert {:error, :unrecognized_format} =
        ModelInventory.parse_gguf_filename("not-a-model.txt")
    end

    test "handles unknown quantization strings gracefully" do
      assert {:ok, %Model{quantization: {:unknown, "NEWFORMAT"}}} =
        ModelInventory.parse_gguf_filename("custom-model.NEWFORMAT.gguf")
    end

    test "handles filenames with no parameter count" do
      # Some models don't encode the param count in the filename
      assert {:ok, %Model{size_params_b: 0.0}} =
        ModelInventory.parse_gguf_filename("my-custom-model.Q4_K_M.gguf")
    end
  end

  # ── parse_quantization/1 ─────────────────────────────────────────────────────

  describe "parse_quantization/1" do
    test "maps all known quantization strings to atoms" do
      known = [
        {"Q4_K_M", :q4_k_m},
        {"Q4_K_S", :q4_k_s},
        {"Q5_K_M", :q5_k_m},
        {"Q5_K_S", :q5_k_s},
        {"Q8_0",   :q8_0},
        {"Q6_K",   :q6_k},
        {"Q3_K_M", :q3_k_m},
        {"Q2_K",   :q2_k},
        {"F16",    :f16},
        {"BF16",   :bf16},
        {"F32",    :f32}
      ]

      for {input, expected} <- known do
        assert ModelInventory.parse_quantization(input) == expected,
               "Expected parse_quantization(#{inspect(input)}) == #{inspect(expected)}"
      end
    end

    test "wraps unknown strings" do
      assert {:unknown, "NEWQUANT"} = ModelInventory.parse_quantization("NEWQUANT")
    end
  end

  # ── scan_directory/1 ─────────────────────────────────────────────────────────

  describe "scan_directory/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "fc_test_models_#{:rand.uniform(99999)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "returns empty list for empty directory", %{dir: dir} do
      assert {:ok, []} = ModelInventory.scan_directory(dir)
    end

    test "returns :enoent for nonexistent directory" do
      assert {:error, :enoent} = ModelInventory.scan_directory("/totally/nonexistent/path")
    end

    test "scans and parses .gguf files, skips non-gguf files", %{dir: dir} do
      # Create fake .gguf files (content doesn't matter for scanning)
      File.write!(Path.join(dir, "mistral-7b-instruct-v0.3.Q4_K_M.gguf"), "fake")
      File.write!(Path.join(dir, "readme.txt"), "ignored")

      assert {:ok, models} = ModelInventory.scan_directory(dir)
      assert length(models) == 1
      assert hd(models).name == "mistral-7b-instruct-v0.3.Q4_K_M"
    end

    test "does not crash on unparseable filenames", %{dir: dir} do
      File.write!(Path.join(dir, "weird_name.gguf"), "fake")
      # Should return result (possibly empty if totally unparseable), not crash
      assert {:ok, _models} = ModelInventory.scan_directory(dir)
    end
  end

  # ── GenServer API ────────────────────────────────────────────────────────────

  describe "GenServer API" do
    setup do
      dir = Path.join(System.tmp_dir!(), "di_model_inventory_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      old_models_dir = Application.get_env(:designator_inator, :models_dir)
      Application.put_env(:designator_inator, :models_dir, dir)

      on_exit(fn ->
        if old_models_dir do
          Application.put_env(:designator_inator, :models_dir, old_models_dir)
        else
          Application.delete_env(:designator_inator, :models_dir)
        end

        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    test "list/0, get/1, and rescan/0 reflect the configured models directory", %{dir: dir} do
      File.write!(Path.join(dir, "mistral-7b-instruct-v0.3.Q4_K_M.gguf"), "fake")

      start_supervised!(ModelInventory)

      assert {:ok, [%Model{name: "mistral-7b-instruct-v0.3.Q4_K_M"}]} = ModelInventory.list()

      assert {:ok, %Model{name: "mistral-7b-instruct-v0.3.Q4_K_M"}} =
               ModelInventory.get("mistral-7b-instruct-v0.3.Q4_K_M")

      assert {:error, :not_found} = ModelInventory.get("missing-model")

      File.write!(Path.join(dir, "codellama-13b-instruct.Q5_K_M.gguf"), "fake")

      assert {:ok, 2} = ModelInventory.rescan()
      assert {:ok, models} = ModelInventory.list()

      assert Enum.sort(Enum.map(models, & &1.name)) == [
               "codellama-13b-instruct.Q5_K_M",
               "mistral-7b-instruct-v0.3.Q4_K_M"
             ]
    end
  end
end
