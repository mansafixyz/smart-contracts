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
import {StakingVault} from "../src/fees/StakingVault.sol";
import {FeeSchedule} from "../src/fees/FeeSchedule.sol";
import {IProtocolAuthority} from "../src/interfaces/IProtocolAuthority.sol";
import {IAccountRegistry} from "../src/interfaces/IAccountRegistry.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @notice Brings the protocol up on Robinhood Chain.
///
/// Everything it needs comes from the environment (see .env.example):
///   PRIVATE_KEY                deployer; needs ETH for gas
///   COMPLIANCE_AUTHORITY       the address that will attest KYC outcomes
///   USDG_ADDRESS               settlement asset the ConfidentialToken wraps
///   TRANSFER_VERIFIER_ADDRESS  Groth16 verifier. Left unset, a
///                              StubTransferVerifier goes in for bring-up and
///                              checks absolutely nothing.
///
/// Run it with:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url robinhood --broadcast --verify --verifier blockscout
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address compliance = vm.envAddress("COMPLIANCE_AUTHORITY");
        address usdg = vm.envAddress("USDG_ADDRESS");
        address verifierAddr = vm.envOr("TRANSFER_VERIFIER_ADDRESS", address(0));

        vm.startBroadcast(pk);

        ProtocolAuthority protocol = new ProtocolAuthority(compliance);
        AccountRegistry registry = new AccountRegistry(IProtocolAuthority(address(protocol)));
        AgentController agents = new AgentController(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        RequestLedger requests = new RequestLedger(
            IProtocolAuthority(address(protocol)), IAccountRegistry(address(registry))
        );
        DisclosureLog disclosures = new DisclosureLog(IAccountRegistry(address(registry)));

        if (verifierAddr == address(0)) {
            verifierAddr = address(new StubTransferVerifier());
            console2.log("WARNING: bring-up StubTransferVerifier deployed. Rotate before use.");
        }
        ConfidentialToken confidential = new ConfidentialToken(
            IERC20(usdg), IConfidentialTransferVerifier(verifierAddr), msg.sender
        );

        // The $MANSA fee layer. Given an existing token and a destination for
        // the proceeds, this deploys the staking vault and the schedule, then
        // points the protocol at both so holding and staking start to pay off.
        // Miss either variable and the whole layer is skipped, leaving fees off.
        address mansa = vm.envOr("MANSA_ADDRESS", address(0));
        address treasury = vm.envOr("TREASURY", address(0));
        StakingVault staking;
        FeeSchedule feeSchedule;
        if (mansa != address(0) && treasury != address(0)) {
            staking = new StakingVault(IERC20(mansa));
            feeSchedule = new FeeSchedule(msg.sender, IERC20(mansa), staking);
            protocol.setFeeConfig(treasury, address(feeSchedule));
        }

        vm.stopBroadcast();

        console2.log("ProtocolAuthority:  ", address(protocol));
        console2.log("AccountRegistry:    ", address(registry));
        console2.log("AgentController:    ", address(agents));
        console2.log("RequestLedger:      ", address(requests));
        console2.log("DisclosureLog:      ", address(disclosures));
        console2.log("ConfidentialToken:  ", address(confidential));
        console2.log("TransferVerifier:   ", verifierAddr);
        console2.log("StakingVault:       ", address(staking));
        console2.log("FeeSchedule:        ", address(feeSchedule));
    }
}
