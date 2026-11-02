# DawnMark App Configuration

The Xcode target requires macOS 14 and Swift 6. It compiles only
`Sources/DawnMark`; library modules come from the local packages `.` and
`../appcommerce`.

From the DawnMark package directory:

```sh
./Scripts/generate-project.sh
xcodebuild -project DawnMark.xcodeproj -scheme DawnMark -configuration Debug -derivedDataPath build/Xcode CODE_SIGNING_ALLOWED=NO build
./Scripts/build-app.sh
```

The SwiftPM script assembles `build/DawnMark.app`, including SwiftPM resource
bundles. This is an unsigned, non-sandbox-signed local app, not a distribution
artifact. Use the Xcode target, a development team, and appropriate signing for
sandbox testing and distribution. No app is launched by either script.

## App Icon

Both build paths include `Configuration/AppIcon.icns`, referenced by
`CFBundleIconFile` in `Info.plist`. The icon uses a white geometric Markdown
mark on a rounded square with a dawn gradient: deep teal through softer teal,
a narrow peach transition, and pale apricot gold along the lower edge. The
shadow is restrained, and no additional illustrations are used.

To regenerate all 16-1024 pixel representations and the 1024 pixel PNG preview:

```sh
swift Scripts/generate-icon.swift
```

Quit all DawnMark instances before running `./Scripts/build-app.sh` to update
the local application bundle. After changing `project.yml`, regenerate the
Xcode project with `./Scripts/generate-project.sh`.

## StoreKit

The shared DawnMark scheme uses `DawnMark.storekit` for local StoreKit testing
when launched through Xcode. The file contains a free non-consumable
`com.liaolinrong.DawnMark.trial15days` and a one-time non-consumable
`com.liaolinrong.DawnMark.lifetime` priced at USD 10.00 in the US test storefront.
Both products include native metadata in all 15 locales listed below: 30
localization entries, each with a display name and description (60 text fields).
The English trial name remains "15-day Trial"; the trial remains free and lifetime
access remains USD 10.00. Trial expiration after 15 days is enforced by the app's
commerce policy, not by the StoreKit non-consumable product type.

### Localization / 本地化

| Language / 语言 | CommerceUI Resource / 资源标识 | StoreKit Locale / 商品区域标识 |
| --- | --- | --- |
| English / 英语 | `en` | `en_US` |
| Simplified Chinese / 简体中文 | `zh-Hans` | `zh_Hans` |
| Traditional Chinese / 繁体中文 | `zh-Hant` | `zh_Hant` |
| Japanese / 日语 | `ja` | `ja_JP` |
| Korean / 韩语 | `ko` | `ko_KR` |
| French / 法语 | `fr` | `fr_FR` |
| German / 德语 | `de` | `de_DE` |
| Spanish / 西班牙语 | `es` | `es_ES` |
| Brazilian Portuguese / 巴西葡萄牙语 | `pt-BR` | `pt_BR` |
| European Portuguese / 葡萄牙葡萄牙语 | `pt-PT` | `pt_PT` |
| Italian / 意大利语 | `it` | `it_IT` |
| Dutch / 荷兰语 | `nl` | `nl_NL` |
| Polish / 波兰语 | `pl` | `pl_PL` |
| Turkish / 土耳其语 | `tr` | `tr_TR` |
| Indonesian / 印度尼西亚语 | `id` | `id_ID` |

AppCommerce is an independent package with no dependency on DawnMark. Its optional
CommerceUI has 12 native text keys per language (180 values), uses explicit
language selection, and never silently falls back to English. Its existing
`defaultLocalization: "en"` is a SwiftPM packaging setting, not a runtime fallback.
These StoreKit locales describe product metadata only; they do not change the
host app's language selection or add translations to its other UI.

AppCommerce 是不依赖 DawnMark 的独立包。可选 CommerceUI 的 15 种语言各有
12 个原生文案键，共 180 条文案，显式选择语言，不会静默回退英文。
包中已有的 `defaultLocalization: "en"` 仅用于 SwiftPM 资源打包，并非运行时兜底。
StoreKit 的 15 个 locale 仅覆盖商品元数据，不改变宿主应用语言选择，也不扩充其余应用界面文案。

This configuration simulates transactions and does not create, publish, or
purchase real App Store products. No developer account, App Store Connect
products, agreements, banking, or tax configuration is provided here. The free
non-consumable is a local test fixture. App Review guideline 3.1.1 describes
price-tier-zero trials named "XX-day Trial"; configure the real product using
the currently available App Store Connect workflow and confirm eligibility
during submission. This local file proves neither availability nor approval.

For real sandbox or production transactions, configure the app and supported
products in App Store Connect, complete the required agreements, set real
pricing and localizations, sign the app appropriately, and set the scheme's
StoreKit Configuration to None. A terminal-built app does not activate the
scheme's local StoreKit configuration.

## 本地构建与购买限制

Xcode 工程仅编译 Sources/DawnMark，通过本地 Swift Package 链接其余模块。
build-app.sh 生成的 build/DawnMark.app 包含资源，但未签名，也未通过签名启用沙盒；
正式发布与沙盒验证应使用 Xcode 工程配置开发团队和签名。

DawnMark scheme 的 StoreKit 配置仅用于 Xcode 本地测试：15 天免费试用是
non-consumable 测试商品，试用期限由应用业务规则执行；永久版为一次性购买，
美国测试商店价格为 10.00 美元。两个商品均覆盖上表全部 15 个 locale，
共 30 条本地化记录、60 个名称／描述字段，14 种非英语文案均为原生翻译。
英文试用名称保持为 "15-day Trial"，试用仍为 15 天，价格与商品类型均不变。

这里没有配置开发者账号或 App Store Connect 真实商品，本地交易不扣费，也不会
发布任何真实商品。审核指南 3.1.1 描述了名为“XX-day Trial”的零价格非订阅试用；
真实商品仍需按 App Store Connect 当前流程配置并在提交时确认资格，
本地配置不代表正式商品已可用或通过审核。真实沙盒或正式购买需要单独配置账号、商品、定价、
协议、税务和银行信息，并正确签名，同时将 scheme 的 StoreKit Configuration
设为 None。直接从终端构建或启动不会启用 scheme 的本地 StoreKit 配置。