defmodule Featurevisor.CLI.ProjectProcessTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Featurevisor.CLI.Project

  @moduletag skip: match?({:win32, _}, :os.type())

  setup %{tmp_dir: directory} do
    on_exit(fn -> File.rm_rf!(directory) end)
    :ok
  end

  @tag :tmp_dir
  test "warning stays on stderr and leaves JSON intact", %{tmp_dir: directory} do
    with_fake_npx(directory, "success", fn ->
      warning =
        capture_io(:stderr, fn ->
          send(self(), {:result, Project.json(directory, "config")})
        end)

      assert_received {:result, {:ok, %{"ok" => true}}}
      assert warning == "mutation warning\n"
    end)
  end

  @tag :tmp_dir
  test "large stderr does not block and failure retains diagnostics", %{tmp_dir: directory} do
    with_fake_npx(directory, "failure", fn ->
      assert {:error, message} = Project.json(directory, "build")
      assert message =~ "status 17"
      assert message =~ "syntax error at build staging"
      assert byte_size(message) > 262_144
    end)
  end

  defp with_fake_npx(directory, mode, callback) do
    executable = Path.join(directory, "npx")

    File.write!(
      executable,
      "#!/bin/sh\n" <>
        "if [ \"$FAKE_MODE\" = failure ]; then\n" <>
        "  head -c 262144 /dev/zero >&2\n" <>
        "  printf 'syntax error at build staging\\n' >&2\n" <>
        "  exit 17\n" <>
        "fi\n" <>
        "printf 'mutation warning\\n' >&2\n" <>
        "printf '{\"ok\":true}\\n'\n"
    )

    File.chmod!(executable, 0o755)
    old_path = System.get_env("PATH")
    old_mode = System.get_env("FAKE_MODE")
    System.put_env("PATH", directory <> ":" <> old_path)
    System.put_env("FAKE_MODE", mode)

    try do
      callback.()
    after
      System.put_env("PATH", old_path)
      if old_mode, do: System.put_env("FAKE_MODE", old_mode), else: System.delete_env("FAKE_MODE")
    end
  end

  @tag :tmp_dir
  test "runs the nearest local CLI entry with node, then falls back to npx", %{tmp_dir: root} do
    project = Path.join([root, "packages", "flags"])
    File.mkdir_p!(project)
    assert Project.node_command(project) == ["npx", "featurevisor"]
    entry = Path.join([root, "node_modules", "@featurevisor", "cli", "bin.js"])
    File.mkdir_p!(Path.dirname(entry))
    File.write!(entry, "")
    assert Project.node_command(project) == ["node", entry]
  end
end
