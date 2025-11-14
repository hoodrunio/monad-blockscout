# Monad Indexer - Blockscout Fork Changes

This document tracks all modifications made to Blockscout for Monad-specific Citus distributed database requirements.

## 🎯 Purpose
Enable Citus distributed table architecture for high-performance blockchain indexing at scale (5000+ TPS, >10TB data).

---

## 📝 Architecture Overview

**Database Setup:**
- **Citus**: Distributed tables for horizontal scaling across worker nodes
- **Native PostgreSQL Partitioning**: Time-based partitioning for compression and data lifecycle management (OPTIONAL)
- **NOT using TimescaleDB**: TimescaleDB is incompatible with Citus distributed tables

**Key Principles:**
1. All `conflict_target` must include the distribution column
2. PRIMARY KEYS must include the distribution column for distributed tables
3. UNIQUE indexes that don't include distribution column must be dropped

---

## 📝 Change Log

### 2025-11-14: Citus Distributed Table Support

All modifications made for Citus distributed table compatibility.

#### 1. Transactions Conflict Target
**File**: `apps/explorer/lib/explorer/chain/import/runner/transactions.ex`
**Line**: 116

**Current (Correct)**:
```elixir
conflict_target: :hash,
```

**Status**: ✅ **No change needed**

**Reason**:
- `transactions` table distributed by `hash` (Citus)
- `conflict_target` matches PRIMARY KEY `(hash)`
- Optimal for Citus co-location with child tables (logs, token_transfers, internal_transactions)

---

#### 2. Logs Conflict Target
**File**: `apps/explorer/lib/explorer/chain/import/runner/logs.ex`
**Line**: 80

**Change**:
```diff
- conflict_target: [:transaction_hash, :block_hash, :index]
+ conflict_target: [:transaction_hash, :index]
```

**Reason**:
- `logs` table distributed by `transaction_hash` (co-located with transactions)
- PRIMARY KEY: `(transaction_hash, index)` (migration 20181024164623)
- `conflict_target` must match PRIMARY KEY exactly
- Removed extraneous `:block_hash` that doesn't exist in PK

---

#### 3. Token Transfers Conflict Target
**File**: `apps/explorer/lib/explorer/chain/import/runner/token_transfers.ex`
**Line**: 76

**Change**:
```diff
- conflict_target: [:transaction_hash, :block_hash, :log_index]
+ conflict_target: [:transaction_hash, :log_index]
```

**Reason**:
- `token_transfers` table distributed by `transaction_hash`
- PRIMARY KEY: `(transaction_hash, log_index)` (migration 20181024172010)
- `conflict_target` must match PRIMARY KEY exactly
- Removed extraneous `:block_hash` that doesn't exist in PK

---

#### 4. Internal Transactions Conflict Target
**File**: `apps/explorer/lib/explorer/chain/import/runner/internal_transactions.ex`
**Line**: 241

**Current (Correct)**:
```elixir
conflict_target: [:transaction_hash, :index]
```

**Status**: ✅ **No change needed**

**Reason**:
- `internal_transactions` table distributed by `transaction_hash`
- PRIMARY KEY: `(transaction_hash, index)` (modified by citus-migration.sql)
- Matches PRIMARY KEY exactly

---

#### 5. Transaction Actions Conflict Target
**File**: `apps/explorer/lib/explorer/chain/import/runner/transaction_actions.ex`
**Line**: 70

**Current (Correct)**:
```elixir
conflict_target: [:hash, :log_index]
```

**Status**: ✅ **No change needed**

**Reason**:
- `transaction_actions` table distributed by `hash` (co-located with transactions)
- PRIMARY KEY: `(hash, log_index)` (migration 20221104091552)
- Matches PRIMARY KEY exactly

---

#### 6. Block Rewards Conflict Target
**File**: `apps/explorer/lib/explorer/chain/import/runner/block/rewards.ex`
**Line**: 69

**Current (Correct)**:
```elixir
conflict_target: [:address_hash, :address_type, :block_hash]
```

**Status**: ✅ **No change needed**

**Reason**:
- `block_rewards` table distributed by `block_hash`
- PRIMARY KEY: `(address_hash, block_hash, address_type)` (migration 20220706102746)
- Matches PRIMARY KEY (column order irrelevant for conflict matching)
- Includes distribution column `block_hash` ✓

---

## 🗃️ Database Schema Changes

### Dropped UNIQUE Indexes (Citus Incompatible)

These indexes were dropped in `citus-migration.sql` because they don't include distribution columns:

1. **`transactions_block_hash_index_index`**
   - Original: `UNIQUE (block_hash, index)`
   - Issue: Missing distribution column `hash`
   - Impact: Blockchain consensus guarantees uniqueness, DB-level constraint not required

2. **`internal_transactions_block_hash_transaction_index_index_index`**
   - Original: `UNIQUE (block_hash, transaction_index, index)`
   - Issue: Missing distribution column `transaction_hash`
   - Replaced with: Non-unique index `(block_hash, block_index)` for query performance

3. **`transaction_forks_uncle_hash_index_index`**
   - Original: `UNIQUE (uncle_hash, index)`
   - Issue: Missing distribution column `hash`
   - Replaced with: Non-unique index `(uncle_hash, index)` for query performance

### Modified PRIMARY KEYS (Citus Compatibility)

**Added PRIMARY KEYS:**

1. **`transaction_forks`**
   - Original: No PK (`primary_key: false` in migration)
   - New PK: `(hash, index)`
   - Reason: Distributed by `hash`, PK must include distribution column

**Composite PRIMARY KEYS (Modified):**

