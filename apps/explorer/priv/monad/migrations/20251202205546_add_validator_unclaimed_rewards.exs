defmodule Explorer.Repo.Monad.Migrations.AddValidatorUnclaimedRewards do
  use Ecto.Migration

  def change do
    alter table(:monad_validators) do
      # Validator operator's personal unclaimed rewards (from getDelegator call with auth_address)
      add(:validator_unclaimed_rewards, :numeric, precision: 100)
    end
  end
end
