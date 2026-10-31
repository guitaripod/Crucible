# Crucible Pro products

One app record (App Store Connect app 6822066419, bundle id `com.guitaripod.crucible`, iOS and tvOS versions) and two products. Until 2.3.0 they were sold through RevenueCat (project `projad1befc4`); from 2.4.0 through MidgarKit's MidgarStore, both granting the `pro` entitlement in the Midgar ledger.

| Product id | Type | Price | Notes |
|---|---|---|---|
| `com.guitaripod.crucible.pro.lifetime` | non-consumable | $17.99 until 2026-12-07, then $24.99 | Family Sharing on; the rise is a scheduled price in App Store Connect |
| `com.guitaripod.crucible.pro.yearly` | auto-renewable, group "Crucible Pro" | $7.99 per year | Family Sharing on; no introductory offer (the 14-day free trial was removed on 2026-10-31, Midgar D22) |

Created with the `asc` CLI:

```
asc iap setup --app 6822066419 --type NON_CONSUMABLE --reference-name "Crucible Pro Lifetime" \
  --product-id com.guitaripod.crucible.pro.lifetime --display-name "Crucible Pro Lifetime" \
  --description "Pay once. Every update, on every device." --locale en-US --family-sharable \
  --price 17.99 --base-territory "United States"
asc iap pricing schedules create --iap-id <iap id> --base-territory USA \
  --prices "<17.99 price point>::2026-12-07,<24.99 price point>:2026-12-07"
asc subscriptions setup --app 6822066419 --group-reference-name "Crucible Pro" --group-display-name "Crucible Pro" \
  --group-locale en-US --reference-name "Crucible Pro Annual" --product-id com.guitaripod.crucible.pro.yearly \
  --subscription-period ONE_YEAR --display-name "Crucible Pro Annual" --description "Downloads, full Statistics and Top Shelf." \
  --locale en-US --family-sharable --price 7.99 --price-territory "United States" --territories <every territory but CHN>
asc subscriptions offers introductory import --subscription-id <sub id> --input offers.csv \
  --offer-duration TWO_WEEKS --offer-mode FREE_TRIAL --number-of-periods 1 --confirm
```

Both stay MISSING_METADATA until each has its review screenshot and rides the first version submission (Apple's first-product rule). `scripts/asc-setup.py` writes the listing and review details for both platform versions; `scripts/asc-products.py` attaches the review screenshots and review notes.

The App Store build reads the products through StoreKit with MidgarStore (`Sources/CrucibleStore/MidgarProAccess.swift`), buys with the Midgar ID as the app account token and watches the `pro` entitlement. `Tests/CrucibleStoreTests` checks the offers and the entitlement mapping against `Products.storekit`.
