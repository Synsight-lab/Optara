// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SeriesFixture} from "../utils/SeriesFixture.sol";
import {ExternalOptionWrapper} from "../../src/series/ExternalOptionWrapper.sol";
import {ExternalOptionFactory} from "../../src/series/ExternalOptionFactory.sol";
import {IProtocolControl} from "../../src/interfaces/IProtocolControl.sol";
import {OptionType} from "../../src/libraries/OptaraTypes.sol";
import {NotAuthorized, ZeroAddress, NotAContract} from "../../src/libraries/Errors.sol";

/// @notice Unit tests for ExternalOptionWrapper and ExternalOptionFactory (OPTION_SPEC.md §7).
contract ExternalOptionWrapperTest is SeriesFixture {
    ExternalOptionWrapper internal w;
    bytes32 internal sid;
    address internal alice;
    uint256 internal aliceKey;
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_791_244_800);
        _deploySeries();
        sid = _create(_params(OptionType.CALL, 4500e18, 1_798_185_600));
        w = ExternalOptionWrapper(registry.getSeries(sid).wrapper);
        (alice, aliceKey) = makeAddrAndKey("alice");
    }

    // ------------------------------------------------------------------ initialization

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        wrapperImpl.initialize(sid, "n", "s", clearing, settlementWindow, liquidationModule);
    }

    function test_cloneCannotBeReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        w.initialize(sid, "n", "s", stranger, stranger, stranger);
        assertEq(w.minter(), clearing, "minter fixed");
    }

    // ------------------------------------------------------------------ mint / burn permissions

    function test_onlyMinterMints() public {
        vm.prank(clearing);
        w.mint(alice, 5e18);
        assertEq(w.balanceOf(alice), 5e18);
        assertEq(w.totalSupply(), 5e18);
        address[3] memory others = [settlementWindow, liquidationModule, stranger];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, others[i]));
            w.mint(alice, 1);
        }
    }

    function test_eachBurnerBurns() public {
        vm.prank(clearing);
        w.mint(alice, 3e18);
        address[3] memory burners = [clearing, settlementWindow, liquidationModule];
        for (uint256 i; i < 3; ++i) {
            vm.prank(burners[i]);
            w.burn(alice, 1e18);
        }
        assertEq(w.balanceOf(alice), 0);
        assertEq(w.totalSupply(), 0);
    }

    function test_strangerCannotBurn() public {
        vm.prank(clearing);
        w.mint(alice, 1e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        w.burn(alice, 1e18);
        vm.prank(alice); // not even the holder burns directly: burning goes through Optara entry points
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, alice));
        w.burn(alice, 1e18);
    }

    function test_burnMoreThanBalanceReverts() public {
        vm.prank(clearing);
        w.mint(alice, 1e18);
        vm.prank(clearing);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 2e18));
        w.burn(alice, 2e18);
    }

    // ------------------------------------------------------------------ plain ERC-20

    function test_transfersAreExact() public {
        vm.prank(clearing);
        w.mint(alice, 10e18);
        vm.prank(alice);
        assertTrue(w.transfer(bob, 4e18));
        assertEq(w.balanceOf(alice), 6e18);
        assertEq(w.balanceOf(bob), 4e18);
        assertEq(w.totalSupply(), 10e18);
    }

    function test_permit() public {
        vm.prank(clearing);
        w.mint(alice, 10e18);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                bob,
                7e18,
                w.nonces(alice),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", w.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        w.permit(alice, bob, 7e18, deadline, v, r, s);
        assertEq(w.allowance(alice, bob), 7e18);
        assertEq(w.nonces(alice), 1);

        vm.prank(bob);
        assertTrue(w.transferFrom(alice, bob, 7e18));
        assertEq(w.balanceOf(bob), 7e18);

        // replay fails
        vm.expectRevert();
        w.permit(alice, bob, 7e18, deadline, v, r, s);
    }

    function test_permitDomainUsesSeriesName() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(w.name())),
                keccak256("1"),
                block.chainid,
                address(w)
            )
        );
        assertEq(w.DOMAIN_SEPARATOR(), expected);
    }

    // ------------------------------------------------------------------ factory

    function test_factoryOnlyRegistryDeploys() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NotAuthorized.selector, stranger));
        factory.deployWrapper(keccak256("x"), "n", "s");
    }

    function test_factoryViews() public view {
        assertEq(factory.wrapperImplementation(), address(wrapperImpl));
        assertEq(factory.registry(), address(registry));
        assertEq(factory.clearing(), clearing);
        assertEq(factory.settlementWindow(), settlementWindow);
        assertEq(factory.liquidationModule(), liquidationModule);
        assertEq(factory.predictWrapper(sid), address(w));
    }

    function test_factoryInitializeChecks() public {
        ExternalOptionFactory impl = new ExternalOptionFactory();
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, stranger));
        upgradeAdmin.deployProxy(
            address(impl),
            abi.encodeCall(
                ExternalOptionFactory.initialize,
                (IProtocolControl(address(pc)), stranger, stranger, stranger, stranger, stranger)
            )
        );
        vm.expectRevert(ZeroAddress.selector);
        upgradeAdmin.deployProxy(
            address(impl),
            abi.encodeCall(
                ExternalOptionFactory.initialize,
                (IProtocolControl(address(pc)), address(wrapperImpl), address(0), stranger, stranger, stranger)
            )
        );
        vm.stopPrank();
    }

    function test_wrapperInitializeRejectsZeroModules() public {
        // a fresh clone initialized with a zero module address
        ExternalOptionWrapper clone = ExternalOptionWrapper(_clone(address(wrapperImpl)));
        vm.expectRevert(ZeroAddress.selector);
        clone.initialize(sid, "n", "s", clearing, address(0), liquidationModule);
    }

    function _clone(address impl) internal returns (address instance) {
        assembly {
            mstore(0x00, or(shr(0xe8, shl(0x60, impl)), 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000))
            mstore(0x20, or(shl(0x78, impl), 0x5af43d82803e903d91602b57fd5bf3))
            instance := create(0, 0x09, 0x37)
        }
    }
}
