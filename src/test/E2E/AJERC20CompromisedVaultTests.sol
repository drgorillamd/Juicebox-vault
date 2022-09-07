// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.6;

import "./abstract/AJPayoutRedemptionTerminalTests.sol";
import {MockERC20} from "MockERC4626/MockERC20.sol";
import {MockCompromisedERC4626} from "MockERC4626/vaults/MockCompromisedERC4626.sol";

contract AJERC20CompromisedVaultTests is AJPayoutRedemptionTerminalTests {
    AJSingleVaultTerminalERC20 private _ajSingleVaultTerminalERC20;
    address private _ajERC20Asset;

    //*********************************************************************//
    // ------------------------- virtual methods ------------------------- //
    //*********************************************************************//

    function ajSingleVaultTerminal()
        internal
        view
        virtual
        override
        returns (IAJSingleVaultTerminal terminal)
    {
        terminal = IAJSingleVaultTerminal(address(_ajSingleVaultTerminalERC20));
    }

    function ajTerminalAsset()
        internal
        view
        virtual
        override
        returns (address)
    {
        return _ajERC20Asset;
    }

    function ajVaultAsset() internal view virtual override returns (address) {
        return _ajERC20Asset;
    }

    function ajAssetMinter()
        internal
        view
        virtual
        override
        returns (IMintable)
    {
        return IMintable(_ajERC20Asset);
    }

    function ajAssetBalanceOf(address addr)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return MockERC20(_ajERC20Asset).balanceOf(addr);
    }

    function fundWallet(address addr, uint256 amount)
        internal
        virtual
        override
    {
        IMintable(address(_ajERC20Asset)).mint(addr, amount);
    }

    function beforeTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override returns (uint256 value) {
        evm.prank(from);
        MockERC20(_ajERC20Asset).approve(to, amount);
    }

    function setUp() public override {
        // Setup Juicebox
        super.setUp();

        // Create the valuable asset
        _ajERC20Asset = address(new MockERC20("MockAsset", "MAsset", 18));
        evm.label(_ajERC20Asset, "MockAsset");

        // Deploy AJ ERC20 Terminal
        _ajSingleVaultTerminalERC20 = new AJSingleVaultTerminalERC20(
            IERC20Metadata(_ajERC20Asset),
            jbLibraries().ETH(), // currency
            jbLibraries().ETH(), // base weight currency
            1, // JBSplitsGroup
            jbOperatorStore(),
            jbProjects(),
            jbDirectory(),
            jbSplitsStore(),
            jbPrices(),
            jbPaymentTerminalStore(),
            multisig()
        );

        // Label the ERC20 address
        evm.label(
            address(_ajSingleVaultTerminalERC20),
            "AJSingleVaultTerminalERC20"
        );
    }

    function testPayRedeemFuzz(
        uint40 _LocalBalancePPM,
        uint128 _payAmount,
        uint256 _redeemAmount,
        uint32 _secondsBetweenPayAndRedeem
    ) public override {
        uint256 _localBalancePPMNormalised = _LocalBalancePPM / 1_000_000;
        address hacker = address(0xf00ba6);

        evm.assume(
            _localBalancePPMNormalised > 0 &&
                _localBalancePPMNormalised <= 1_000_000
        );
        evm.assume(_payAmount > 0);
        evm.assume(_redeemAmount > 0);

        IAJSingleVaultTerminal _ajSingleVaultTerminal = ajSingleVaultTerminal();

        IJBPaymentTerminal[] memory _terminals = new IJBPaymentTerminal[](1);
        _terminals[0] = _ajSingleVaultTerminal;

        // Configure project
        uint256 projectId = controller.launchProjectFor(
            msg.sender,
            _projectMetadata,
            _data,
            _metadata,
            block.timestamp,
            _groupedSplits,
            _fundAccessConstraints,
            _terminals,
            ""
        );

        // Create the ERC4626 Vault
        MockCompromisedERC4626 vault = new MockCompromisedERC4626(
            ajVaultAsset(),
            ajAssetMinter(),
            "yJBX",
            "yJBX",
            1000
        );

        // Configure the AJ terminal to use the MockERC4626
        evm.prank(msg.sender);
        _ajSingleVaultTerminal.setVault(
            projectId,
            IERC4626(address(vault)),
            VaultConfig(_localBalancePPMNormalised),
            0
        );

        // Mint some tokens the payer can use
        address payer = address(0xf00);

        // Mint and Approve the tokens to be paid (if needed)
        fundWallet(payer, _payAmount);
        uint256 _value = beforeTransfer(
            payer,
            address(_ajSingleVaultTerminal),
            _payAmount
        );

        // Perform the pay
        evm.startPrank(payer);
        uint256 jbTokensReceived = _ajSingleVaultTerminal.pay{value: _value}(
            projectId,
            _payAmount,
            ajVaultAsset(),
            payer,
            0,
            false,
            "",
            ""
        );

        // Check that: Balance in the terminal is correct, balance in the vault is correct
        uint256 _expectedBalanceInVault = (_payAmount *
            _localBalancePPMNormalised) / 1_000_000;
        assertEq(
            ajAssetBalanceOf(address(_ajSingleVaultTerminal)),
            _expectedBalanceInVault
        );
        assertEq(
            ajAssetBalanceOf(address(vault)),
            _payAmount - _expectedBalanceInVault
        );

        // Fast forward time (assumes 15 second blocks)
        evm.warp(block.timestamp + _secondsBetweenPayAndRedeem);
        evm.roll(block.number + _secondsBetweenPayAndRedeem / 15);

        // Check the store to see what overflow we should be expecting
        uint256 overflowExpected = jbPaymentTerminalStore()
            .currentReclaimableOverflowOf(
                IJBSingleTokenPaymentTerminal(address(_ajSingleVaultTerminal)),
                projectId,
                jbTokensReceived,
                false
            );
        uint256 _userBalanceBeforeWithdraw = ajAssetBalanceOf(payer);

        evm.stopPrank();

        evm.prank(hacker);
        // drain the vault
        vault.withdraw(0, hacker, hacker);

        evm.prank(payer);
        // Perform the redeem
        _ajSingleVaultTerminal.redeemTokensOf(payer, projectId, jbTokensReceived, address(jbToken()), 0, payable(payer), '', '');
        evm.stopPrank();

        // If the initial pay amount was more than 10 wei there should be some overflow
        if(_payAmount > 10){
            assertGt(overflowExpected, 0);
        }

        // Check that the user received the expected amount
        assertEq(ajAssetBalanceOf(payer), _userBalanceBeforeWithdraw + overflowExpected);
    }

    // function testAllowanceFuzz(
    //     uint40 _LocalBalancePPM,
    //     uint232 _allowance,
    //     uint232 _target,
    //     uint96 _balance,
    //     uint32 _secondsBetweenActions
    // ) public override {
    //     uint256 _localBalancePPMNormalised = _LocalBalancePPM / 1_000_000;
    //     address hacker = address(0xf00ba6);
    //     MockCompromisedERC4626 vault;

    //     evm.assume(
    //         _localBalancePPMNormalised > 0 &&
    //             _localBalancePPMNormalised <= 1_000_000
    //     );

    //     IAJSingleVaultTerminal _ajSingleVaultTerminal = ajSingleVaultTerminal();

    //     IJBPaymentTerminal[] memory _terminals = new IJBPaymentTerminal[](1);
    //     _terminals[0] = _ajSingleVaultTerminal;

    //     _fundAccessConstraints.push(
    //         JBFundAccessConstraints({
    //             terminal: _ajSingleVaultTerminal,
    //             token: ajTerminalAsset(),
    //             distributionLimit: _target,
    //             overflowAllowance: _allowance,
    //             distributionLimitCurrency: jbLibraries().ETH(),
    //             overflowAllowanceCurrency: jbLibraries().ETH()
    //         })
    //     );

    //     // Configure project
    //     address _projectOwner = address(420);
    //     uint256 projectId = controller.launchProjectFor(
    //         _projectOwner,
    //         _projectMetadata,
    //         _data,
    //         _metadata,
    //         block.timestamp,
    //         _groupedSplits,
    //         _fundAccessConstraints,
    //         _terminals,
    //         ""
    //     );

    //     // Scoped to prevent stack too deep
    //     {
    //         // Create the ERC4626 Vault
    //         vault = new MockCompromisedERC4626(
    //             ajVaultAsset(),
    //             ajAssetMinter(),
    //             "yJBX",
    //             "yJBX",
    //             1000
    //         );

    //         evm.prank(_projectOwner);
    //         _ajSingleVaultTerminal.setVault(
    //             projectId,
    //             IERC4626(address(vault)),
    //             VaultConfig(_localBalancePPMNormalised),
    //             0
    //         );
    //     }

    //     // Mint some tokens the payer can use
    //     address payer = address(0xf00);

    //     // Mint and Approve the tokens to be paid (if needed)
    //     fundWallet(payer, _balance);
    //     uint256 _value = beforeTransfer(
    //         payer,
    //         address(_ajSingleVaultTerminal),
    //         _balance
    //     );

    //     // Perform the pay
    //     evm.prank(payer);
    //     uint256 jbTokensReceived = _ajSingleVaultTerminal.pay{value: _value}(
    //         projectId,
    //         _balance,
    //         ajVaultAsset(),
    //         payer,
    //         0,
    //         false,
    //         "",
    //         ""
    //     );

    //     // Fast forward time (assumes 15 second blocks)
    //     evm.warp(block.timestamp + _secondsBetweenActions);
    //     evm.roll(block.number + _secondsBetweenActions / 15);

    //     // Discretionary use of overflow allowance by project owner (allowance = 5ETH)
    //     bool willRevert;
    //     if (_allowance == 0) {
    //         evm.expectRevert(
    //             abi.encodeWithSignature("INADEQUATE_CONTROLLER_ALLOWANCE()")
    //         );
    //         willRevert = true;
    //     } else if (_target >= _balance || _allowance > (_balance - _target)) {
    //         // Too much to withdraw or no overflow ?
    //         evm.expectRevert(
    //             abi.encodeWithSignature(
    //                 "INADEQUATE_PAYMENT_TERMINAL_STORE_BALANCE()"
    //             )
    //         );
    //         willRevert = true;
    //     } else if (
    //         _allowance > ajAssetBalanceOf(address(_ajSingleVaultTerminal))
    //     ) {
    //         // If the amount being withdrawn as allowance is more than the terminal has in its localBalance
    //         // than the terminal will withdraw from the vault
    //         evm.expectEmit(true, true, true, false);
    //         emit Withdraw(
    //             address(_ajSingleVaultTerminal),
    //             address(_ajSingleVaultTerminal),
    //             address(_ajSingleVaultTerminal),
    //             0,
    //             0
    //         );
    //     }
        
    //     evm.prank(_projectOwner);
    //     _ajSingleVaultTerminal.useAllowanceOf(
    //         projectId,
    //         _allowance,
    //         1, // Currency
    //         address(0), //token (unused)
    //         0, // Min wei out
    //         payable(_projectOwner), // Beneficiary
    //         "MEMO"
    //     );

    //     // Fast forward time (assumes 15 second blocks)
    //     evm.warp(block.timestamp + _secondsBetweenActions);
    //     evm.roll(block.number + _secondsBetweenActions / 15);

    //     if (_balance != 0 && !willRevert)
    //         assertEq(
    //             ajAssetBalanceOf(_projectOwner),
    //             PRBMath.mulDiv(
    //                 _allowance,
    //                 jbLibraries().MAX_FEE(),
    //                 jbLibraries().MAX_FEE() + _ajSingleVaultTerminal.fee()
    //             )
    //         );

    //     // Distribute the funding target ETH -> no split then beneficiary is the project owner
    //     uint256 initBalance = ajAssetBalanceOf(_projectOwner);

    //     if (_target > _balance) {
    //         evm.expectRevert(
    //             abi.encodeWithSignature(
    //                 "INADEQUATE_PAYMENT_TERMINAL_STORE_BALANCE()"
    //             )
    //         );
    //     } else if (_target == 0) {
    //         evm.expectRevert(
    //             abi.encodeWithSignature("DISTRIBUTION_AMOUNT_LIMIT_REACHED()")
    //         );
    //     } else if (
    //         _target > ajAssetBalanceOf(address(_ajSingleVaultTerminal))
    //     ) {
    //         // If the amount being withdrawn as allowance is more than the terminal has in its localBalance
    //         // than the terminal will withdraw from the vault
    //         evm.expectEmit(true, true, true, false);
    //         emit Withdraw(
    //             address(_ajSingleVaultTerminal),
    //             address(_ajSingleVaultTerminal),
    //             address(_ajSingleVaultTerminal),
    //             0,
    //             0
    //         );
    //     }

    //     evm.prank(hacker);
    //     // drain the vault
    //     vault.withdraw(0, hacker, hacker);

    //     evm.prank(_projectOwner);
    //     _ajSingleVaultTerminal.distributePayoutsOf(
    //         projectId,
    //         _target,
    //         1, // Currency
    //         address(0), //token (unused)
    //         0, // Min wei out
    //         "Foundry payment" // Memo
    //     );

    //     // Funds leaving the ecosystem -> fee taken
    //     if (_target <= _balance && _target != 0)
    //         assertEq(
    //             ajAssetBalanceOf(_projectOwner),
    //             initBalance +
    //                 PRBMath.mulDiv(
    //                     _target,
    //                     jbLibraries().MAX_FEE(),
    //                     _ajSingleVaultTerminal.fee() + jbLibraries().MAX_FEE()
    //                 )
    //         );
    //     // // redeem eth from the overflow by the token holder:
    //     // uint256 senderBalance = jbTokenStore().balanceOf(payer, projectId);

    //     // evm.prank(payer);
    //     // _ajSingleVaultTerminal.redeemTokensOf(
    //     //     payer,
    //     //     projectId,
    //     //     senderBalance,
    //     //     address(0), //token (unused)
    //     //     0,
    //     //     payable(payer),
    //     //     'gimme my token back',
    //     //     new bytes(0)
    //     // );

    //     // // verify: beneficiary should have a balance of 0 JBTokens
    //     // assertEq(jbTokenStore().balanceOf(payer, projectId), 0);
    // }
}