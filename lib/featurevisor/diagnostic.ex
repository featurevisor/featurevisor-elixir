defmodule Featurevisor.Diagnostic do
  @moduledoc "Structured diagnostic emitted by a Featurevisor instance."

  @type level :: :fatal | :error | :warn | :info | :debug
  @type t :: %__MODULE__{
          level: level(),
          code: String.t(),
          message: String.t(),
          details: map(),
          module: String.t() | nil,
          module_name: String.t() | nil,
          original_error: term() | nil
        }

  @enforce_keys [:level, :code, :message]
  defstruct [:level, :code, :message, :module, :module_name, :original_error, details: %{}]

  @levels [:fatal, :error, :warn, :info, :debug]

  @doc false
  def allowed?(configured, level) do
    level_index(configured) >= level_index(level)
  end

  defp level_index(level), do: Enum.find_index(@levels, &(&1 == level)) || 0
end
