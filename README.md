# Daemon (DAEMON)

A plain, fixed-supply ERC-20 community token for the people who keep the IMD daemon running.

| Parameter    | Value                                            |
|--------------|--------------------------------------------------|
| Name         | `Daemon`                                         |
| Symbol       | `DAEMON`                                         |
| Decimals     | `18`                                             |
| Total supply | `1,000,000,000` tokens = `1000000000000000000000000000` minor units (`1e27`) |
| Minted to    | `msg.sender` of the constructor, once, in full   |
| Contract     | `src/DaemonToken.sol` (`DaemonToken`)            |
| Constructor  | no arguments                                     |

No fees, no minting after launch, no owner powers, no transfer rules. That is the whole design.

## Layout

```
foundry.toml                  compiler pinned to solc 0.8.26, bytecode_hash = "none", ffi off
remappings.txt                forge-std/=lib/forge-std/src/
src/DaemonToken.sol           the token
script/DeployDaemonToken.s.sol  reviewable deploy script (deploy() is tested directly)
test/DaemonToken.t.sol        unit, failure, fuzz and launch-floor mirror tests
lib/forge-std/                forge-std v1.9.6, vendored as ordinary files (no submodule)
```

## Build and test

```
forge build
forge test
forge fmt --check
```

All three were run locally with Foundry 1.8.3 and solc 0.8.26. The verifier re-runs the tests in
any order, in parallel, with an empty environment and no network. Nothing in `test/` or `script/`
reads an environment variable, touches the filesystem, or forks a chain.

## What the contract does

`DaemonToken` is a self-contained ERC-20 (not inherited from a library, so the audited surface is
one file). It exposes exactly the standard surface:

- `name()`, `symbol()`, `decimals()`, `totalSupply()`, `balanceOf(address)`, `allowance(address,address)`
- `transfer(address,uint256)`, `approve(address,uint256)`, `transferFrom(address,address,uint256)`
- `Transfer` and `Approval` events, plus the public constant `TOTAL_SUPPLY`

Semantics match OpenZeppelin v5 ERC-20:

- transfers move exactly `amount`, with no tax, burn, reflection or rounding;
- insufficient balance or allowance reverts with a typed error carrying the offending values;
- the zero address is rejected as sender, receiver, approver and spender;
- an allowance of `type(uint256).max` is treated as unlimited and is never decremented;
- `totalSupply()` is a compile-time constant and cannot change after deployment.

There is no `owner()`, no `mint`, no `burn`, no `pause`, no blocklist, no `permit`, no proxy, no
`receive`/`fallback` (ETH sent to the contract reverts), no external calls, and the runtime bytecode
contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` (a test scans for them).

## Assumptions

1. **The deployer is the distributor of the supply.** The constructor mints everything to
   `msg.sender`. Under the IMD custom-token launch that sender is `ProjectFactory` (it deploys the
   token with CREATE2 and then moves the swarm's ten percent to the MerkleDistributor, seeds the
   pool, and forwards the remainder to `economics.remainderTo`). Outside that flow, whichever key or
   contract sends the creation transaction holds every token until it transfers them.
2. **No exemptions are needed.** Because ordinary transfers already move exactly what they say,
   the launch flows (factory to distributor, distributor to claimant, factory to PoolManager, trader
   to and from PoolManager) all arrive whole without the token knowing any launch address. The
   constructor therefore takes no `$factory`, `$poolManager` or `$launchNumber` argument.
3. **Supply can only shrink by accident, never grow.** There is no burn function. Tokens sent to an
   address nobody controls are simply stuck; `transfer(address(0), ...)` is rejected so the common
   mistake is caught.
4. **The ERC-20 approve race is accepted as standard.** `approve` overwrites the previous value;
   wallets that care should set the allowance to zero before changing it, as with every standard
   ERC-20. No `increaseAllowance`/`decreaseAllowance` was added, matching OpenZeppelin v5 which also
   removed them.
5. **The compiler is solc 0.8.26, EVM `cancun`, optimizer on at 200 runs**, with
   `bytecode_hash = "none"` and `cbor_metadata = false` so the deployed bytes are reproducible and
   carry no metadata hash. The launch compares deployed bytes under this setting.

## Deployment parameters

The token has **no constructor arguments** and **no post-deployment configuration**. For the IMD
launch manifest (`kind: "custom_token"`):

```
token.contract        DaemonToken
token.name            Daemon
token.symbol          DAEMON
token.decimals        18
token.constructorArgs []
token.totalSupply     1000000000000000000000000000
contracts             []            (no application contracts)
```

`pool`, `economics` (`poolBps`, `initialMarketCapWei`, `remainderTo`) and the paired currency come
from the job and are copied into the manifest by the manifest node, not decided here. They do not
affect the token's bytecode.

Stand-alone deployment (testnet, local anvil, or manual review) uses the script, with the signer
chosen by forge flags and never read from the repository:

```
forge script script/DeployDaemonToken.s.sol:DeployDaemonToken \
  --rpc-url <RPC_URL> --account <KEYSTORE_ACCOUNT> --broadcast
