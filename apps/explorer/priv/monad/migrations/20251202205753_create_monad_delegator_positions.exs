defmodule Explorer.Repo.Monad.Migrations.CreateMonadDelegatorPositions do
  use Ecto.Migration

  def change do
    create table(:monad_delegator_positions, primary_key: false) do
      add(:delegator_address_hash, :bytea, null: false, primary_key: true)
      add(:validator_id, :integer, null: false, primary_key: true)
      add(:stake, :numeric, precision: 100, null: false)
      add(:unclaimed_rewards, :numeric, precision: 100)
      add(:updated_at_block, :integer, null: false)

      timestamps(null: false, type: :utc_datetime_usec)
    end

    create(index(:monad_delegator_positions, [:delegator_address_hash]))
    create(index(:monad_delegator_positions, [:validator_id]))
    create(index(:monad_delegator_positions, [:updated_at_block]))
  end
end