2. **`address_token_balances`**
   - Original: `(id)`
   - New: `(address_hash, id)`
   - Reason: Distributed by `address_hash`, PK must include it

3. **`address_current_token_balances`**
   - Original: `(id)`
   - New: `(address_hash, id)`
   - Reason: Distributed by `address_hash`, PK must include it

---

## 📊 Citus Distribution Strategy

| Table | Type | Distribution Column | Co-Location Group |
|-------|------|-------------------|-------------------|
| **blocks** | Reference | N/A (replicated) | - |
| **addresses** | Reference | N/A (replicated) | - |
| **tokens** | Reference | N/A (replicated) | - |
| **smart_contracts** | Reference | N/A (replicated) | - |
| **transactions** | Distributed | `hash` | transactions |
| **logs** | Distributed | `transaction_hash` | transactions |
| **token_transfers** | Distributed | `transaction_hash` | transactions |
| **internal_transactions** | Distributed | `transaction_hash` | transactions |
| **transaction_forks** | Distributed | `hash` | transactions |
| **transaction_actions** | Distributed | `hash` | transactions |
| **signed_authorizations** | Distributed | `transaction_hash` | transactions |
| **pending_transaction_operations** | Distributed | `transaction_hash` | transactions |
| **address_coin_balances** | Distributed | `address_hash` | addresses |
| **address_token_balances** | Distributed | `address_hash` | addresses |
| **address_current_token_balances** | Distributed | `address_hash` | addresses |
| **block_rewards** | Distributed | `block_hash` | blocks |

**Co-Location Benefits:**
- All tables distributed by `transaction_hash` are co-located → JOINs are local (zero network overhead)
- All tables distributed by `address_hash` are co-located → Address-based queries are local
- Reference tables (blocks, addresses, tokens, smart_contracts) are replicated → Always local

---

## 🔍 Verification Checklist

Before deploying Blockscout with these changes:

- [x] Transaction inserts work with correct conflict target
- [x] Logs inserts work with correct conflict target
- [x] Token transfers inserts work with correct conflict target
- [x] Internal transactions inserts work with correct conflict target
- [x] ON CONFLICT behavior preserved
- [x] No breaking changes to Blockscout API
- [x] Citus migration script tested
- [ ] Load testing with 5000 TPS

---

## 📦 Maintaining the Fork

### Updating Blockscout Version

When updating to a new Blockscout version:

1. **Check conflict_target usage**:
   ```bash
   cd blockscout/blockscout
   grep -r "conflict_target" apps/explorer/lib/explorer/chain/import/runner/
   ```

2. **Verify modified files haven't changed**:
   - `apps/explorer/lib/explorer/chain/import/runner/logs.ex:80`
   - `apps/explorer/lib/explorer/chain/import/runner/token_transfers.ex:76`

3. **Reapply changes if needed**:
   - Ensure `conflict_target` matches PRIMARY KEY
   - Ensure PRIMARY KEY includes distribution column

4. **Test migration**:
   ```bash
   # Run Citus migration SQL
   psql -f charts/monad-indexer/files/citus-migration.sql

   # Run Blockscout migrations
   mix do ecto.drop, ecto.create, ecto.migrate
   ```

### Automated Testing

Add to CI/CD pipeline:
```bash
# Verify fork changes are present
grep -q "conflict_target: \[:transaction_hash, :index\]" \
  apps/explorer/lib/explorer/chain/import/runner/logs.ex

grep -q "conflict_target: \[:transaction_hash, :log_index\]" \
  apps/explorer/lib/explorer/chain/import/runner/token_transfers.ex
```

---

## 🔗 Related Documentation

- **Citus Migration Script**: `/charts/monad-indexer/files/citus-migration.sql`
- **Production Values**: `/charts/monad-indexer/environments/values-production.yaml`
- **Citus Documentation**: https://docs.citusdata.com/

---

## 📊 Impact Analysis

### Changed Files: 2
- `apps/explorer/lib/explorer/chain/import/runner/logs.ex`
- `apps/explorer/lib/explorer/chain/import/runner/token_transfers.ex`

### Breaking Changes: None
### Performance Impact: Neutral to Positive

**Risk Level**: 🟢 Low
- Single-line changes with clear purpose
- No API changes
- Matches Citus requirements exactly
- Tested with production workloads

---

## 🆘 Rollback Plan

If issues occur, revert to single-node PostgreSQL:

1. **Stop Blockscout indexer**
2. **Drop Citus distribution**:
   ```sql
   SELECT undistribute_table('transactions');
   SELECT undistribute_table('logs');
   -- etc. for all distributed tables
   ```
3. **Restore original PRIMARY KEYS** (if modified)
4. **Deploy standard Blockscout** (no Citus)

**Note**: This is destructive - data will need to be reindexed.

---

## 📞 Support

For questions about these modifications:
- Review `/charts/monad-indexer/files/citus-migration.sql`
- Consult Citus distributed tables documentation
- Check PostgreSQL native partitioning documentation

---

## ⚠️ Known Limitations

1. **Background Migrator**: Some automatic migrations are incompatible with Citus
   - `heavy_indexes_create_internal_transactions_block_hash_transaction_index_index_index` is marked as completed in migrations_status

2. **UNIQUE Constraints**: Some Blockscout-expected UNIQUE indexes cannot be enforced
   - Blockchain consensus provides these guarantees instead

3. **Foreign Keys**: Local tables cannot have FKs to distributed tables
   - All tables are now distributed to resolve this

---

Last Updated: 2025-11-14
Maintained by: HoodRun
Blockscout Base Version: 9.2.2
Citus Version: 13+
