defmodule EthereumJSONRPC.Monad.Constants.Events do
  @moduledoc """
  Provides constant values for Monad staking event signatures.

  These are the keccak256 hashes of the event signatures emitted by
  the Monad staking precompile at address 0x1000.
  """

  # ClaimRewards(uint64 indexed validatorId, address indexed delegator, uint256 amount, uint64 epoch)
  @claim_rewards "0xcb607e6b63c89c95f6ae24ece9fe0e38a7971aa5ed956254f1df47490921727b"

  # ValidatorRewarded(uint64 indexed validatorId, address indexed from, uint256 amount, uint64 epoch)
  @validator_rewarded "0x3a420a01486b6b28d6ae89c51f5c3bde3e0e74eecbb646a0c481ccba3aae3754"

  # Delegate(uint64 indexed validatorId, address indexed delegator, uint256 amount, uint64 activationEpoch)
  @delegate "0xe4d4df1e1827dd28252fd5c3cd7ebccd3da6e0aa31f74c828f3c8542af49d840"

  # Undelegate(uint64 indexed validatorId, address indexed delegator, uint8 withdrawId, uint256 amount, uint64 activationEpoch)
  @undelegate "0x3e53c8b91747e1b72a44894db10f2a45fa632b161fdcdd3a17bd6be5482bac62"

  # Withdraw(uint64 indexed validatorId, address indexed delegator, uint8 withdrawId, uint256 amount, uint64 withdrawEpoch)
  @withdraw "0x63030e4238e1146c63f38f4ac81b2b23c8be28882e68b03f0887e50d0e9bb18f"

  # ValidatorCreated(uint64 indexed validatorId, address indexed authAddress, uint256 commission)
  @validator_created "0x6f8045cd38e512b8f12f6f02947c632e5f25af03aad132890ecf50015d97c1b2"

  # ValidatorStatusChanged(uint64 indexed validatorId, uint64 flags)
  @validator_status_changed "0xc95966754e882e03faffaf164883d98986dda088d09471a35f9e55363daf0c53"

  # CommissionChanged(uint64 indexed validatorId, uint256 oldCommission, uint256 newCommission)
  @commission_changed "0xd1698d3454c5b5384b70aaae33f1704af7c7e055f0c75503ba3146dc28995920"

  # EpochChanged(uint64 oldEpoch, uint64 newEpoch)
  @epoch_changed "0x4fae4dbe0ed659e8ce6637e3c273cd8e4d3bf029b9379a9e8b3f3f27dbef809b"

  # Primary staking events (used for staking rewards tracking)
  @spec claim_rewards() :: String.t()
  def claim_rewards, do: @claim_rewards

  @spec validator_rewarded() :: String.t()
  def validator_rewarded, do: @validator_rewarded

  @spec delegate() :: String.t()
  def delegate, do: @delegate

  @spec undelegate() :: String.t()
  def undelegate, do: @undelegate

  @spec withdraw() :: String.t()
  def withdraw, do: @withdraw

  # Validator lifecycle events
  @spec validator_created() :: String.t()
  def validator_created, do: @validator_created

  @spec validator_status_changed() :: String.t()
  def validator_status_changed, do: @validator_status_changed

  @spec commission_changed() :: String.t()
  def commission_changed, do: @commission_changed

  @spec epoch_changed() :: String.t()
  def epoch_changed, do: @epoch_changed

  @doc """
  Returns all primary staking event signatures for log filtering.

  These are the 5 main events used for tracking staking activity:
  - ClaimRewards
  - ValidatorRewarded
  - Delegate
  - Undelegate
  - Withdraw
  """
  @spec staking_event_signatures() :: [String.t()]
  def staking_event_signatures do
    [
      @claim_rewards,
      @validator_rewarded,
      @delegate,
      @undelegate,
      @withdraw
    ]
  end

  @doc """
  Returns all event signatures including validator lifecycle events.
  """
  @spec all_signatures() :: [String.t()]
  def all_signatures do
    [
      @claim_rewards,
      @validator_rewarded,
      @delegate,
      @undelegate,
      @withdraw,
      @validator_created,
      @validator_status_changed,
      @commission_changed,
      @epoch_changed
    ]
  end

  @doc """
  Maps event signature to event type atom.
  """
  @spec signature_to_type(String.t()) :: atom() | nil
  def signature_to_type(signature) do
    %{
      @claim_rewards => :claim,
      @validator_rewarded => :validator_rewarded,
      @delegate => :delegate,
      @undelegate => :undelegate,
      @withdraw => :withdraw,
      @validator_created => :validator_created,
      @validator_status_changed => :validator_status_changed,
      @commission_changed => :commission_changed,
      @epoch_changed => :epoch_changed
    }
    |> Map.get(signature)
  end
end
