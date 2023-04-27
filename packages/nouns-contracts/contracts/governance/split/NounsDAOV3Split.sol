// SPDX-License-Identifier: GPL-3.0

/*********************************
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░█████████░░█████████░░░ *
 * ░░░░░░██░░░████░░██░░░████░░░ *
 * ░░██████░░░████████░░░████░░░ *
 * ░░██░░██░░░████░░██░░░████░░░ *
 * ░░██░░██░░░████░░██░░░████░░░ *
 * ░░░░░░█████████░░█████████░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 * ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ *
 *********************************/

pragma solidity ^0.8.6;

import { NounsDAOStorageV3 } from '../NounsDAOInterfaces.sol';
import { NounsDAOSplitEscrow } from './NounsDAOSplitEscrow.sol';
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

library NounsDAOV3Split {

    error SplitThresholdNotMet();
    error SplitPeriodNotActive();
    error SplitPeriodActive();

    uint256 constant SPLIT_PERIOD_DURTION = 7 days; // TODO: extract to storage var?
    uint256 constant SPLIT_THRESHOLD_BPS = 2_000; // 20%

    function signalSplit(NounsDAOStorageV3.StorageV3 storage ds, uint256[] calldata tokenIds) external {
        if (isSplitPeriodActive(ds)) revert SplitPeriodActive();
        // TODO: require !splitPeriodActive()

        // TODO: include split id in mapping
        NounsDAOSplitEscrow escrow = NounsDAOSplitEscrow(ds.splitEscrow[msg.sender]);
        if (address(escrow) == address(0)) {
            escrow = new NounsDAOSplitEscrow(msg.sender, address(ds.nouns));
            ds.splitEscrow[msg.sender] = address(escrow);
        }
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            ds.nouns.transferFrom(msg.sender, address(escrow), tokenIds[i]);
        }

        // TODO safecast
        ds.nounsInSplitEscrow[ds.splitId] += uint32(tokenIds.length);
    }

    // TODO: do we need a `to` param?
    function unsignalSplit(NounsDAOStorageV3.StorageV3 storage ds, uint256[] calldata tokenIds) external {
        if (isSplitPeriodActive(ds)) revert SplitPeriodActive();

        NounsDAOSplitEscrow escrow = NounsDAOSplitEscrow(ds.splitEscrow[msg.sender]);
        escrow.returnTokensToOwner(tokenIds);

        // TODO safecast
        ds.nounsInSplitEscrow[ds.splitId] -= uint32(tokenIds.length);
    }

    function executeSplit(NounsDAOStorageV3.StorageV3 storage ds) external {
        if (isSplitPeriodActive(ds)) revert SplitPeriodActive();
        if (ds.nounsInSplitEscrow[ds.splitId] < splitThreshold(ds)) revert SplitThresholdNotMet();

        ds.splitDAOTreasury = ds.splitDAODeployer.deploySplitDAO();
        sendProRataTreasury(ds, ds.splitDAOTreasury, ds.nounsInSplitEscrow[ds.splitId], adjustedTotalSupply(ds));

        ds.splitEndTimestamp = block.timestamp + SPLIT_PERIOD_DURTION;
    }

    function joinSplit(NounsDAOStorageV3.StorageV3 storage ds, uint256[] calldata tokenIds) external {
        if (!isSplitPeriodActive(ds)) revert SplitPeriodNotActive();

        sendProRataTreasury(ds, ds.splitDAOTreasury, tokenIds.length, adjustedTotalSupply(ds));

        for (uint256 i = 0; i < tokenIds.length; i++) {
            ds.nouns.transferFrom(msg.sender, address(ds.timelock), tokenIds[i]);
        }
    }

    function splitThreshold(NounsDAOStorageV3.StorageV3 storage ds) internal view returns (uint256) {
        // TODO: make this constant or configurable param
        return adjustedTotalSupply(ds) * SPLIT_THRESHOLD_BPS / 10_000;
    }

    function adjustedTotalSupply(NounsDAOStorageV3.StorageV3 storage ds) internal view returns (uint256) {
        uint256 totalSupply = ds.nouns.totalSupply() - ds.nouns.balanceOf(address(ds.timelock));
        if (isSplitPeriodActive(ds)) {
            return totalSupply - ds.nounsInSplitEscrow[ds.splitId];
        } else {
            return totalSupply;
        }
    }

    function isSplitPeriodActive(NounsDAOStorageV3.StorageV3 storage ds) internal view returns (bool) {
        return ds.splitEndTimestamp > block.timestamp;
    }

    function sendProRataTreasury(NounsDAOStorageV3.StorageV3 storage ds, address newDAOTreasury, uint256 tokenCount, uint256 totalSupply) internal {
        uint256 ethToSend = address(ds.timelock).balance * tokenCount / totalSupply;

        ds.timelock.sendETHToNewDAO(newDAOTreasury, ethToSend);

        for (uint256 i = 0; i < ds.erc20TokensToIncludeInSplit.length; i++) {
            IERC20 erc20token = IERC20(ds.erc20TokensToIncludeInSplit[i]);
            uint256 tokensToSend = erc20token.balanceOf(address(ds.timelock)) * tokenCount / totalSupply;
            ds.timelock.sendERC20ToNewDAO(newDAOTreasury, address(erc20token), tokensToSend);
        }
    }
}