defmodule EthereumJSONRPC.Monad.Constants.Contracts do
  @moduledoc """
  Provides constant values for Monad contract addresses and ABIs.

  The staking precompile at address 0x1000 allows delegators and validators
  to interact with the Monad staking system.
  """

  @staking_precompile "0x0000000000000000000000000000000000001000"

  @doc """
  Returns the Monad staking precompile address.
  """
  @spec staking_precompile() :: String.t()
  def staking_precompile, do: @staking_precompile

  @doc """
  Returns the ABI for getValidator(uint64) function.

  Returns validator information including auth address, flags, stake,
  commission, unclaimed rewards, and public keys.
  """
  @spec get_validator_abi() :: [map()]
  def get_validator_abi do
    [
      %{
        "type" => "function",
        "name" => "getValidator",
        "inputs" => [
          %{"name" => "validatorId", "type" => "uint64", "internalType" => "uint64"}
        ],
        "outputs" => [
          %{"name" => "authAddress", "type" => "address", "internalType" => "address"},
          %{"name" => "flags", "type" => "uint64", "internalType" => "uint64"},
          %{"name" => "stake", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "accRewardPerToken", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "commission", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "unclaimedRewards", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "consensusStake", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "consensusCommission", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "snapshotStake", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "snapshotCommission", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "secpPubkey", "type" => "bytes", "internalType" => "bytes"},
          %{"name" => "blsPubkey", "type" => "bytes", "internalType" => "bytes"}
        ],
        "stateMutability" => "view"
      }
    ]
  end

  @doc """
  Returns the ABI for getDelegator(uint64, address) function.

  Returns delegator information including stake, rewards, and pending changes.
  """
  @spec get_delegator_abi() :: [map()]
  def get_delegator_abi do
    [
      %{
        "type" => "function",
        "name" => "getDelegator",
        "inputs" => [
          %{"name" => "validatorId", "type" => "uint64", "internalType" => "uint64"},
          %{"name" => "delegator", "type" => "address", "internalType" => "address"}
        ],
        "outputs" => [
          %{"name" => "stake", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "accRewardPerToken", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "unclaimedRewards", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "deltaStake", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "nextDeltaStake", "type" => "uint256", "internalType" => "uint256"},
          %{"name" => "deltaEpoch", "type" => "uint64", "internalType" => "uint64"},
          %{"name" => "nextDeltaEpoch", "type" => "uint64", "internalType" => "uint64"}
        ],
        "stateMutability" => "nonpayable"
      }
    ]
  end

  @doc """
  Returns the ABI for getEpoch() function.

  Returns current epoch number and whether we're in the epoch delay period.
  """
  @spec get_epoch_abi() :: [map()]
  def get_epoch_abi do
    [
      %{
        "type" => "function",
        "name" => "getEpoch",
        "inputs" => [],
        "outputs" => [
          %{"name" => "epoch", "type" => "uint64", "internalType" => "uint64"},
          %{"name" => "inEpochDelayPeriod", "type" => "bool", "internalType" => "bool"}
        ],
        "stateMutability" => "nonpayable"
      }
    ]
  end

  @doc """
  Returns the ABI for getExecutionValidatorSet(uint32) function.

  Returns paginated list of validator IDs in the execution validator set.
  """
  @spec get_execution_validator_set_abi() :: [map()]
  def get_execution_validator_set_abi do
    [
      %{
        "type" => "function",
        "name" => "getExecutionValidatorSet",
        "inputs" => [
          %{"name" => "startIndex", "type" => "uint32", "internalType" => "uint32"}
        ],
        "outputs" => [
          %{"name" => "isDone", "type" => "bool", "internalType" => "bool"},
          %{"name" => "nextIndex", "type" => "uint32", "internalType" => "uint32"},
          %{"name" => "valIds", "type" => "uint64[]", "internalType" => "uint64[]"}
        ],
        "stateMutability" => "nonpayable"
      }
    ]
  end

  @doc """
  Returns the function selector for getValidator(uint64).
  """
  @spec get_validator_selector() :: String.t()
  def get_validator_selector, do: "0x2b6d639a"

  @doc """
  Returns the function selector for getDelegator(uint64, address).
  """
  @spec get_delegator_selector() :: String.t()
  def get_delegator_selector, do: "0x573c1ce0"

  @doc """
  Returns the function selector for getEpoch().
  """
  @spec get_epoch_selector() :: String.t()
  def get_epoch_selector, do: "0x757991a8"

  @doc """
  Returns the function selector for getExecutionValidatorSet(uint32).
  """
  @spec get_execution_validator_set_selector() :: String.t()
  def get_execution_validator_set_selector, do: "0x7cb074df"
end
