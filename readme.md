## Objective

Optara aims to provide a secure and capital-transparent protocol for creating, collateralizing, trading, and settling on-chain options.

The protocol enables users to write fully collateralized call and put options, tokenize those positions as transferable assets, trade them through on-chain liquidity venues such as Kuru, and settle them deterministically at expiry.

Its primary objective is to make options trading on-chain simple, transparent, composable, and secure without depending on centralized intermediaries or exposing the protocol to unnecessary leverage and insolvency risk.

## Mission

Optara's mission is to build a secure, transparent, and permissionless options infrastructure where users can create and trade tokenized derivatives while maintaining verifiable collateral backing and predictable settlement.

The protocol separates option issuance and settlement from secondary-market trading so that liquidity providers, traders, and option writers can interact without compromising the solvency of the underlying system.

## Vision

Optara's vision is to become a composable derivatives layer for on-chain markets, where options can be created for digital assets, traded across decentralized liquidity venues, and integrated into broader DeFi applications.

Over time, Optara can evolve from fully collateralized European-style options into a broader derivatives infrastructure supporting multiple assets, expiry structures, trading venues, market makers, and risk-management strategies while preserving strong security guarantees.

## Project Description

Optara is a decentralized options protocol that enables users to create, collateralize, trade, and settle tokenized call and put options on-chain.

Option writers lock collateral into Optara vaults and receive ERC-20 option tokens representing standardized option series defined by an underlying asset, strike price, expiry, and option type. These tokens can then be traded on secondary markets such as Kuru's on-chain order book.

For V1, Optara uses fully collateralized European-style options. Call options are backed by the underlying asset, while put options are backed by the corresponding quote asset. Option holders can freely trade their positions before expiry, but settlement occurs only after expiry using an independent oracle price.

Kuru is used strictly as the trading and price-discovery layer. Optara independently controls collateral, option issuance, expiry, and settlement. This separation ensures that manipulation or illiquidity in the secondary market cannot directly compromise protocol solvency.

Optara charges protocol fees at mint and exercise. They are structured so they can never touch the collateral backing live claims: mint fees are added on top of required collateral rather than taken from it, and exercise fees are carved out of an already-computed payout. Fee rates are fixed per series when the series is created and cannot be changed afterward, so the economics of a position cannot shift once someone has entered it. Kuru's own trading fees are separate, are never received by Optara, and are shown to users as their own line item.

The core security principle of Optara is simple:

**Every outstanding option claim must remain fully backed by collateral regardless of how the option is traded or who currently owns it.**

This allows buyers and sellers to behave adversarially without threatening the solvency of the protocol.

Full specifications live in [simple-workflow/](./simple-workflow/), starting with [simple-workflow/README.md](./simple-workflow/README.md).
