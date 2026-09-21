// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {
    OptionType,
    FeeConfig,
    PairConfig,
    CreateSeriesParams,
    SeriesConfig,
    MAX_MINT_FEE_BPS,
    MAX_EXERCISE_FEE_BPS,
    MIN_EXPIRY_DELAY,
    MAX_EXPIRY_DELAY,
    EXPIRY_SLOT_OFFSET,
    OPTION_DECIMALS,
    MIN_OPTION_AMOUNT,
    PAUSER_ROLE
} from "./Types.sol";
import {
    ZeroAddress,
    AssetNotAllowed,
    InvalidDecimals,
    InvalidStrike,
    InvalidExpiry,
    InvalidOracleConfig,
    DuplicateSeries,
    CreationPaused,
    FeedNotApproved,
    FeeExceedsCap,
    KuruMarketAlreadySet,
    SeriesNotFound,
    Unauthorized
} from "./Errors.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IVaultDeployer} from "./interfaces/IVaultDeployer.sol";

/// @title OptionSeriesFactory
/// @notice Lets ANYONE create an option series within fixed limits, and is the canonical registry of official
///         series. Also holds the two roles and the global settings. See simple-workflow/contracts.md.
///
/// A user chooses only: option type, the two assets, the strike, the expiry and the feed. The feed must be the
/// one ADMIN approved for that pair, so a user can never attach a different one. Everything else (contract
/// size, option decimals, minimum amount, open-interest cap, age window, fees, names) is fixed by this contract.
///
/// Roles (OpenZeppelin AccessControl): ADMIN (DEFAULT_ADMIN_ROLE) and PAUSER. There is no creator role.
/// No role can move collateral, change a live series, change a settlement result, or block settle / redeem /
/// claim / payout / transfers. The only switches are a freeze on minting (per series) and a freeze on creation.
contract OptionSeriesFactory is AccessControl, ReentrancyGuard {
    /// @notice Deploys the vaults. It holds the vault creation code so this contract stays under the size limit.
    IVaultDeployer public immutable deployer;

    // ------------------------------------------------------------------ settings

    mapping(address => bool) public allowedAsset;
    mapping(bytes32 => PairConfig) public pairConfig; // key = pairKey(underlying, quote)
    mapping(address => uint256) public maxShortAmountOf; // per underlying, option raw units, 0 = uncapped
    FeeConfig public defaultFeeConfig; // snapshotted into each NEW series
    address public feeRecipient; // read live at sweep time, never snapshotted

    bool public creationPaused;
    uint256 public seriesCount; // used only to generate names

    // ------------------------------------------------------------------ registry

    mapping(bytes32 => address) public vaultOf; // seriesId -> vault
    mapping(address => bytes32) public seriesIdOf; // vault -> seriesId, nonzero means official
    mapping(bytes32 => address) public kuruMarketOf; // write-once pointer, optional

    // ------------------------------------------------------------------ events

    event SeriesCreated(
        bytes32 indexed seriesId,
        address indexed vault,
        address indexed creator,
        OptionType optionType,
        address underlying,
        address quote,
        uint256 strikePrice,
        uint64 expiry,
        address chainlinkFeed
    );
    event PairConfigSet(bytes32 indexed pairKey, address feed, uint32 maxChainlinkAgeAtExpiry, uint256 strikeStep);
    event AssetAllowed(address indexed asset, bool allowed);
    event MaxShortAmountSet(address indexed underlying, uint256 amount);
    event DefaultFeeConfigSet(uint16 mintFeeBps, uint16 exerciseFeeBps);
    event FeeRecipientSet(address indexed recipient);
    event CreationPauseSet(bool paused);
    event KuruMarketSet(bytes32 indexed seriesId, address indexed market);

    /// @param admin the initial ADMIN (the deployer, who then hands the role to a multisig and renounces)
    /// @param deployer_ a fresh VaultDeployer. The factory binds itself to it here and verifies the binding.
    constructor(address admin, IVaultDeployer deployer_) {
        if (admin == address(0) || address(deployer_) == address(0)) revert ZeroAddress();
        deployer_.bind();
        if (deployer_.factory() != address(this)) revert Unauthorized();
        deployer = deployer_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------ creation

    /// @notice Create a series. Callable by anyone. Reverts on any invalid input and on a duplicate.
    function createSeries(CreateSeriesParams calldata p)
        external
        nonReentrant
        returns (bytes32 seriesId, address vault)
    {
        if (creationPaused) revert CreationPaused();

        // assets
        if (p.underlying == address(0) || p.quote == address(0)) revert ZeroAddress();
        if (p.underlying == p.quote) revert AssetNotAllowed();
        if (!allowedAsset[p.underlying] || !allowedAsset[p.quote]) revert AssetNotAllowed();
        uint8 underlyingDecimals = _decimalsOf(p.underlying);
        _decimalsOf(p.quote); // must be readable and at most 18

        // feed: must be exactly the one ADMIN approved for this pair
        PairConfig memory pc = pairConfig[pairKey(p.underlying, p.quote)];
        if (pc.feed == address(0) || p.chainlinkFeed != pc.feed) revert FeedNotApproved();

        // strike
        if (p.strikePrice == 0 || p.strikePrice % pc.strikeStep != 0) revert InvalidStrike();

        // expiry: at least an hour away, at most 30 days away, on the daily 08:00 UTC slot
        if (
            p.expiry < block.timestamp + MIN_EXPIRY_DELAY || p.expiry > block.timestamp + MAX_EXPIRY_DELAY
                || p.expiry % 1 days != EXPIRY_SLOT_OFFSET
        ) revert InvalidExpiry();

        // identity: a duplicate ALWAYS reverts, there is no idempotent return
        seriesId = _computeSeriesId(p);
        if (vaultOf[seriesId] != address(0)) revert DuplicateSeries(seriesId);

        uint256 n = ++seriesCount;
        SeriesConfig memory c = SeriesConfig({
            optionType: p.optionType,
            underlying: p.underlying,
            quote: p.quote,
            strikePrice: p.strikePrice,
            expiry: p.expiry,
            contractSize: 10 ** uint256(underlyingDecimals), // exactly one whole underlying per option
            optionDecimals: OPTION_DECIMALS,
            minOptionAmount: MIN_OPTION_AMOUNT,
            maxTotalShortAmount: maxShortAmountOf[p.underlying],
            chainlinkFeed: pc.feed,
            maxChainlinkAgeAtExpiry: pc.maxChainlinkAgeAtExpiry,
            name: "",
            symbol: ""
        });
        (c.name, c.symbol) = _metadata(p.optionType, p.underlying, p.quote, n);

        vault = deployer.deploy(seriesId, c, defaultFeeConfig);

        vaultOf[seriesId] = vault;
        seriesIdOf[vault] = seriesId;

        emit SeriesCreated(
            seriesId, vault, msg.sender, p.optionType, p.underlying, p.quote, p.strikePrice, p.expiry, pc.feed
        );
    }

    function computeSeriesId(CreateSeriesParams calldata p) external view returns (bytes32) {
        return _computeSeriesId(p);
    }

    function _computeSeriesId(CreateSeriesParams calldata p) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid, address(this), p.optionType, p.underlying, p.quote, p.strikePrice, p.expiry, p.chainlinkFeed
            )
        );
    }

    /// @notice True only for vaults this factory deployed. Names, symbols and Kuru listings prove nothing.
    function isOptionToken(address token) external view returns (bool) {
        return seriesIdOf[token] != bytes32(0);
    }

    function pairKey(address underlying, address quote) public pure returns (bytes32) {
        return keccak256(abi.encode(underlying, quote));
    }

    // ------------------------------------------------------------------ ADMIN: settings

    /// @notice Allowlist an asset. Only after confirming it is a standard ERC-20: non-rebasing, no transfer fee,
    ///         no re-entering hooks, stable readable decimals. The vault does not measure balance deltas, so this
    ///         allowlist is the only defense against fee-on-transfer and rebasing tokens.
    function setAllowedAsset(address asset, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (allowed) _decimalsOf(asset); // readable and at most 18
        allowedAsset[asset] = allowed;
        emit AssetAllowed(asset, allowed);
    }

    /// @notice Approve the ONE Chainlink feed for a pair, with its age window and strike step. Setting `feed` to
    ///         address(0) disables the pair for new series. Affects only series created afterward.
    /// @dev Approving a feed is the most security-critical action in the system: a series cannot be corrected
    ///      once created with it. Two people must confirm that the feed is a direct feed for exactly this pair.
    function setPairConfig(address underlying, address quote, PairConfig calldata c)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        bytes32 key = pairKey(underlying, quote);
        if (c.feed == address(0)) {
            delete pairConfig[key];
            emit PairConfigSet(key, address(0), 0, 0);
            return;
        }
        if (!allowedAsset[underlying] || !allowedAsset[quote]) revert AssetNotAllowed();
        if (c.maxChainlinkAgeAtExpiry == 0 || c.strikeStep == 0) revert InvalidOracleConfig();
        _checkFeed(c.feed);

        pairConfig[key] = c;
        emit PairConfigSet(key, c.feed, c.maxChainlinkAgeAtExpiry, c.strikeStep);
    }

    /// @notice Open-interest cap for future series of this underlying, in option raw units. 0 = uncapped.
    function setMaxShortAmount(address underlying, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxShortAmountOf[underlying] = amount;
        emit MaxShortAmountSet(underlying, amount);
    }

    /// @notice Fee rates for future series. Rates are snapshotted into each series and never change after.
    function setDefaultFeeConfig(FeeConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cfg.mintFeeBps > MAX_MINT_FEE_BPS || cfg.exerciseFeeBps > MAX_EXERCISE_FEE_BPS) revert FeeExceedsCap();
        defaultFeeConfig = cfg;
        emit DefaultFeeConfigSet(cfg.mintFeeBps, cfg.exerciseFeeBps);
    }

    /// @notice Where swept fees go. Read live at sweep time, so a compromised treasury can be rotated.
    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    /// @notice Optional pointer from a series to its official Kuru market. Write-once. The contracts never call
    ///         Kuru; the pointer only lets the guard and the frontend tell which market is official.
    function setKuruMarket(bytes32 seriesId, address market) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vaultOf[seriesId] == address(0)) revert SeriesNotFound();
        if (market == address(0)) revert ZeroAddress();
        if (kuruMarketOf[seriesId] != address(0)) revert KuruMarketAlreadySet();
        kuruMarketOf[seriesId] = market;
        emit KuruMarketSet(seriesId, market);
    }

    // ------------------------------------------------------------------ freeze creation

    /// @notice Freeze or unfreeze series creation. PAUSER or ADMIN can freeze; only ADMIN can unfreeze, so a
    ///         compromised PAUSER cannot undo a freeze. Existing series are not affected in any way.
    function setCreationPaused(bool paused) external {
        if (paused) {
            if (!hasRole(PAUSER_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                revert AccessControlUnauthorizedAccount(msg.sender, PAUSER_ROLE);
            }
        } else if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, DEFAULT_ADMIN_ROLE);
        }
        creationPaused = paused;
        emit CreationPauseSet(paused);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Token name and symbol, generated here so nothing a user types can reach the metadata. They always
    ///      carry the REAL pair, read from the two tokens' own symbols (which ADMIN vetted when it allowlisted
    ///      them), plus the option type and a running number for uniqueness:
    ///        name   "Optara WMON/USDC Call #1"
    ///        symbol "OPT-WMON-USDC-C-1"
    ///      Strike and expiry are not in the name: read them from `seriesInfo()`.
    function _metadata(OptionType t, address underlying, address quote, uint256 n)
        private
        view
        returns (string memory name, string memory symbol)
    {
        string memory u = _symbolOf(underlying);
        string memory q = _symbolOf(quote);
        string memory id = Strings.toString(n);
        bool isCall = t == OptionType.CALL;
        name = string.concat("Optara ", u, "/", q, isCall ? " Call #" : " Put #", id);
        symbol = string.concat("OPT-", u, "-", q, isCall ? "-C-" : "-P-", id);
    }

    /// @dev A token's own symbol, or "?" if it cannot be read, so a token without symbol() never blocks creation.
    function _symbolOf(address token) private view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            return s;
        } catch {
            return "?";
        }
    }

    /// @dev Decimals must be readable and at most 18. A token with no code or a reverting decimals() is rejected.
    function _decimalsOf(address token) private view returns (uint8) {
        if (token.code.length == 0) revert InvalidDecimals();
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            if (d > 18) revert InvalidDecimals();
            return d;
        } catch {
            revert InvalidDecimals();
        }
    }

    /// @dev The feed must have code, readable decimals of at most 18, and a positive latest answer.
    function _checkFeed(address feed) private view {
        if (feed.code.length == 0) revert InvalidOracleConfig();
        try IAggregatorV3(feed).decimals() returns (uint8 d) {
            if (d > 18) revert InvalidOracleConfig();
        } catch {
            revert InvalidOracleConfig();
        }
        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0) revert InvalidOracleConfig();
        } catch {
            revert InvalidOracleConfig();
        }
    }
}
