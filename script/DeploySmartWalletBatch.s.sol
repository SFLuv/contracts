// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

interface IAccountFactory {
    function getAddress(address owner, uint256 salt) external view returns (address);
    function createAccount(address owner, uint256 salt) external returns (address);
}

/**
 * @notice Deploy Citizen Wallet smart wallets in bounded batches.
 *
 * Input JSON:
 * {
 *   "owners": ["0x..."],
 *   "salts": ["0", "1"],
 *   "expected_addresses": ["0x..."]
 * }
 *
 * Env:
 *   ACCOUNT_FACTORY_ADDRESS = target Celo account factory
 *
 * Run:
 *   forge script script/DeploySmartWalletBatch.s.sol:DeploySmartWalletBatch \
 *     --sig "run(string,uint256,uint256,string)" /abs/input.json 0 50 /abs/output.json \
 *     --rpc-url https://forno.celo.org \
 *     --private-key $WALLET_DEPLOYER_PRIVATE_KEY --broadcast
 */
contract DeploySmartWalletBatch is Script {
    struct WalletBatchInput {
        address[] owners;
        uint256[] salts;
        address[] expected;
    }

    struct WalletBatchOutput {
        address[] owners;
        uint256[] salts;
        address[] accounts;
        bool[] alreadyDeployed;
    }

    // Reverts unless block.chainid matches EXPECTED_CHAIN_ID when that env var is
    // set, so a misconfigured RPC can never execute against the wrong chain.
    function _requireExpectedChain() internal view {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        require(expected == 0 || block.chainid == expected, "EXPECTED_CHAIN_ID mismatch: wrong chain");
    }

    function run(string memory inputPath, uint256 start, uint256 count, string memory outputPath) public {
        _requireExpectedChain();
        address factoryAddr = vm.envAddress("ACCOUNT_FACTORY_ADDRESS");
        IAccountFactory factory = IAccountFactory(factoryAddr);

        string memory raw = vm.readFile(inputPath);
        WalletBatchInput memory input = WalletBatchInput({
            owners: vm.parseJsonAddressArray(raw, ".owners"),
            salts: vm.parseJsonUintArray(raw, ".salts"),
            expected: vm.parseJsonAddressArray(raw, ".expected_addresses")
        });

        require(input.owners.length == input.salts.length, "owners/salts length mismatch");
        require(input.owners.length == input.expected.length, "owners/expected length mismatch");
        require(start <= input.owners.length, "start out of range");

        uint256 end = start + count;
        if (end > input.owners.length) end = input.owners.length;
        uint256 batchSize = end - start;
        require(batchSize > 0, "empty batch");

        WalletBatchOutput memory output = WalletBatchOutput({
            owners: new address[](batchSize),
            salts: new uint256[](batchSize),
            accounts: new address[](batchSize),
            alreadyDeployed: new bool[](batchSize)
        });

        _deployBatch(factory, input, output, start, end);
        _writeOutput(output, start, end, outputPath);

        console.log("Factory:", factoryAddr);
        console.log("Batch start:", start);
        console.log("Batch end:", end);
        console.log("Output:", outputPath);
    }

    function _deployBatch(
        IAccountFactory factory,
        WalletBatchInput memory input,
        WalletBatchOutput memory output,
        uint256 start,
        uint256 end
    ) internal {
        vm.startBroadcast();
        for (uint256 i = start; i < end; ++i) {
            uint256 j = i - start;
            (address account, bool exists) =
                _deployOrVerify(factory, input.owners[i], input.salts[i], input.expected[i]);
            output.owners[j] = input.owners[i];
            output.salts[j] = input.salts[i];
            output.accounts[j] = account;
            output.alreadyDeployed[j] = exists;
        }
        vm.stopBroadcast();
    }

    function _writeOutput(WalletBatchOutput memory output, uint256 start, uint256 end, string memory outputPath)
        internal
    {
        string memory objectKey = "deployed_smart_wallet_batch";
        vm.serializeUint(objectKey, "start", start);
        vm.serializeUint(objectKey, "end", end);
        vm.serializeAddress(objectKey, "owners", output.owners);
        vm.serializeUint(objectKey, "salts", output.salts);
        vm.serializeAddress(objectKey, "addresses", output.accounts);
        string memory json = vm.serializeBool(objectKey, "already_deployed", output.alreadyDeployed);
        vm.writeJson(json, outputPath);
    }

    function _deployOrVerify(IAccountFactory factory, address owner, uint256 salt, address expected)
        internal
        returns (address account, bool alreadyDeployed)
    {
        account = factory.getAddress(owner, salt);
        require(account == expected, "factory address mismatch");

        alreadyDeployed = account.code.length > 0;
        if (!alreadyDeployed) {
            address created = factory.createAccount(owner, salt);
            require(created == account, "created address mismatch");
        }
    }
}
