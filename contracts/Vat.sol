// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;
import "@yield-protocol/utils/contracts/token/IERC20.sol";
import "./interfaces/IFYToken.sol";
import "./interfaces/IJoin.sol";
import "./interfaces/IOracle.sol";
import "./libraries/DataTypes.sol";


library Math {
    /// @dev Add a number (which might be negative) to a positive, and revert if the result is negative.
    function add(uint128 x, int128 y) internal pure returns (uint128 z) {
        require (y > 0 || x >= uint128(-y), "Math: Negative result");
        z = y > 0 ? x + uint128(y) : x - uint128(-y);
    }
}

library RMath { // Fixed point arithmetic in Ray units
    /// @dev Multiply an unsigned integer by another, returning a fixed point factor in ray units
    function rmul(uint128 x, uint128 y) internal pure returns (uint128 z) {
        uint256 _z = uint256(x) * uint256(y) / 1e27;
        require (_z <= type(uint128).max, "RMUL Overflow");
        z = uint128(_z);
    }
}

contract Vat {
    using Math for uint128;
    using RMath for uint128;

    event AssetAdded(bytes6 indexed assetId, address indexed asset);
    event SeriesAdded(bytes6 indexed seriesId, bytes6 indexed baseId, address indexed fyToken);
    event IlkAdded(bytes6 indexed seriesId, bytes6 indexed ilkId);
    event SpotOracleAdded(bytes6 indexed baseId, bytes6 indexed ilkId, address indexed oracle);
    event MaxDebtSet(bytes6 indexed baseId, bytes6 indexed ilkId, uint128 max);

    event VaultBuilt(bytes12 indexed vaultId, address indexed owner, bytes6 indexed seriesId, bytes6 ilkId);
    event VaultTweaked(bytes12 indexed vaultId, bytes6 indexed seriesId, bytes6 indexed ilkId);
    event VaultDestroyed(bytes12 indexed vaultId);
    event VaultTransfer(bytes12 indexed vaultId, address indexed receiver);

    event VaultFrobbed(bytes12 indexed vaultId, bytes6 indexed seriesId, bytes6 indexed ilkId, int128 ink, int128 art);
    event VaultFluxxed(bytes12 indexed from, bytes12 indexed to, uint128 ink);

    // ==== Protocol data ====
    mapping (bytes6 => IERC20)                              public assets;          // Underlyings and collaterals available in Vat. 12 bytes still free.
    mapping (bytes6 => mapping(bytes6 => DataTypes.Debt))   public debt;            // [baseId][ilkId] Max and sum of debt per underlying and collateral.
    mapping (bytes6 => DataTypes.Series)                    public series;          // Series available in Vat. We can possibly use a bytes6 (3e14 possible series).
    mapping (bytes6 => mapping(bytes6 => bool))             public ilks;            // [seriesId][assetId] Assets that are approved as collateral for a series

    mapping (bytes6 => IOracle)                             public chiOracles;      // Chi (savings rate) accruals oracle for the underlying
    mapping (bytes6 => IOracle)                             public rateOracles;     // Rate (borrowing rate) accruals oracle for the underlying
    mapping (bytes6 => mapping(bytes6 => DataTypes.Spot))   public spotOracles;     // [assetId][assetId] Spot price oracles

    // ==== Vault data ====
    mapping (bytes12 => DataTypes.Vault)                    public vaults;          // An user can own one or more Vaults, each one with a bytes12 identifier
    mapping (bytes12 => DataTypes.Balances)                 public vaultBalances;   // Both debt and assets
    mapping (bytes12 => uint32)                             public timestamps;      // If grater than zero, time that a vault was timestamped. Used for liquidation.

    // ==== Administration ====

    /// @dev Add a new Asset.
    function addAsset(bytes6 assetId, IERC20 asset)
        external
    {
        require (assets[assetId] == IERC20(address(0)), "Id already used");
        assets[assetId] = asset;
        emit AssetAdded(assetId, address(asset));
    }

    /// @dev Add a new series
    function addSeries(bytes6 seriesId, bytes6 baseId, IFYToken fyToken)
        external
        /*auth*/
    {
        require (assets[baseId] != IERC20(address(0)), "Asset not found");                  // 1 SLOAD
        require (fyToken != IFYToken(address(0)), "Series need a fyToken");
        require (series[seriesId].fyToken == IFYToken(address(0)), "Id already used");      // 1 SLOAD
        series[seriesId] = DataTypes.Series({
            fyToken: fyToken,
            maturity: fyToken.maturity(),
            baseId: baseId
        });                                                                                 // 1 SSTORE
        emit SeriesAdded(seriesId, baseId, address(fyToken));
    }

    /// @dev Add a spot oracle and its collateralization ratio
    function addSpotOracle(bytes6 baseId, bytes6 ilkId, IOracle oracle, uint32 ratio)
        external
    {
        require (assets[baseId] != IERC20(address(0)), "Asset not found");                  // 1 SLOAD
        require (assets[ilkId] != IERC20(address(0)), "Asset not found");                   // 1 SLOAD
        spotOracles[baseId][ilkId] = DataTypes.Spot({
            oracle: oracle,
            ratio: ratio                                                                    // With 2 decimals. 10000 == 100%
        });                                                                                 // 1 SSTORE. Allows to replace an existing oracle.
        emit SpotOracleAdded(baseId, ilkId, address(oracle));
    }

    /// @dev Add a new Ilk (approve an asset as collateral for a series).
    function addIlk(bytes6 seriesId, bytes6 ilkId)
        external
    {
        DataTypes.Series memory _series = series[seriesId];                                 // 1 SLOAD
        require (
            _series.fyToken != IFYToken(address(0)),
            "Series not found"
        );
        require (
            spotOracles[_series.baseId][ilkId].oracle != IOracle(address(0)),               // 1 SLOAD
            "Oracle not found"
        );
        ilks[seriesId][ilkId] = true;                                                       // 1 SSTORE
        emit IlkAdded(seriesId, ilkId);
    }

    /// @dev Add a new Ilk (approve an asset as collateral for a series).
    function setMaxDebt(bytes6 baseId, bytes6 ilkId, uint128 max)
        external
    {
        require (assets[baseId] != IERC20(address(0)), "Asset not found");                  // 1 SLOAD
        require (assets[ilkId] != IERC20(address(0)), "Asset not found");                   // 1 SLOAD
        debt[baseId][ilkId].max = max;                                                      // 1 SSTORE
        emit MaxDebtSet(baseId, ilkId, max);
    }

    // ==== Vault management ====

    /// @dev Create a new vault, linked to a series (and therefore underlying) and a collateral
    function build(bytes6 seriesId, bytes6 ilkId)
        public
        returns (bytes12 vaultId)
    {
        require (ilks[seriesId][ilkId] == true, "Ilk not added");                           // 1 SLOAD
        vaultId = bytes12(keccak256(abi.encodePacked(msg.sender, block.timestamp)));        // Check (vaults[id].owner == address(0)), and increase the salt until a free vault id is found. 1 SLOAD per check.
        vaults[vaultId] = DataTypes.Vault({
            owner: msg.sender,
            seriesId: seriesId,
            ilkId: ilkId
        });                                                                                 // 1 SSTORE

        emit VaultBuilt(vaultId, msg.sender, seriesId, ilkId);
    }

    /// @dev Destroy an empty vault. Used to recover gas costs.
    function destroy(bytes12 vaultId)
        public
    {
        require (vaults[vaultId].owner == msg.sender, "Only vault owner");                  // 1 SLOAD
        DataTypes.Balances memory _balances = vaultBalances[vaultId];                       // 1 SLOAD
        require (_balances.art == 0 && _balances.ink == 0, "Only empty vaults");            // 1 SLOAD
        // delete timestamps[vaultId];                                                      // 1 SSTORE REFUND
        delete vaults[vaultId];                                                             // 1 SSTORE REFUND
        emit VaultDestroyed(vaultId);
    }

    /// @dev Change a vault series and/or collateral types.
    /// We can change the series if there is no debt, or assets if there are no assets
    /// Doesn't check inputs, or collateralization level. Do that in public functions.
    function __tweak(bytes12 vaultId, bytes6 seriesId, bytes6 ilkId)
        internal
    {
        require (ilks[seriesId][ilkId] == true, "Ilk not added");                           // 1 SLOAD
        DataTypes.Balances memory _balances = vaultBalances[vaultId];                       // 1 SLOAD
        DataTypes.Vault memory _vault = vaults[vaultId];                                    // 1 SLOAD
        if (seriesId != _vault.seriesId) {
            require (_balances.art == 0, "Only with no debt");
            _vault.seriesId = seriesId;
        }
        if (ilkId != _vault.ilkId) {                                                        // If a new asset was provided
            require (_balances.ink == 0, "Only with no collateral");
            _vault.ilkId = ilkId;
        }
        vaults[vaultId] = _vault;                                                           // 1 SSTORE
        emit VaultTweaked(vaultId, seriesId, ilkId);
    }

    /// @dev Transfer a vault to another user.
    /// Doesn't check inputs, or collateralization level. Do that in public functions.
    function __give(bytes12 vaultId, address receiver)
        internal
    {
        vaults[vaultId].owner = receiver;                                                   // 1 SSTORE
        emit VaultTransfer(vaultId, receiver);
    }

    // ==== Asset and debt management ====

    /// @dev Move collateral between vaults.
    /// Doesn't check inputs, or collateralization level. Do that in public functions.
    function __flux(bytes12 from, bytes12 to, uint128 ink)
        internal
        returns (DataTypes.Balances memory, DataTypes.Balances memory)
    {
        require (vaults[from].ilkId == vaults[to].ilkId, "Different collateral");               // 2 SLOAD
        DataTypes.Balances memory _balancesFrom = vaultBalances[from];                          // 1 SLOAD
        DataTypes.Balances memory _balancesTo = vaultBalances[to];                              // 1 SLOAD
        _balancesFrom.ink -= ink;
        _balancesTo.ink += ink;
        vaultBalances[from] = _balancesFrom;                                                    // 1 SSTORE
        vaultBalances[to] = _balancesTo;                                                        // 1 SSTORE
        emit VaultFluxxed(from, to, ink);

        return (_balancesFrom, _balancesTo);
    }

    /// @dev Add collateral and borrow from vault, pull assets from and push borrowed asset to user
    /// Or, repay to vault and remove collateral, pull borrowed asset from and push assets to user
    /// Doesn't check inputs, or collateralization level. Do that in public functions.
    function __frob(bytes12 vaultId, int128 ink, int128 art)
        internal returns (DataTypes.Balances memory)
    {
        DataTypes.Vault memory _vault = vaults[vaultId];                                    // 1 SLOAD
        DataTypes.Balances memory _balances = vaultBalances[vaultId];                       // 1 SLOAD
        DataTypes.Series memory _series = series[_vault.seriesId];                          // 1 SLOAD

        // For now, the collateralization checks are done outside to allow for underwater operation. That might change.
        if (ink != 0) {
            _balances.ink = _balances.ink.add(ink);
        }

        // TODO: Consider whether _roll should call __frob, or the next block be a private function.
        // Modify vault and global debt records. If debt increases, check global limit.
        if (art != 0) {
            DataTypes.Debt memory _debt = debt[_series.baseId][_vault.ilkId];               // 1 SLOAD
            if (art > 0) require (_debt.sum.add(art) <= _debt.max, "Max debt exceeded");
            _balances.art = _balances.art.add(art);
            _debt.sum = _debt.sum.add(art);
            debt[_series.baseId][_vault.ilkId] = _debt;                                     // 1 SSTORE
        }
        vaultBalances[vaultId] = _balances;                                                 // 1 SSTORE

        emit VaultFrobbed(vaultId, _vault.seriesId, _vault.ilkId, ink, art);
        return _balances;
    }

    // ---- Restricted processes ----
    // Usable only by a authorized modules that won't cheat on Vat.

    // Change series and debt of a vault.
    // The module calling this function also needs to buy underlying in the pool for the new series, and sell it in pool for the old series.
    // TODO: Should we allow changing the collateral at the same time?
    /* function _roll(bytes12 vaultId, bytes6 seriesId, int128 art)
        public
        auth
    {
        require (vaults[vaultId].owner != address(0), "Vault not found");                   // 1 SLOAD
        DataTypes.Balances memory _balances = vaultBalances[vaultId];                       // 1 SLOAD
        DataTypes.Series memory _series = series[vaultId];                                  // 1 SLOAD
        
        delete vaultBalances[vaultId];                                                      // -1 SSTORE
        __tweak(vaultId, seriesId, vaults[vaultId].ilkId);                                  // 1 SLOAD + Cost of `__tweak`

        // Modify vault and global debt records. If debt increases, check global limit.
        if (art != 0) {
            DataTypes.Debt memory _debt = debt[_series.baseId][_vault.ilkId];               // 1 SLOAD
            if (art > 0) require (_debt.sum.add(art) <= _debt.max, "Max debt exceeded");
            _balances.art = _balances.art.add(art);
            _debt.sum = _debt.sum.add(art);
            debt[_series.baseId][_vault.ilkId] = _debt;                                     // 1 SSTORE
        }
        vaultBalances[vaultId] = _balances;                                                 // 1 SSTORE
        require(level(vaultId) >= 0, "Undercollateralized");                                // Cost of `level`
    } */

    // Give a non-timestamped vault to the caller, and timestamp it.
    // To be used for liquidation engines.
    /* function _grab(bytes12 vaultId)
        public
        auth                                                                                // 1 SLOAD
    {
        require (timestamps[vaultId] + 24*60*60 <= block.timestamp, "Timestamped");         // 1 SLOAD. Grabbing a vault protects it for a day from being grabbed by another liquidator.
        timestamps[vaultId] = block.timestamp;                                              // 1 SSTORE
        __give(vaultId, msg.sender);                                                        // Cost of `__give`
    } */

    /// @dev Manipulate a vault with collateralization checks.
    /// Available only to authenticated platform accounts.
    /// To be used by debt management contracts.
    function _frob(bytes12 vaultId, int128 ink, int128 art)
        public
        // auth                                                                             // 1 SLOAD
        returns (DataTypes.Balances memory balances)
    {
        require (vaults[vaultId].owner != address(0), "Vault not found");                   // 1 SLOAD
        balances = __frob(vaultId, ink, art);                                               // Cost of `__frob`
        if (balances.art > 0 && (ink < 0 || art > 0))                                       // If there is debt and we are less safe
            require(level(vaultId) >= 0, "Undercollateralized");                            // Cost of `level`
        return balances;
    }

    // ---- Public processes ----

    /// @dev Change a vault series or collateral.
    function tweak(bytes12 vaultId, bytes6 seriesId, bytes6 ilkId)
        public
    {
        require (vaults[vaultId].owner == msg.sender, "Only vault owner");                  // 1 SLOAD
        // __tweak checks that the series and the collateral both exist and that the collateral is approved for the series
        __tweak(vaultId, seriesId, ilkId);                                                  // Cost of `__give`
    }

    /// @dev Give a vault to another user.
    function give(bytes12 vaultId, address user)
        public
    {
        require (vaults[vaultId].owner == msg.sender, "Only vault owner");                  // 1 SLOAD
        __give(vaultId, user);                                                              // Cost of `__give`
    }

    // Move collateral between vaults.
    function flux(bytes12 from, bytes12 to, uint128 ink)
        public
        returns (DataTypes.Balances memory, DataTypes.Balances memory)
    {
        require (vaults[from].owner == msg.sender, "Only vault owner");                     // 1 SLOAD
        require (vaults[to].owner != address(0), "Vault not found");                        // 1 SLOAD
        DataTypes.Balances memory _balancesFrom;
        DataTypes.Balances memory _balancesTo;
        (_balancesFrom, _balancesTo) = __flux(from, to, ink);                               // Cost of `__flux`
        if (_balancesFrom.art > 0) require(level(from) >= 0, "Undercollateralized");        // Cost of `level`
        return (_balancesFrom, _balancesTo);
    }

    // ==== Accounting ====

    /// @dev Return the collateralization level of a vault. It will be negative if undercollateralized.
    function level(bytes12 vaultId) public view returns (int128) {
        DataTypes.Vault memory _vault = vaults[vaultId];                                    // 1 SLOAD
        DataTypes.Series memory _series = series[_vault.seriesId];                          // 1 SLOAD
        DataTypes.Balances memory _balances = vaultBalances[vaultId];                       // 1 SLOAD
        require (_vault.owner != address(0), "Vault not found");                            // The vault existing is enough to be certain that the oracle exists.

        // Value of the collateral in the vault according to the spot price
        bytes6 ilkId = _vault.ilkId;
        bytes6 baseId = _series.baseId;
        DataTypes.Spot memory _spot = spotOracles[baseId][ilkId];                           // 1 SLOAD
        IOracle oracle = _spot.oracle;
        uint128 ratio = uint128(_spot.ratio) * 1e23;                                        // Normalization factor from 2 to 27 decimals
        uint128 ink = _balances.ink;                                                        // 1 Oracle Call

        // Debt owed by the vault in underlying terms
        uint128 dues;
        if (block.timestamp >= _series.maturity) {
            // IOracle oracle = rateOracles[_series.baseId];                                 // 1 SLOAD
            dues = _balances.art /*.rmul(oracle.accrual(maturity))*/;                        // 1 Oracle Call
        } else {
            dues = _balances.art;
        }

        return int128(ink.rmul(oracle.spot())) - int128(dues.rmul(ratio));                   // 1 Oracle Call | TODO: SafeCast
    }
}