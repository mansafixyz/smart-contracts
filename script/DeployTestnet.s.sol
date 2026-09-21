// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolAuthority} from "../src/ProtocolAuthority.sol";
import {AccountRegistry} from "../src/AccountRegistry.sol";
import {AgentController} from "../src/AgentController.sol";
import {RequestLedger} from "../src/RequestLedger.sol";
import {DisclosureLog} from "../src/DisclosureLog.sol";
import {ConfidentialToken} from "../src/confidential/ConfidentialToken.sol";
import {StubTransferVerifier} from "../src/confidential/StubTransferVerifier.sol";
import {IConfidentialTransferVerifier} from "../src/confidential/IConfidentialTransferVerifier.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Bring-up deployment for the Robinhood Chain testnet, chain ID 46630.
///
/// There is no canonical USDG on the testnet, so this script mints its own
/// six-decimal stand-in, appoints the deployer as compliance authority, and
/// installs the do-nothing verifier. Every one of those shortcuts is
/// disqualifying on mainnet; the real path is script/Deploy.s.sol reading actual
/// addresses out of .env.
///
/// Run it with:
///   forge script script/DeployTestnet.s.sol:DeployTestnet \
///     --rpc-url robinhood_testnet --broadcast
contract DeployTestnet is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // Stand-in settlement asset, minted to the deployer so the deployment
        // can be driven end to end once it is up.
        MockERC20 usdg = new MockERC20("Global Dollar (Testnet)", "USDG", 6);
        usdg.mint(deployer, 1_000_000e6);

        ProtocolAuthority protocol = new ProtocolAuthority(deployer);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        AgentController agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        RequestLedger requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        DisclosureLog disclosures = new DisclosureLog(IAccountRegistry(address(registry)));

        StubTransferVerifier verifier = new StubTransferVerifier();
        ConfidentialToken confidential = new ConfidentialToken(
            IERC20(address(usdg)), IConfidentialTransferVerifier(address(verifier)), deployer
        );

        vm.stopBroadcast();

        console2.log("Deployer:           ", deployer);
        console2.log("USDG (mock):        ", address(usdg));
        console2.log("ProtocolAuthority:  ", address(protocol));
        console2.log("AccountRegistry:    ", address(registry));
        console2.log("AgentController:    ", address(agents));
        console2.log("RequestLedger:      ", address(requests));
        console2.log("DisclosureLog:      ", address(disclosures));
        console2.log("TransferVerifier:   ", address(verifier));
        console2.log("ConfidentialToken:  ", address(confidential));
    }
}