```

The broadcaster receives the full supply. This repository never holds a key, never reads one, and
this task did not broadcast anything.

## Operational responsibilities

Because the token has no owner, there is nothing to administer after deployment. The remaining
responsibilities sit with the people around it, not with the contract:

- **The deployer / factory** must forward the supply correctly. The token cannot claw anything back,
  so a wrong recipient address is final.
- **Explorer verification** after deployment (`forge verify-contract` with solc 0.8.26, optimizer
  200 runs, EVM `cancun`, `bytecode_hash = none`, `cbor_metadata = false`) belongs to the network's
  deployer. Unverified contracts look like scams; verified source lets holders check for themselves
  that there is no owner.
- **Key hygiene** for whichever wallet ends up holding the requester's remainder. The contract
  offers no recovery, freeze or pause, so a compromised holder key loses only that holder's
  balance, and nobody can help them.
- **Independent review before release.** Tests passing is not an audit. Anything that will hold
  other people's funds (pools, distributors, vesting built on top of DAEMON) needs a separate
  adversarial review by an independent contributor.
- **Nothing to upgrade, pause, or rotate.** If the community ever wants different token rules, that
  is a new contract and a migration, by design.

## Security checklist (eth-security reference)

Walked against `src/DaemonToken.sol`:

| Item | Status |
|------|--------|
| Access control | No privileged functions exist, so none to restrict. Tested: 22 common admin selectors revert from both a stranger and the deployer. |
| Pausable tradeoff | Not pausable. No single key can freeze holders. |
| Reentrancy | No external calls; state is updated before the only events are emitted. |
| Decimals | Fixed at 18; supply constant derived with `10 ** 18`. |
| Integer math | Only additions/subtractions guarded by explicit balance and allowance checks. The `unchecked` block is justified in a comment: the sum of balances is the constant supply. |
| Return values | `transfer`, `approve`, `transferFrom` always return `true` or revert. |
| Input validation | Zero address rejected everywhere it matters; zero amounts allowed (standard). |
| Events | Every balance or allowance change emits `Transfer` / `Approval`. |
| Infinite approvals | Supported per ERC-20 convention; the risk is the approver's, documented above. |
| Fee-on-transfer | Not applicable: transfers are exact (fuzz-tested). |
| Proxies / delegatecall / selfdestruct | None; bytecode scanned in a test. |
| Oracles, MEV, signatures | Not applicable: no price logic, no swaps, no signatures. |
| Automated analysis | `forge test` with 256 fuzz runs per fuzz test ran. Slither and Mythril were not available in this task's environment and did not run. |
| Explorer verification | Open item for the network's deployer (see above). |

## Licence

MIT. `lib/forge-std` is Apache-2.0 / MIT (see the licence files inside it).
