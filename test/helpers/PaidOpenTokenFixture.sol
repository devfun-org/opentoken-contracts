// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Local fault injection only. This is not Circle USDC or a reserve attestation.
contract PaidOpenTokenUsdcFixture is ERC20 {
    enum Fault {
        None,
        ReturnFalse,
        RevertTransfer,
        ShortReceipt,
        ExcessReceipt,
        DecreaseTreasury,
        NoReturn
    }

    enum OutflowFault {
        None,
        ReturnFalse,
        ShortDebit,
        ExcessDebit,
        IncreaseSender,
        ShortCredit,
        DecreaseRecipient
    }
    OutflowFault public outflowFault;

    function setOutflowFault(OutflowFault next) external {
        outflowFault = next;
    }

    function forceBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (outflowFault == OutflowFault.ReturnFalse) return false;
        if (callback != address(0)) {
            (bool ok, bytes memory result) = callback.call(callbackData);
            require(!ok, "callback unexpectedly succeeded");
            callbackError = bytes4(result);
        }
        if (outflowFault == OutflowFault.IncreaseSender) {
            _mint(msg.sender, 1);
            return true;
        }
        if (outflowFault == OutflowFault.DecreaseRecipient) {
            _burn(msg.sender, amount);
            _burn(to, 1);
            return true;
        }
        uint256 debit = outflowFault == OutflowFault.ShortDebit
            ? amount - 1
            : outflowFault == OutflowFault.ExcessDebit ? amount + 1 : amount;
        _burn(msg.sender, debit);
        _mint(to, outflowFault == OutflowFault.ShortCredit ? amount - 1 : amount);
        return true;
    }

    uint8 private immutable precision;
    Fault public fault;
    bool public failBalanceRead;
    address public callback;
    bytes public callbackData;
    bytes4 public callbackError;

    constructor(uint8 assetDecimals) ERC20("USDC fixture", "USDC") {
        precision = assetDecimals;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function seed(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFault(Fault next) external {
        fault = next;
    }

    function setFailBalanceRead(bool value) external {
        failBalanceRead = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function balanceOf(address account) public view override returns (uint256) {
        require(!failBalanceRead, "USDC read unavailable");
        return super.balanceOf(account);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (fault == Fault.ReturnFalse) return false;
        require(fault != Fault.RevertTransfer, "USDC transfer unavailable");
        if (fault == Fault.DecreaseTreasury) {
            _burn(to, 1);
            return true;
        }
        if (callback != address(0)) {
            (bool ok, bytes memory result) = callback.call(callbackData);
            require(!ok, "callback unexpectedly succeeded");
            callbackError = bytes4(result);
        }
        super.transferFrom(from, to, fault == Fault.ShortReceipt ? amount - 1 : amount);
        if (fault == Fault.ExcessReceipt) _mint(to, 1);
        if (fault == Fault.NoReturn) {
            assembly {
                return(0, 0)
            }
        }
        return true;
    }
}

/// Code-bearing address for tests, not a Safe or evidence of a signing threshold.
contract PaidOpenTokenWalletFixture {}
