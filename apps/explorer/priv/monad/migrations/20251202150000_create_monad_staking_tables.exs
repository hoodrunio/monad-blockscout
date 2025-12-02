defmodule Explorer.Repo.Monad.Migrations.CreateMonadStakingTables do
  @moduledoc """
  Creates tables for Monad staking data:
  - monad_staking_events: Stores staking events (delegate, undelegate, claim, withdraw)
  - monad_validators: Stores validator state snapshots

  Note: Foreign key constraints are intentionally omitted for Citus compatibility.
  In Citus distributed PostgreSQL, foreign keys from local/distributed tables to
  reference tables must be added after the table is distributed.
  See: citus-migration.sql for FK setup after distribution.
  """

  use Ecto.Migration

  def change do
    # Staking Events Table
    # Note: No FK constraints - Citus requires tables to be distributed first
    create table(:monad_staking_events, primary_key: false) do
      add(:block_number, :integer, null: false, primary_key: true)
      add(:log_index, :integer, null: false, primary_key: true)

      # transaction_hash - FK added by citus-migration.sql after distribution
      add(:transaction_hash, :bytea, null: false)

      # block_hash - FK added by citus-migration.sql after distribution
      add(:block_hash, :bytea, null: false)

      add(:event_type, :string, null: false)
      add(:validator_id, :integer, null: false)

      # delegator_address_hash - FK added by citus-migration.sql after distribution
      add(:delegator_address_hash, :bytea, null: false)

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
    # Note: No FK constraints - Citus requires tables to be distributed first
    # auth_address_hash FK is added by citus-migration.sql after distribution
    # The validator fetcher creates addresses during import to satisfy the FK
    create table(:monad_validators, primary_key: false) do
      add(:validator_id, :integer, null: false, primary_key: true)

      # auth_address_hash - FK added by citus-migration.sql after distribution
      add(:auth_address_hash, :bytea, null: false)

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
