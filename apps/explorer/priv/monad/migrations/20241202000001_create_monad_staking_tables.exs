defmodule Explorer.Repo.Monad.Migrations.CreateMonadStakingTables do
  @moduledoc """
  Creates tables for Monad staking data:
  - monad_staking_events: Stores staking events (delegate, undelegate, claim, withdraw)
  - monad_validators: Stores validator state snapshots
  """

  use Ecto.Migration

  def change do
    # Staking Events Table
    create table(:monad_staking_events, primary_key: false) do
      add(:block_number, :integer, null: false, primary_key: true)
      add(:log_index, :integer, null: false, primary_key: true)

      add(
        :transaction_hash,
        references(:transactions, column: :hash, type: :bytea, on_delete: :delete_all),
        null: false
      )

      add(
        :block_hash,
        references(:blocks, column: :hash, type: :bytea, on_delete: :delete_all),
        null: false
      )

      add(:event_type, :string, null: false)
      add(:validator_id, :integer, null: false)

      add(
        :delegator_address_hash,
        references(:addresses, column: :hash, type: :bytea, on_delete: :delete_all),
        null: false
      )

      add(:amount, :numeric, precision: 100, null: false)
      add(:epoch, :integer)
      add(:withdraw_id, :smallint)
      add(:activation_epoch, :integer)

      timestamps(null: false, type: :utc_datetime_usec)
    end

    create(index(:monad_staking_events, [:delegator_address_hash]))
    create(index(:monad_staking_events, [:validator_id]))
    create(index(:monad_staking_events, [:event_type]))
    create(index(:monad_staking_events, [:block_number]))
    create(index(:monad_staking_events, [:transaction_hash]))

    create(
      constraint(
        :monad_staking_events,
        :valid_event_type,
        check: "event_type IN ('claim', 'delegate', 'undelegate', 'withdraw', 'validator_rewarded')"
      )
    )

    # Validators Table
    create table(:monad_validators, primary_key: false) do
      add(:validator_id, :integer, null: false, primary_key: true)

      add(
        :auth_address_hash,
        references(:addresses, column: :hash, type: :bytea, on_delete: :delete_all),
        null: false
      )

      add(:total_stake, :numeric, precision: 100, null: false)
      add(:consensus_stake, :numeric, precision: 100)
      add(:commission, :numeric, precision: 100, null: false)
      add(:unclaimed_rewards, :numeric, precision: 100)
      add(:flags, :integer)
      add(:secp_pubkey, :bytea)
      add(:bls_pubkey, :bytea)
      add(:updated_at_block, :integer, null: false)

      timestamps(null: false, type: :utc_datetime_usec)
    end

    create(index(:monad_validators, [:auth_address_hash]))
    create(index(:monad_validators, [:updated_at_block]))
  end
end
