%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: [
        # Evaluation is intentionally expressed as the same explicit decision
        # tree as the JavaScript source of truth. Splitting it to satisfy a
        # metric would make cross SDK review and correctness work harder.
        {Credo.Check.Refactor.CyclomaticComplexity, false},
        {Credo.Check.Refactor.Nesting, false}
      ]
    }
  ]
}
