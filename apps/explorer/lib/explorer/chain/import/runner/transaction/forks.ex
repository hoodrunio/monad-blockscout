defmodule Explorer.Chain.Import.Runner.Transaction.Forks do
  @moduledoc """
  Bulk imports `t:Explorer.Chain.Transaction.Fork.t/0`.
  """

  require Ecto.Query

  import Ecto.Query, only: [from: 2]

  alias Ecto.{Multi, Repo}
  alias Explorer.Chain.{Hash, Import, Transaction}
  alias Explorer.Prometheus.Instrumenter

  @behaviour Import.Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [
          %{required(:uncle_hash) => Hash.Full.t(), required(:hash) => Hash.Full.t()}
        ]

  @impl Import.Runner
  def ecto_schema_module, do: Transaction.Fork

  @impl Import.Runner
  def option_key, do: :transaction_forks

  @impl Import.Runner
  def imported_table_row do
    %{
      value_type: "[%{uncle_hash: Explorer.Chain.Hash.t(), hash: Explorer.Chain.Hash.t()}]",
      value_description: "List of maps of the `t:#{ecto_schema_module()}.t/0` `uncle_hash` and `hash` "
    }
  end

  @impl Import.Runner
  def run(multi, changes_list, %{timestamps: timestamps} = options) do
    insert_options =
      options
      |> Map.get(option_key(), %{})
      |> Map.take(~w(on_conflict timeout)a)
      |> Map.put_new(:timeout, @timeout)
      |> Map.put(:timestamps, timestamps)

    Multi.run(multi, :transaction_forks, fn repo, _ ->
      Instrumenter.block_import_stage_runner(
        fn -> insert(repo, changes_list, insert_options) end,
        :block_referencing,
        :forks,
        :transaction_forks
      )
    end)
  end

  @impl Import.Runner
  def timeout, do: @timeout

  @spec insert(Repo.t(), [map()], %{
          optional(:on_conflict) => Import.Runner.on_conflict(),
          required(:timeout) => timeout,
          required(:timestamps) => Import.timestamps()
        }) :: {:ok, [%{uncle_hash: Hash.t(), hash: Hash.t()}]}
  defp insert(repo, changes_list, %{timeout: timeout, timestamps: timestamps} = options) when is_list(changes_list) do
    on_conflict = Map.get_lazy(options, :on_conflict, &default_on_conflict/0)

    # Enforce Fork ShareLocks order (see docs: sharelocks.md)
    # Modified for Citus: sort by distribution column (hash) first
    ordered_changes_list = Enum.sort_by(changes_list, &{&1.hash, &1.index})

    # Modified for Citus distributed table support
    # transaction_forks PRIMARY KEY: (hash, index) - matches distribution column
    # Old PK was: UNIQUE (uncle_hash, index) - incompatible with Citus
    Import.insert_changes_list(
      repo,
      ordered_changes_list,
      conflict_target: [:hash, :index],
      on_conflict: on_conflict,
      for: Transaction.Fork,
      returning: [:uncle_hash, :hash],
      timeout: timeout,
      timestamps: timestamps
    )
  end

  defp default_on_conflict do
    # Citus compatibility: use :replace_all instead of query-based on_conflict
    # Query-based on_conflict generates SELECT FOR UPDATE which is incompatible
    # with Citus distributed tables without WHERE clause on distribution column
    :replace_all
  end
end
