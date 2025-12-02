defmodule Explorer.Chain.Import.Runner.Monad.DelegatorPositions do
  @moduledoc """
  Bulk imports `t:Explorer.Chain.Monad.DelegatorPosition.t/0`.
  """

  require Ecto.Query

  alias Ecto.{Changeset, Multi, Repo}
  alias Explorer.Chain.Import
  alias Explorer.Chain.Monad.DelegatorPosition
  alias Explorer.Prometheus.Instrumenter

  @behaviour Import.Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [DelegatorPosition.t()]

  @impl Import.Runner
  def ecto_schema_module, do: DelegatorPosition

  @impl Import.Runner
  def option_key, do: :monad_delegator_positions

  @impl Import.Runner
  @spec imported_table_row() :: %{:value_description => binary(), :value_type => binary()}
  def imported_table_row do
    %{
      value_type: "[#{ecto_schema_module()}.t()]",
      value_description: "List of `t:#{ecto_schema_module()}.t/0`s"
    }
  end

  @impl Import.Runner
  @spec run(Multi.t(), list(), map()) :: Multi.t()
  def run(multi, changes_list, %{timestamps: timestamps} = options) do
    insert_options =
      options
      |> Map.get(option_key(), %{})
      |> Map.take(~w(on_conflict timeout)a)
      |> Map.put_new(:timeout, @timeout)
      |> Map.put(:timestamps, timestamps)

    Multi.run(multi, :insert_monad_delegator_positions, fn repo, _ ->
      Instrumenter.block_import_stage_runner(
        fn -> upsert(repo, changes_list, insert_options) end,
        :block_referencing,
        :monad_delegator_positions,
        :monad_delegator_positions
      )
    end)
  end

  @impl Import.Runner
  def timeout, do: @timeout

  @spec upsert(Repo.t(), [map()], %{required(:timeout) => timeout(), required(:timestamps) => Import.timestamps()}) ::
          {:ok, [DelegatorPosition.t()]}
          | {:error, [Changeset.t()]}
  def upsert(repo, changes_list, %{timeout: timeout, timestamps: timestamps} = _options) when is_list(changes_list) do
    # Enforce DelegatorPosition ShareLocks order (see docs: sharelock.md)
    ordered_changes_list =
      Enum.sort_by(
        changes_list,
        &{&1.delegator_address_hash, &1.validator_id}
      )

    {:ok, inserted} =
      Import.insert_changes_list(
        repo,
        ordered_changes_list,
        for: DelegatorPosition,
        returning: true,
        timeout: timeout,
        timestamps: timestamps,
        conflict_target: [:delegator_address_hash, :validator_id],
        on_conflict:
          {:replace,
           [
             :stake,
             :unclaimed_rewards,
             :updated_at_block,
             :updated_at
           ]}
      )

    {:ok, inserted}
  end
end
