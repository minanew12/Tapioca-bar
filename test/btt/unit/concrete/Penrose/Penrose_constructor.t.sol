// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.22;

import {Markets_Unit_Shared} from "../../shared/Markets_Unit_Shared.t.sol";

contract Penrose_constructor is Markets_Unit_Shared {
    function test_WhenPenroseIsCreated() external {
        // it should have all initial state variables set
        assertEq(address(penrose.yieldBox()), address(yieldBox));
        assertEq(address(penrose.cluster()), address(cluster));
        assertEq(address(penrose.tapToken()), address(tapToken));
        assertEq(address(penrose.mainToken()), address(mainToken));
        assertEq(penrose.tapAssetId(), tapId);
        assertEq(penrose.mainAssetId(), mainTokenId);
        assertEq(penrose.bigBangEthDebtRate(), 8e16);
        assertEq(penrose.owner(), address(this));
    }
}
