defmodule Explorer.Chain.Import.Runner.Monad.Validators do
  @moduledoc """
  Bulk imports `t:Explorer.Chain.Monad.Validator.t/0`.
  """

  require Ecto.Query

  alias Ecto.{Changeset, Multi, Repo}
  alias Explorer.Chain.Import
  alias Explorer.Chain.Monad.Validator
  alias Explorer.Prometheus.Instrumenter

  @behaviour Import.Runner

  # milliseconds
  @timeout 60_000

  @type imported :: [Validator.t()]

  @impl Import.Runner
  def ecto_schema_module, do: Validator

  @impl Import.Runner
  def option_key, do: :monad_validators

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

    Multi.run(multi, :insert_monad_validators, fn repo, _ ->
      Instrumenter.block_import_stage_runner(
        fn -> upsert(repo, changes_list, insert_options) end,
        :block_referencing,
        :monad_validators,
        :monad_validators
      )
    end)
  end

  @impl Import.Runner
  def timeout, do: @timeout

  @spec upsert(Repo.t(), [map()], %{required(:timeout) => timeout(), required(:timestamps) => Import.timestamps()}) ::
          {:ok, [Validator.t()]}
          | {:error, [Changeset.t()]}
  def upsert(repo, changes_list, %{timeout: timeout, timestamps: timestamps} = _options) when is_list(changes_list) do
    # Enforce Validator ShareLocks order (see docs: sharelock.md)
    ordered_changes_list =
      Enum.sort_by(
        changes_list,
        & &1.validator_id
      )

    {:ok, inserted} =
      Import.insert_changes_list(
        repo,
        ordered_changes_list,
        for: Validator,
        returning: true,
        timeout: timeout,
        timestamps: timestamps,
        conflict_target: [:validator_id],
        on_conflict:
          {:replace,
           [
             :auth_address_hash,
             :total_stake,
             :consensus_stake,
             :commission,
             :unclaimed_rewards,
             :flags,
             :secp_pubkey,
             :bls_pubkey,
             :updated_at_block,
             :updated_at
           ]}
      )

    {:ok, inserted}
  end
end
