defmodule ForgeClaw.Pod.ManifestTest do
  @moduledoc """
  Tests for `ForgeClaw.Pod.Manifest`.

  ## Testing strategy (HTDP step 6)

  `parse/1` is the heart — tested with valid, partially-valid, and invalid maps.
  `load/1` is tested against temporary files to verify the file → parse pipeline.
  """

  use ExUnit.Case, async: true

  alias ForgeClaw.Pod.Manifest
  alias ForgeClaw.Types.{PodManifest, ResourceRequirements, ModelPreference}
  alias ForgeClaw.Test.Fixtures

  # ── parse/1 ──────────────────────────────────────────────────────────────────

  describe "parse/1" do
    test "parses a complete valid manifest" do
      raw = %{
        "name" => "code-reviewer",
        "version" => "1.0.0",
        "description" => "Reviews code",
        "exposed_tools" => [
          %{"name" => "review_code", "description" => "Reviews code.", "parameters" => %{}}
        ]
      }

      assert {:ok, %PodManifest{name: "code-reviewer", version: "1.0.0"}} = Manifest.parse(raw)
    end

    test "returns errors for missing required fields" do
      assert {:error, errors} = Manifest.parse(%{"version" => "1.0.0"})
      assert is_list(errors)
      assert Enum.any?(errors, &(&1 =~ "name"))
      assert Enum.any?(errors, &(&1 =~ "description"))
    end

    test "returns error when exposed_tools is empty" do
      raw = %{
        "name" => "pod",
        "version" => "1.0.0",
        "description" => "A pod",
        "exposed_tools" => []
      }
      assert {:error, errors} = Manifest.parse(raw)
      assert Enum.any?(errors, &(&1 =~ "exposed_tools"))
    end

    test "applies defaults for optional fields" do
      raw = %{
        "name" => "minimal",
        "version" => "1.0.0",
        "description" => "Minimal pod",
        "exposed_tools" => [%{"name" => "ping", "description" => "Pong", "parameters" => %{}}]
      }

      assert {:ok, manifest} = Manifest.parse(raw)
      assert manifest.isolation == :beam
      assert manifest.internal_tools == []
    end

    test "parses requires section" do
      raw = %{
        "name" => "heavy",
        "version" => "1.0.0",
        "description" => "Needs GPU",
        "requires" => %{"min_ram_mb" => 16384, "gpu" => "required"},
        "exposed_tools" => [%{"name" => "t", "description" => "d", "parameters" => %{}}]
      }

      assert {:ok, manifest} = Manifest.parse(raw)
      assert manifest.requires.min_ram_mb == 16384
      assert manifest.requires.gpu == :required
    end
  end

  # ── parse_requires/1 ─────────────────────────────────────────────────────────

  describe "parse_requires/1" do
    test "returns defaults for nil" do
      result = Manifest.parse_requires(nil)
      assert %ResourceRequirements{gpu: :optional} = result
    end

    test "parses gpu: required" do
      assert %ResourceRequirements{gpu: :required} =
        Manifest.parse_requires(%{"gpu" => "required"})
    end

    test "parses gpu: none" do
      assert %ResourceRequirements{gpu: :none} =
        Manifest.parse_requires(%{"gpu" => "none"})
    end
  end

  # ── load/1 ───────────────────────────────────────────────────────────────────

  describe "load/1" do
    test "loads a valid manifest.yaml file" do
      dir = Path.join(System.tmp_dir!(), "fc_manifest_test_#{:rand.uniform(99999)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "manifest.yaml"), Fixtures.minimal_manifest_yaml())

      assert {:ok, %PodManifest{name: "test-pod"}} =
        Manifest.load(Path.join(dir, "manifest.yaml"))
    end

    test "returns :enoent for missing file" do
      assert {:error, :enoent} = Manifest.load("/nonexistent/manifest.yaml")
    end

    test "returns validation errors for invalid manifest" do
      dir = Path.join(System.tmp_dir!(), "fc_manifest_test_#{:rand.uniform(99999)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      File.write!(Path.join(dir, "manifest.yaml"), Fixtures.invalid_manifest_yaml())

      assert {:error, errors} = Manifest.load(Path.join(dir, "manifest.yaml"))
      assert is_list(errors)
    end
  end
end
