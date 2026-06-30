// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

interface IAccessControlLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
}

interface IWrapperLike {
    function underlying() external view returns (address);
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @notice Local test-environment setup for the Berachain -> Celo migration.
 *
 *         Grants every migration-relevant AccessControl role on a SFLUV proxy to
 *         the default anvil account (key index 0) on a LOCAL FORK, so the whole
 *         migration can be exercised with the well-known anvil key instead of the
 *         real governance / deployer / distributor keys ("live ammo" in .env).
 *
 *         The anvil account must already hold DEFAULT_ADMIN_ROLE on the proxy.
 *         The tmux harness seeds that one role by writing the AccessControl
 *         storage slot directly on the fork (anvil_setStorageAt) — the persistent
 *         equivalent of pranking the proxy's admin. From there this script, run as
 *         that account, grants itself the remaining roles with real transactions:
 *           - DEFAULT_ADMIN_ROLE (seeded) : UUPS upgrade (Bera lock), sweep, role admin
 *           - MINTER_ROLE   : depositFor (Celo distribution)
 *           - REDEEMER_ROLE : withdrawTo (unwrap testing)
 *           - MIGRATOR_ROLE : SFLUVv2_1 migrate() path
 *         For each role it first grants itself the role's admin role (so it is
 *         authorized to grant the role), then the role. Roles a given contract
 *         does not define are still settable and simply stay inert.
 *
 *         Idempotent: every grant is skipped when already held, so reruns are safe.
 *
 * Env:
 *   SFLUV_PROXY = SFLUV proxy on the target (forked) chain.
 *   TEST_ADMIN  = (optional) account to empower. Default: anvil key-0 0xf39F...2266.
 *                 Must match the broadcasting key (--private-key) and must already
 *                 hold DEFAULT_ADMIN_ROLE (seeded by the harness).
 *
 * Run (after the DEFAULT_ADMIN_ROLE seed):
 *   SFLUV_PROXY=$OLD_TOKEN forge script script/SetupMigrationTestEnv.s.sol:SetupMigrationTestEnv \
 *     --rpc-url $OLD_CHAIN_RPC --broadcast \
 *     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
 */
contract SetupMigrationTestEnv is Script {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // anvil account #0 (default mnemonic), the universal local test signer.
    address internal constant DEFAULT_ANVIL_ACCOUNT_0 =
        0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() public {
        address proxy = vm.envAddress("SFLUV_PROXY");
        address acct = vm.envOr("TEST_ADMIN", DEFAULT_ANVIL_ACCOUNT_0);
        IAccessControlLike acl = IAccessControlLike(proxy);

        require(
            acl.hasRole(DEFAULT_ADMIN_ROLE, acct),
            "test account lacks DEFAULT_ADMIN_ROLE; seed it first (tmux migration-roles bootstrap)"
        );

        string[3] memory names = ["MINTER", "REDEEMER", "MIGRATOR"];
        bytes32[3] memory roles = [keccak256("MINTER"), keccak256("REDEEMER"), keccak256("MIGRATOR")];

        console.log("Setup migration test env (local fork only)");
        console.log("  proxy:", proxy);
        console.log("  admin:", acct);

        // Backing token the proxy wraps; the distributor must approve the proxy
        // to pull it during depositFor (Celo distribution). Funding the balance
        // itself is done by the harness (fork balance write).
        address backing = IWrapperLike(proxy).underlying();

        vm.startBroadcast();
        for (uint256 i = 0; i < roles.length; i++) {
            bytes32 adminRole = acl.getRoleAdmin(roles[i]);
            // Authorize the account to administer this role, then grant the role.
            if (!acl.hasRole(adminRole, acct)) {
                acl.grantRole(adminRole, acct);
            }
            if (!acl.hasRole(roles[i], acct)) {
                acl.grantRole(roles[i], acct);
            }
            console.log(string.concat("  granted ", names[i]));
        }
        if (backing != address(0)) {
            IERC20Like(backing).approve(proxy, type(uint256).max);
            console.log("  approved backing", backing);
        }
        vm.stopBroadcast();

        console.log("All migration roles granted to test admin.");
    }
}
