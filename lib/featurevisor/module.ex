defmodule Featurevisor.Module do
  @moduledoc "Evaluation and lifecycle extension for a Featurevisor instance."

  alias Featurevisor.{Diagnostic, Evaluation}

  @type api :: %{
          get_revision: (-> String.t()),
          on_diagnostic: (function(), keyword() -> function()),
          report_diagnostic: (Diagnostic.t() | map() -> :ok)
        }

  @type t :: %__MODULE__{
          name: String.t() | nil,
          setup: (api() -> any()) | nil,
          before: (map() -> map()) | nil,
          before_evaluation: (map() -> map()) | nil,
          bucket_key: (map() -> String.t()) | nil,
          bucket_value: (map() -> non_neg_integer()) | nil,
          after: (Evaluation.t(), map() -> Evaluation.t()) | nil,
          after_evaluation: (Evaluation.t(), map() -> Evaluation.t()) | nil,
          close: (-> any()) | nil
        }

  defstruct [
    :name,
    :setup,
    :before,
    :before_evaluation,
    :bucket_key,
    :bucket_value,
    :after,
    :after_evaluation,
    :close,
    :id
  ]
end
