# Reproducing the invalid-frame warnings

These steps recreate the three framework warnings investigated in
[#757](https://github.com/ZsomborRajki/OpenHikes/issues/757), using a temporary
SwiftUI app. The measured configuration is **Xcode 27.0 (27A266a), iPhone 18
Pro, iOS Simulator 27.0 (24A434), arm64**.

## Set up the temporary app

1. Create a separate iOS App project in Xcode, using Swift and SwiftUI, with
   an iOS 27 deployment target. Keep it outside the OpenHikes checkout.
2. Add this repository's `OpenHikes.storekit` to the temporary project. Select
   it under **Edit Scheme → Run → Options → StoreKit Configuration**. The
   subscription identifier used below must match that fixture.
3. From the OpenHikes checkout, acquire a simulator with
   `Scripts/sim-pool.sh acquire`. Select that pooled device as the temporary
   app's run destination. Keep runtime diagnostics enabled.
4. Make the window's root a blue `Color` at opacity `0.15`. Present a sheet
   from it using a Boolean state initially set to `true`.
5. In that sheet, put a `List` inside a `NavigationStack`. Add navigation
   links titled **Chart** and **Keyboard**, and a **Settings** button that
   presents another sheet. Give the navigation stack the inline title
   **Reproductions**, medium and large presentation detents, and disable
   interactive dismissal of this first sheet.

## Chart: animate a valid elevation domain

1. Make the Chart destination a `ScrollView` containing a `Chart` and a
   **Change Domain** button. Use the inline navigation title **Chart**.
2. Define three elevation samples: `550.0`, `590.0`, and `570.0`. Create one
   `AreaMark` per sample, with x values `0`, `1000`, and `2000`. Set each
   mark's `yStart` to the current domain's lower bound and its `yEnd` to the
   sample's elevation. Use the value labels **Distance**, **Base**, and
   **Elevation**, respectively.
3. Use a Boolean state, initially `false`, to choose between the y domains
   `530...610` and `420...720`. Both domains contain every sample. Set
   `.chartXScale(domain: 0...2000)` and `.chartYScale(domain: domain)`.
4. Customize `.chartYAxis` with `AxisMarks`. For every mark, include an
   `AxisGridLine` and an `AxisValueLabel` whose custom content is a `Text`
   interpolating the axis value as a `Double`, followed by `" m"`.
5. Give the chart the constant `.frame(height: 200)`. Have **Change Domain**
   toggle the Boolean inside `withAnimation`.
6. Run the app, open **Chart**, and tap **Change Domain**. Observe **“Invalid
   frame dimension (negative or non-finite).”** Charts supplies a negative
   height to SwiftUI during the animation, despite the finite data, valid
   domains, and positive chart height. A captured sample was about `−85.06`
   points; the exact transient value can vary.

## Keyboard: use a standard accessory toolbar

1. Make the Keyboard destination a `Form` with a `TextField` titled
   **Title**, bound to string state initially containing **A trail**.
2. Bind the field's focus to a Boolean `@FocusState`. Attach a toolbar to
   the field containing a `ToolbarItemGroup(placement: .keyboard)` with a
   `Spacer` and a **Done** button. Done sets the focus state to `false`.
3. Give the destination the inline navigation title **Keyboard**. No
   explicit frame is needed for the field or toolbar.
4. Return from Chart, open **Keyboard**, tap **Title**, and type. The same
   diagnostic occurs while SwiftUI's `InputAccessoryBar` supplies an
   infinite width and an unspecified height to its frame initializer.
5. Tap **Done**, then return to the first sheet.

## Store: load a subscription above a bottom bar

1. Make the sheet presented by **Settings** contain a `NavigationStack`
   with a `Form`, an inline title **Settings**, and a **Store** button.
   Have that button present a third sheet from inside the form's view
   hierarchy. Put another `NavigationStack` in the third sheet.
2. Its content is a `SubscriptionStoreView(productIDs:)` using
   `tappium.com.OpenHikes.pro.maps.monthly`, the product in
   `OpenHikes.storekit`.
3. For the store view's marketing content, use a `VStack(spacing: 24)` with
   a **Marketing** title and twelve text rows. For each row use
   **Feature N: A paragraph of marketing text that takes several lines.**,
   substituting its index for N. Give the title and rows `.font(.title2)`,
   and give the stack `.padding(20)`.
4. Apply `.subscriptionStoreControlStyle(.prominentPicker)`. With
   `.storeButton`, hide `.restorePurchases` and `.cancellation`, and make
   `.policies` visible.
5. Attach `.safeAreaBar(edge: .bottom)` to the store view. Its content is a
   `VStack(spacing: 6)` holding a **Restore Purchases** button with an empty
   action and `.frame(minHeight: 44)`, followed by the caption **Available
   on all your devices.** Give this stack horizontal padding `20`, bottom
   padding `8`, and `.frame(maxWidth: .infinity)`.
6. Give the store view the inline navigation title **Store**. Add a **Close**
   toolbar button at `.cancellationAction` that calls the environment's
   dismiss action.
7. Open **Settings → Store** and wait for a price and purchase control to
   appear. No purchase or restore is necessary. The diagnostic occurs as
   SwiftUI's `SafeAreaPaddingModifier.insetView(edge:)` supplies width `0`
   and height approximately `−68.33` to its frame initializer.
8. If the screen says **Subscription Unavailable**, check the scheme's
   StoreKit configuration. That state did not reproduce this warning:
   a loaded product is necessary for the layout exercised here.

## Inspect the origin and finish

For a symbolicated stack on the measured toolchain, place an LLDB symbolic
breakpoint on this private SwiftUICore initializer:

```text
$s7SwiftUI12_FrameLayoutV5width6height9alignmentAC12CoreGraphics7CGFloatVSg_AjA9AlignmentVtcfCTf4nnnd_n
```

On this arm64 runtime, `x0` and `x2` contain the width and height as IEEE-754
Double bits; the low bytes of `x1` and `x3` are the Optional tags, where zero
means present. Inspect present negative or non-finite arguments and use `bt`
to capture their callers. The symbol and register assignments are specific
to this toolchain; verify them again on a different runtime. Most hits are
ordinary valid frames.

The matching callers are Charts through `View.frame(width:height:alignment:)`,
SwiftUI's `InputAccessoryBar`, and SwiftUICore's
`SafeAreaPaddingModifier.insetView(edge:)`, respectively. These samples
identify framework diagnostics; they do not establish a visible defect.

Stop the temporary app and debugger, then run `Scripts/sim-pool.sh release`
from the checkout that acquired the device.
