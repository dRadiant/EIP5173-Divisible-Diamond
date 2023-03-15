// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./InFR.sol";
import "./nFRStorage.sol";
import "@solidstate/contracts/token/ERC721/SolidStateERC721.sol";
import "@prb/math/contracts/PRBMathUD60x18.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {CounterStorage} from "../utils/CounterStorage.sol";

abstract contract nFR is InFR, SolidStateERC721 {
    using PRBMathUD60x18 for uint256;
    using PRBMathSD59x18 for int256;

    using CounterStorage for CounterStorage.Layout;

    function getFRInfo(uint256 tokenId)
        external
        view
        virtual
        override
        returns (
            uint8 numGenerations,
            uint256 percentOfProfit,
            uint256 successiveRatio,
            uint256 lastSoldPrice,
            uint256 ownerAmount,
            address[] memory addressesInFR
        )
    {
        nFRStorage.Layout storage l = nFRStorage.layout();
        return (l._tokenFRInfo[tokenId].numGenerations, l._tokenFRInfo[tokenId].percentOfProfit, l._tokenFRInfo[tokenId].successiveRatio, l._tokenFRInfo[tokenId].lastSoldPrice, l._tokenFRInfo[tokenId].ownerAmount, l._tokenFRInfo[tokenId].addressesInFR);
    }

    function getListInfo(uint256 tokenId)
        external
        view
        virtual
        override
        returns (
            uint256,
            address,
            bool
        )
    {
        nFRStorage.Layout storage l = nFRStorage.layout();
        return (l._tokenListInfo[tokenId].salePrice, l._tokenListInfo[tokenId].lister, l._tokenListInfo[tokenId].isListed);
    }

    function getAssetInfo(uint256 tokenId) 
        external
        view
        virtual
        override
        returns (
            uint256,
            uint256
        )
    {
        nFRStorage.Layout storage l = nFRStorage.layout();
        return (l._tokenAssetInfo[tokenId].initialAmount, l._tokenAssetInfo[tokenId].amount);
    }

    function getAllottedFR(address account) external view virtual override returns (uint256) {
        nFRStorage.Layout storage l = nFRStorage.layout();
        return l._allottedFR[account];
    }

    function _transferFrom(
        address from,
        address to,
        uint256 tokenId,
        uint256 amount,
        uint256 soldPrice
    ) internal virtual {
        require(from != to, "transfer to self");
        nFRStorage.Layout storage l = nFRStorage.layout();

        require(amount <= l._tokenAssetInfo[tokenId].amount, "amount is too large"); // This check can be done in buy

        // Just transfer the token

        // NFT sold for a loss, meaning no FR distribution, but we still shift generations, and update price. We return ALL of the received ETH to the msg.sender as no FR chunk was needed.

        uint256 allocatedFR = 0;

        if (soldPrice > l._tokenFRInfo[tokenId].lastSoldPrice) { // NFT sold for a profit
            allocatedFR = _distributeFR(tokenId, soldPrice, amount);
        }

        uint256 newTokenId;

        if (amount != l._tokenAssetInfo[tokenId].amount) {
            // Mint a new token that clones the FR info, then deducts the amount from the current token, then I think we can override the tokenId argument with the new tokenId
            newTokenId = _createSplitToken(to, tokenId, amount, soldPrice);

            l._tokenAssetInfo[tokenId].amount -= amount;
        }
        
        if (newTokenId == 0) { // Whole NFT has been transferred
            ERC721BaseInternal._transfer(from, to, tokenId);
            require(_checkOnERC721Received(from, to, tokenId, ""), "ERC721: transfer to non ERC721Receiver implementer");

            l._tokenFRInfo[tokenId].lastSoldPrice = soldPrice; // Should not be updating this if the transfer is not whole. Otherwise, you can sell 0.1 tokens at 1000, then sell 0.9 tokens at 1000 paying 0 FR.
            l._tokenFRInfo[tokenId].ownerAmount++;

            _shiftGenerations(to, tokenId);
        }

        address lister = l._tokenListInfo[tokenId].lister;

        delete l._tokenListInfo[tokenId]; // Need to determine if we want to have partial buys, aka if the list amount is 10 tokens, and you have partial buys, you can just buy 5 tokens. Without partials, the listing would be deleted, with partials, it'd just be deducted from the list amount.

        (bool sent, ) = payable(lister).call{value: soldPrice - allocatedFR}("");
        require(sent, "ERC5173: Failed to send ETH to lister");
    }

    function list(uint256 tokenId, uint256 salePrice) public virtual override {
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC5173: list caller is not owner nor approved");
        nFRStorage.Layout storage l = nFRStorage.layout();

        l._tokenListInfo[tokenId] = nFRStorage.ListInfo(salePrice, _msgSender(), true);

        emit Listed(tokenId, salePrice);
    }

    function unlist(uint256 tokenId) public virtual override {
        require(_isApprovedOrOwner(_msgSender(), tokenId), "ERC5173: unlist caller is not owner nor approved");
        nFRStorage.Layout storage l = nFRStorage.layout();

        delete l._tokenListInfo[tokenId];

        emit Unlisted(tokenId);
    }

    function buy(uint256 tokenId) public payable virtual override {
        nFRStorage.Layout storage l = nFRStorage.layout();
        require(l._tokenListInfo[tokenId].isListed == true, "Token is not listed");
        require(l._tokenListInfo[tokenId].salePrice == msg.value, "salePrice and msg.value mismatch");

        for (uint i = 0; i < l._tokenFRInfo[tokenId].addressesInFR.length; i++) { // Could use a isInFR mapping if it is cheaper than this
            require(l._tokenFRInfo[tokenId].addressesInFR[i] != _msgSender(), "Already in the FR sliding window"); // Could move this verification to _transferFrom and also call _transferFrom in the _transfer override instead of repeating ourselves
        }

        uint256 salePrice = l._tokenListInfo[tokenId].salePrice;

        _transferFrom(l._tokenListInfo[tokenId].lister, _msgSender(), tokenId, l._tokenAssetInfo[tokenId].amount, l._tokenListInfo[tokenId].salePrice);

        emit Bought(tokenId, salePrice);
    }

    function _transfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 amount
    ) internal virtual {
        
    }

    function _transfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override {
        require(from != to, "transfer to self");
        super._transfer(from, to, tokenId);
        nFRStorage.Layout storage l = nFRStorage.layout();

        for (uint i = 0; i < l._tokenFRInfo[tokenId].addressesInFR.length; i++) {
            require(l._tokenFRInfo[tokenId].addressesInFR[i] != to, "Already in the FR sliding window");
        }

        if (l._tokenListInfo[tokenId].isListed == true) {
            delete l._tokenListInfo[tokenId];
        }

        l._tokenFRInfo[tokenId].lastSoldPrice = 0;
        l._tokenFRInfo[tokenId].ownerAmount++;
        _shiftGenerations(to, tokenId);
    }

    function _burn(uint256 tokenId) internal virtual override {
        super._burn(tokenId);
        nFRStorage.Layout storage l = nFRStorage.layout();

        delete l._tokenFRInfo[tokenId];
        delete l._tokenListInfo[tokenId];
        delete l._tokenAssetInfo[tokenId];
    }

    function _createSplitToken(address to, uint256 tokenId, uint256 amount, uint256 soldPrice) internal virtual returns (uint256) {
        CounterStorage.incrementTokenId();

        uint256 newTokenId = CounterStorage.currentTokenId();

        nFRStorage.Layout storage l = nFRStorage.layout();

        nFRStorage.FRInfo memory tokenFRInfo = l._tokenFRInfo[tokenId]; // Needed or else Stack Too Deep error

        _mint(to, newTokenId, amount, tokenFRInfo.numGenerations, tokenFRInfo.percentOfProfit, tokenFRInfo.successiveRatio, soldPrice, tokenFRInfo.ownerAmount + 1, tokenFRInfo.addressesInFR);

        return newTokenId;
    }

    function _mint(address to, uint256 tokenId) internal virtual override {
        nFRStorage.Layout storage l = nFRStorage.layout();

        require(l._defaultFRInfo.isValid, "No Default FR Info has been set");

        super._mint(to, tokenId);

        l._tokenFRInfo[tokenId] = nFRStorage.FRInfo(l._defaultFRInfo.numGenerations, l._defaultFRInfo.percentOfProfit, l._defaultFRInfo.successiveRatio, 0, 1, new address[](0), true);

        l._tokenFRInfo[tokenId].addressesInFR.push(to);
    }

    function _mint(
        address to,
        uint256 tokenId,
        uint256 amount,
        uint8 numGenerations,
        uint256 percentOfProfit,
        uint256 successiveRatio
    ) internal virtual {
        _mint(to, tokenId, amount, numGenerations, percentOfProfit, successiveRatio, 0, 1, new address[](0));
    }

    function _mint(
        address to,
        uint256 tokenId,
        uint256 amount,
        uint8 numGenerations,
        uint256 percentOfProfit,
        uint256 successiveRatio,
        uint256 lastSoldPrice,
        uint256 ownerAmount,
        address[] memory addressesInFR
    ) internal virtual {
        require(numGenerations > 0 && percentOfProfit > 0 && percentOfProfit <= 1e18 && successiveRatio > 0 && amount > 0 && ownerAmount > 0, "Invalid Data Passed");

        ERC721BaseInternal._mint(to, tokenId);
        require(_checkOnERC721Received(address(0), to, tokenId, ""), "ERC721: transfer to non ERC721Receiver implementer");

        nFRStorage.Layout storage l = nFRStorage.layout();

        l._tokenFRInfo[tokenId] = nFRStorage.FRInfo(numGenerations, percentOfProfit, successiveRatio, lastSoldPrice, ownerAmount, addressesInFR, true);

        _shiftGenerations(to, tokenId); // Functionally equivalent to pushing addressInFR, however, takes into account calls providing a non-empty addressesInFR

        l._tokenAssetInfo[tokenId].initialAmount = amount;
        l._tokenAssetInfo[tokenId].amount = amount;
    }

    function _distributeFR(uint256 tokenId, uint256 soldPrice, uint256 soldAmount) internal virtual returns(uint256 allocatedFR) {
        nFRStorage.Layout storage l = nFRStorage.layout();

        address[] memory eligibleAddresses = l._tokenFRInfo[tokenId].addressesInFR;
        assembly { mstore(eligibleAddresses, sub(mload(eligibleAddresses), 1)) } // This is functionally equivalent to .pop() except for a memory array. Remove last person in FR array as the last person doesn't pay themselves. This won't underflow because someone is always in the FR array. Early on that'll be the minter who is added at mint time.

        if (eligibleAddresses.length == 0) 
            return 0;

        uint256 profit = (soldPrice - l._tokenFRInfo[tokenId].lastSoldPrice).div((l._tokenAssetInfo[tokenId].initialAmount).div(soldAmount)); // (Current Sale Price - Last Sale Price) / (Initial Token Amount / Sale Amount) - If we don't have initial token amount, then you can't properly calculate the profits. If you sell half of the token, then the other half, it'll be as if you made 1.5x of your actual profits
        uint256[] memory FR = _calculateFR(profit, l._tokenFRInfo[tokenId].percentOfProfit, l._tokenFRInfo[tokenId].successiveRatio, l._tokenFRInfo[tokenId].ownerAmount - 1, l._tokenFRInfo[tokenId].numGenerations - 1); // Deduct one from numGenerations and ownerAmount because otherwise it'll create the distribution with an extra person in mind

        for (uint owner = 0; owner < FR.length; owner++) {
            l._allottedFR[l._tokenFRInfo[tokenId].addressesInFR[owner]] += FR[owner];
        }

        allocatedFR = profit.mul(l._tokenFRInfo[tokenId].percentOfProfit);

        emit FRDistributed(tokenId, soldPrice, allocatedFR);
    }

    function _shiftGenerations(address to, uint256 tokenId) internal virtual {
        nFRStorage.Layout storage l = nFRStorage.layout();
        if (l._tokenFRInfo[tokenId].addressesInFR.length < l._tokenFRInfo[tokenId].numGenerations) { // We just want to push to the array
            l._tokenFRInfo[tokenId].addressesInFR.push(to);
        } else { // We want to remove the first element in the array and then push to the end of the array
            for (uint i = 0; i < l._tokenFRInfo[tokenId].addressesInFR.length-1; i++) {
                l._tokenFRInfo[tokenId].addressesInFR[i] = l._tokenFRInfo[tokenId].addressesInFR[i+1];
            }

            l._tokenFRInfo[tokenId].addressesInFR.pop();

            l._tokenFRInfo[tokenId].addressesInFR.push(to); // Wouldn't it just be more efficient to replace the last element with to. Instead of pop and pushing.
        }
    }

    function _setDefaultFRInfo(
        uint8 numGenerations,
        uint256 percentOfProfit,
        uint256 successiveRatio
    ) internal virtual {
        require(numGenerations > 0 && percentOfProfit > 0 && percentOfProfit <= 1e18 && successiveRatio > 0, "Invalid Data Passed");
        nFRStorage.Layout storage l = nFRStorage.layout();

        l._defaultFRInfo.numGenerations = numGenerations;
        l._defaultFRInfo.percentOfProfit = percentOfProfit;
        l._defaultFRInfo.successiveRatio = successiveRatio;
        l._defaultFRInfo.isValid = true;
    }

    function releaseFR(address payable account) public virtual override {
        nFRStorage.Layout storage l = nFRStorage.layout();
        require(l._allottedFR[account] > 0, "No FR Payment due");

        uint256 FRAmount = l._allottedFR[account];

        l._allottedFR[account] = 0;

        (bool sent, ) = account.call{value: FRAmount}("");
        require(sent, "Failed to release FR");

        emit FRClaimed(account, FRAmount);
    }

    function _calculateFR(
        uint256 totalProfit,
        uint256 buyerReward,
        uint256 successiveRatio,
        uint256 ownerAmount,
        uint256 windowSize
    ) internal pure virtual returns (uint256[] memory) {
        uint256 n = Math.min(ownerAmount, windowSize);
        uint256[] memory FR = new uint256[](n);

        for (uint256 i = 1; i < n + 1; i++) { // There have to be some optimizations we could make
            uint256 pi = 0;

            if (successiveRatio != 1e18) {
                int256 v1 = 1e18 - int256(successiveRatio).powu(n);
                int256 v2 = int256(successiveRatio).powu(i - 1);
                int256 v3 = int256(totalProfit).mul(int256(buyerReward));
                int256 v4 = v3.mul(1e18 - int256(successiveRatio));
                pi = uint256(v4 * v2 / v1);
            } else {
                pi = totalProfit.mul(buyerReward).div(n);
            }

            FR[n - i] = pi;
        }

        return FR;
    }

    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}
