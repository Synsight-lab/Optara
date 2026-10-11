# Optara contracts on Monad testnet

Every contract the Monad testnet deployment created, with links to its verified source.

| | |
|---|---|
| Network | Monad testnet (chain ID 10143) |
| Deployed at block | 70,216,680 |
| Deployer | `0xfa42adb8200b8Cc2296D1848B563c205d28620e9` |
| Roles (governance, guardian, council, admins) | `0xbCe599D231e83594F47bFA2805bb8D8dF3D578bd` |
| Machine-readable manifest | [`monad-testnet.json`](monad-testnet.json) |

## Verification

All 47 contracts below are source-verified, status `match`, on both:

- [Sourcify](https://sourcify.dev) (the "Sourcify" links below), and
- MonadVision's own Sourcify instance (`https://sourcify-api-monad.blockvision.org/`), which is what the MonadVision explorer shows.

`exact_match` is not possible because the build sets `bytecode_hash = "none"`, so the bytecode carries no metadata hash. The 16 option tokens are EIP-1167 clones of the verified `ExternalOptionWrapper`.

To verify a contract on MonadVision (note the trailing slash on the URL):

```sh
forge verify-contract <address> <path>:<Contract> --chain 10143 --verifier sourcify \
  --verifier-url https://sourcify-api-monad.blockvision.org/ --rpc-url https://testnet-rpc.monad.xyz
```

## Core protocol

Use the **proxy** address to interact with each contract. The implementation holds the code; the ProxyAdmin, owned by UpgradeAdmin, is the only account that can upgrade it.

| Contract | Proxy (use this) | Implementation | ProxyAdmin |
|---|---|---|---|
| ExternalOptionFactory | `0xdFf864f9bd093e0eFFa13Af807efb1CA3621bF98`<br>[Sourcify](https://repo.sourcify.dev/10143/0xdFf864f9bd093e0eFFa13Af807efb1CA3621bF98) · [MonadVision](https://testnet.monadvision.com/address/0xdFf864f9bd093e0eFFa13Af807efb1CA3621bF98) | `0xbC0795A0855A1DDaf1E579Ff6c67Cc4806C7Fa3B`<br>[Sourcify](https://repo.sourcify.dev/10143/0xbC0795A0855A1DDaf1E579Ff6c67Cc4806C7Fa3B) | `0xE9300fEA1108AeCd49918F6F802b9C0893FE50Fa`<br>[Sourcify](https://repo.sourcify.dev/10143/0xE9300fEA1108AeCd49918F6F802b9C0893FE50Fa) |
| FeeController | `0x2277eE16E766A2b750E92AF1900a1365a5191c4F`<br>[Sourcify](https://repo.sourcify.dev/10143/0x2277eE16E766A2b750E92AF1900a1365a5191c4F) · [MonadVision](https://testnet.monadvision.com/address/0x2277eE16E766A2b750E92AF1900a1365a5191c4F) | `0x4787C983502C94530FA831cFe23DeECcbAa77458`<br>[Sourcify](https://repo.sourcify.dev/10143/0x4787C983502C94530FA831cFe23DeECcbAa77458) | `0x64f07853e65c7D1C8FE818F3Da6A8A917c29050E`<br>[Sourcify](https://repo.sourcify.dev/10143/0x64f07853e65c7D1C8FE818F3Da6A8A917c29050E) |
| InsuranceFund | `0x9E4E1aCB01B51cC483F25f9CDa6FbA806EB948ac`<br>[Sourcify](https://repo.sourcify.dev/10143/0x9E4E1aCB01B51cC483F25f9CDa6FbA806EB948ac) · [MonadVision](https://testnet.monadvision.com/address/0x9E4E1aCB01B51cC483F25f9CDa6FbA806EB948ac) | `0x60196fD13df523E8FF31937f1170f4c908cF5437`<br>[Sourcify](https://repo.sourcify.dev/10143/0x60196fD13df523E8FF31937f1170f4c908cF5437) | `0x8A3eE509b6B506c07215077D21142D0403107978`<br>[Sourcify](https://repo.sourcify.dev/10143/0x8A3eE509b6B506c07215077D21142D0403107978) |
| LiquidationModule | `0x4c317CD9c6E1F1Ce4D1DaBf93fFa97eC87475078`<br>[Sourcify](https://repo.sourcify.dev/10143/0x4c317CD9c6E1F1Ce4D1DaBf93fFa97eC87475078) · [MonadVision](https://testnet.monadvision.com/address/0x4c317CD9c6E1F1Ce4D1DaBf93fFa97eC87475078) | `0x975f77C3F1A2AfedEDE326Bdc4175a808De3254B`<br>[Sourcify](https://repo.sourcify.dev/10143/0x975f77C3F1A2AfedEDE326Bdc4175a808De3254B) | `0x54ab04Ceaa54970C803F7B580307679c1fC69e1F`<br>[Sourcify](https://repo.sourcify.dev/10143/0x54ab04Ceaa54970C803F7B580307679c1fC69e1F) |
| LiveSpotOracle | `0xcE84cBaCe30ab04e4a55189522286f370c541Dec`<br>[Sourcify](https://repo.sourcify.dev/10143/0xcE84cBaCe30ab04e4a55189522286f370c541Dec) · [MonadVision](https://testnet.monadvision.com/address/0xcE84cBaCe30ab04e4a55189522286f370c541Dec) | `0x902A19f36548F8cC0e75aED25efb60F1F1ea4761`<br>[Sourcify](https://repo.sourcify.dev/10143/0x902A19f36548F8cC0e75aED25efb60F1F1ea4761) | `0x26C052AD4E2670C72437945E04892afadeB86CCe`<br>[Sourcify](https://repo.sourcify.dev/10143/0x26C052AD4E2670C72437945E04892afadeB86CCe) |
| OptionClearing | `0x6fe9A734DC66A147fCA911b2e3a81D99c57d059F`<br>[Sourcify](https://repo.sourcify.dev/10143/0x6fe9A734DC66A147fCA911b2e3a81D99c57d059F) · [MonadVision](https://testnet.monadvision.com/address/0x6fe9A734DC66A147fCA911b2e3a81D99c57d059F) | `0xe53cdd3Dc110DAfa7c315c5997c9E5011EfD3B2C`<br>[Sourcify](https://repo.sourcify.dev/10143/0xe53cdd3Dc110DAfa7c315c5997c9E5011EfD3B2C) | `0xEcDbbA3A525c6f9DB6F0392bD302FD68ca36AC99`<br>[Sourcify](https://repo.sourcify.dev/10143/0xEcDbbA3A525c6f9DB6F0392bD302FD68ca36AC99) |
| OptionSeriesRegistry | `0x9EA49027F518706bE3fa62D85bf3e0740243ee02`<br>[Sourcify](https://repo.sourcify.dev/10143/0x9EA49027F518706bE3fa62D85bf3e0740243ee02) · [MonadVision](https://testnet.monadvision.com/address/0x9EA49027F518706bE3fa62D85bf3e0740243ee02) | `0x5ca33981Ab19B6d48C816DAd3E41CFB76b905922`<br>[Sourcify](https://repo.sourcify.dev/10143/0x5ca33981Ab19B6d48C816DAd3E41CFB76b905922) | `0x2004435BE6bc2187FE12226956e3B9da7868CAE3`<br>[Sourcify](https://repo.sourcify.dev/10143/0x2004435BE6bc2187FE12226956e3B9da7868CAE3) |
| PortfolioRiskManager | `0x0451aa6e58485C24a916De1b8387FD7C46B3408d`<br>[Sourcify](https://repo.sourcify.dev/10143/0x0451aa6e58485C24a916De1b8387FD7C46B3408d) · [MonadVision](https://testnet.monadvision.com/address/0x0451aa6e58485C24a916De1b8387FD7C46B3408d) | `0x7b538E62C1fCe34f940EaAd5155B29E88CA5E5D7`<br>[Sourcify](https://repo.sourcify.dev/10143/0x7b538E62C1fCe34f940EaAd5155B29E88CA5E5D7) | `0x28Eb05B9F8D3A6CFa26f3f3C7e63D0bD6F1159fe`<br>[Sourcify](https://repo.sourcify.dev/10143/0x28Eb05B9F8D3A6CFa26f3f3C7e63D0bD6F1159fe) |
| ProtocolControl | `0xD4f274160bE988920A8605ab949Ad7b10307B491`<br>[Sourcify](https://repo.sourcify.dev/10143/0xD4f274160bE988920A8605ab949Ad7b10307B491) · [MonadVision](https://testnet.monadvision.com/address/0xD4f274160bE988920A8605ab949Ad7b10307B491) | `0x4CA66330ff6B45E205d54962C663195689adab7d`<br>[Sourcify](https://repo.sourcify.dev/10143/0x4CA66330ff6B45E205d54962C663195689adab7d) | `0x1dd5b5Cae299C2fb34d58968a2a39795c838aB60`<br>[Sourcify](https://repo.sourcify.dev/10143/0x1dd5b5Cae299C2fb34d58968a2a39795c838aB60) |
| SettlementOracle | `0x2bB5d1eCe911adFd629332c9539889d2AdcfCbc7`<br>[Sourcify](https://repo.sourcify.dev/10143/0x2bB5d1eCe911adFd629332c9539889d2AdcfCbc7) · [MonadVision](https://testnet.monadvision.com/address/0x2bB5d1eCe911adFd629332c9539889d2AdcfCbc7) | `0x1e0d42A6034A65D6ECf6Dd983212a7407F16432A`<br>[Sourcify](https://repo.sourcify.dev/10143/0x1e0d42A6034A65D6ECf6Dd983212a7407F16432A) | `0x6772A39CFe1f85A401639a49DAf6F943c50afa1e`<br>[Sourcify](https://repo.sourcify.dev/10143/0x6772A39CFe1f85A401639a49DAf6F943c50afa1e) |
| SettlementWindow | `0x4B0AaBfaA36Ca99F1dC2927b43f102bd5ce67C76`<br>[Sourcify](https://repo.sourcify.dev/10143/0x4B0AaBfaA36Ca99F1dC2927b43f102bd5ce67C76) · [MonadVision](https://testnet.monadvision.com/address/0x4B0AaBfaA36Ca99F1dC2927b43f102bd5ce67C76) | `0xD7827384fDb348fe0b709f8E208466Abd82E3bB4`<br>[Sourcify](https://repo.sourcify.dev/10143/0xD7827384fDb348fe0b709f8E208466Abd82E3bB4) | `0x229692E5A16C9166758eC39F78379b35af885082`<br>[Sourcify](https://repo.sourcify.dev/10143/0x229692E5A16C9166758eC39F78379b35af885082) |
| SubAccounts | `0xf5ED8E0dEBA6aBe0EAF3FB11c3C8654C2e077Da1`<br>[Sourcify](https://repo.sourcify.dev/10143/0xf5ED8E0dEBA6aBe0EAF3FB11c3C8654C2e077Da1) · [MonadVision](https://testnet.monadvision.com/address/0xf5ED8E0dEBA6aBe0EAF3FB11c3C8654C2e077Da1) | `0x140B21d4837dd6B43ce32DB82AAa8138b636945d`<br>[Sourcify](https://repo.sourcify.dev/10143/0x140B21d4837dd6B43ce32DB82AAa8138b636945d) | `0x2C614af49bF20d773bd4dDB90F2550d3B5CF626e`<br>[Sourcify](https://repo.sourcify.dev/10143/0x2C614af49bF20d773bd4dDB90F2550d3B5CF626e) |
| VenueRegistry | `0x2FD1166Df458e430c123A40b9944951002de4e28`<br>[Sourcify](https://repo.sourcify.dev/10143/0x2FD1166Df458e430c123A40b9944951002de4e28) · [MonadVision](https://testnet.monadvision.com/address/0x2FD1166Df458e430c123A40b9944951002de4e28) | `0x9E3806DD25D60D00bd46f652F140eD99514f86e0`<br>[Sourcify](https://repo.sourcify.dev/10143/0x9E3806DD25D60D00bd46f652F140eD99514f86e0) | `0xF2282CE902fF6c16a1229E093Ba8B4963324362d`<br>[Sourcify](https://repo.sourcify.dev/10143/0xF2282CE902fF6c16a1229E093Ba8B4963324362d) |
| VenueRouter | `0x39418f4F08367eD8998c19b923f2809E3FD6e97F`<br>[Sourcify](https://repo.sourcify.dev/10143/0x39418f4F08367eD8998c19b923f2809E3FD6e97F) · [MonadVision](https://testnet.monadvision.com/address/0x39418f4F08367eD8998c19b923f2809E3FD6e97F) | `0x9B61D3A07de04D4Ee75fc6a6e8F7F5b7429A672F`<br>[Sourcify](https://repo.sourcify.dev/10143/0x9B61D3A07de04D4Ee75fc6a6e8F7F5b7429A672F) | `0x9eAf0fED4cB66B1262643c59d3a847297e80dF52`<br>[Sourcify](https://repo.sourcify.dev/10143/0x9eAf0fED4cB66B1262643c59d3a847297e80dF52) |
| VolSurfaceOracle | `0xbE20AcFDEf10FA225933c39E167aAae8781d2904`<br>[Sourcify](https://repo.sourcify.dev/10143/0xbE20AcFDEf10FA225933c39E167aAae8781d2904) · [MonadVision](https://testnet.monadvision.com/address/0xbE20AcFDEf10FA225933c39E167aAae8781d2904) | `0x489bac486615726a1c3f0b32a82273734F1d9166`<br>[Sourcify](https://repo.sourcify.dev/10143/0x489bac486615726a1c3f0b32a82273734F1d9166) | `0x66f16C96293D632B3d6F819F5Da9E3eB66B67C58`<br>[Sourcify](https://repo.sourcify.dev/10143/0x66f16C96293D632B3d6F819F5Da9E3eB66B67C58) |

## Governance and templates

| Contract | Address | Role |
|---|---|---|
| UpgradeAdmin | `0xCb38332B51cb714CD9e42300Ba9A6e1dDbbDd559`<br>[Sourcify](https://repo.sourcify.dev/10143/0xCb38332B51cb714CD9e42300Ba9A6e1dDbbDd559) · [MonadVision](https://testnet.monadvision.com/address/0xCb38332B51cb714CD9e42300Ba9A6e1dDbbDd559) | Timelocked upgrades (7-day delay, 1-day emergency) for every proxy |
| ExternalOptionWrapper (implementation) | `0x324EAd492834806f62931015B0AA1E8dc6729119`<br>[Sourcify](https://repo.sourcify.dev/10143/0x324EAd492834806f62931015B0AA1E8dc6729119) · [MonadVision](https://testnet.monadvision.com/address/0x324EAd492834806f62931015B0AA1E8dc6729119) | ERC-20 template cloned for each option series |

## Option tokens (ETH/USDC)

Contract size 1 ETH, settled in USDC. Expiries are at 08:00 UTC.

| Option | Expiry | Token | Series ID |
|---|---|---|---|
| ETH 2,200 Call | 16 Oct 2026 | `0x6aBa41a4F9bdc703e728354765b97d5fD26D5764`<br>[MonadVision](https://testnet.monadvision.com/address/0x6aBa41a4F9bdc703e728354765b97d5fD26D5764) | `0xc70773a2…5fe0` |
| ETH 2,200 Put | 16 Oct 2026 | `0x2AF9270F958c3E898fe5FcF7333212e545b3d81f`<br>[MonadVision](https://testnet.monadvision.com/address/0x2AF9270F958c3E898fe5FcF7333212e545b3d81f) | `0xba7abd8b…73e4` |
| ETH 2,400 Call | 16 Oct 2026 | `0x54564408E9d8ebF606C731dcEDF05393C84531Aa`<br>[MonadVision](https://testnet.monadvision.com/address/0x54564408E9d8ebF606C731dcEDF05393C84531Aa) | `0xe9fd5fe5…8c4e` |
| ETH 2,400 Put | 16 Oct 2026 | `0x46C2d4FA8e1fed263882E3b9c5CD056eED76DA5b`<br>[MonadVision](https://testnet.monadvision.com/address/0x46C2d4FA8e1fed263882E3b9c5CD056eED76DA5b) | `0x9b747f65…6034` |
| ETH 2,600 Call | 16 Oct 2026 | `0x3b42C1dBe01a4e2516Fc87ab547A1C0eDF8C6118`<br>[MonadVision](https://testnet.monadvision.com/address/0x3b42C1dBe01a4e2516Fc87ab547A1C0eDF8C6118) | `0xc2752178…7ea0` |
| ETH 2,600 Put | 16 Oct 2026 | `0x3a20b12A149375DAC898A01e3Cf96Ad7c394D88B`<br>[MonadVision](https://testnet.monadvision.com/address/0x3a20b12A149375DAC898A01e3Cf96Ad7c394D88B) | `0x79797a47…de8a` |
| ETH 2,800 Call | 16 Oct 2026 | `0x9f8aA16cc27f19bBb4Bf59E15f6D2D20b14D1Ff0`<br>[MonadVision](https://testnet.monadvision.com/address/0x9f8aA16cc27f19bBb4Bf59E15f6D2D20b14D1Ff0) | `0x0d47f42c…6ef8` |
| ETH 2,800 Put | 16 Oct 2026 | `0x4Fc8dC147A9e8078D7657A0B05bD645B21774F19`<br>[MonadVision](https://testnet.monadvision.com/address/0x4Fc8dC147A9e8078D7657A0B05bD645B21774F19) | `0xd087cad5…7848` |
| ETH 2,200 Call | 23 Oct 2026 | `0x053627C71321cDdc23705dadaddC91A6e5BCe368`<br>[MonadVision](https://testnet.monadvision.com/address/0x053627C71321cDdc23705dadaddC91A6e5BCe368) | `0x76d9277f…7dfd` |
| ETH 2,200 Put | 23 Oct 2026 | `0x824E0072Cffb3f5523888109B5D295d99aBa3136`<br>[MonadVision](https://testnet.monadvision.com/address/0x824E0072Cffb3f5523888109B5D295d99aBa3136) | `0x465ee143…a22d` |
| ETH 2,400 Call | 23 Oct 2026 | `0xe6af56dbE0a05fb8a44D8aBcA0950974Af05b2A5`<br>[MonadVision](https://testnet.monadvision.com/address/0xe6af56dbE0a05fb8a44D8aBcA0950974Af05b2A5) | `0xbb364c62…e58c` |
| ETH 2,400 Put | 23 Oct 2026 | `0x41e032a7b56bfdc3E782559da443C122D1fB8B34`<br>[MonadVision](https://testnet.monadvision.com/address/0x41e032a7b56bfdc3E782559da443C122D1fB8B34) | `0x07b89f51…01e4` |
| ETH 2,600 Call | 23 Oct 2026 | `0xF6F52718BEA70b2f6726f381F32449Fca07C8Ed3`<br>[MonadVision](https://testnet.monadvision.com/address/0xF6F52718BEA70b2f6726f381F32449Fca07C8Ed3) | `0xf07887db…f0d7` |
| ETH 2,600 Put | 23 Oct 2026 | `0xBE96eFb30412AAf1b504fB16B997425d9B0612d2`<br>[MonadVision](https://testnet.monadvision.com/address/0xBE96eFb30412AAf1b504fB16B997425d9B0612d2) | `0xe15edac7…9cb4` |
| ETH 2,800 Call | 23 Oct 2026 | `0xB6061f36075Bc0CD6aF13947CE7539844384189f`<br>[MonadVision](https://testnet.monadvision.com/address/0xB6061f36075Bc0CD6aF13947CE7539844384189f) | `0x1a6335e1…d0c7` |
| ETH 2,800 Put | 23 Oct 2026 | `0xB85b245826fd90a88AD8f5ed84a4f53B6dB6af9d`<br>[MonadVision](https://testnet.monadvision.com/address/0xB85b245826fd90a88AD8f5ed84a4f53B6dB6af9d) | `0xad9309ee…d3d1` |

## External dependencies (not deployed by Optara)

| Contract | Address |
|---|---|
| USDC | `0x534b2f3A21130d7a60830c2Df862319e593943A3` |
| WETH | `0x45477f4709771331db81944A5E20eF95Bc7BA2D7` |
| Chainlink ETH/USD | `0x5c8c8482f064049248F86D9F4aFa4B1f2F5b6d31` |
| Chainlink USDC/USD | `0x39820e7965e29DC86b94F20eD04e9c5cCf9aFf95` |
| Pyth | `0x2880aB155794e7179c9eE2e38200202908C17B43` |
