# Build SlateHop on macOS

Use an Apple silicon Mac with Xcode, a Rust toolchain, Flutter, CocoaPods, and vcpkg. The public `hbb_common` dependency is pinned as a Git submodule. Initialize it after cloning, then apply the SlateHop change that keeps a macOS app from writing an older daemon password snapshot back to disk. Run the patch command once on a fresh checkout.

```sh
git submodule update --init --recursive
git -C libs/hbb_common apply ../../patches/hbb-common-macos-config.patch
```

Run these commands from the repository root. Set `VCPKG_ROOT` to your vcpkg checkout.

```sh
export MACOSX_DEPLOYMENT_TARGET=12.3
export VCPKG_INSTALLED_ROOT="$VCPKG_ROOT/installed"
export FLUTTER_XCODE_ARCHS=arm64
export FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES
"$VCPKG_ROOT/vcpkg" install --triplet arm64-osx
cargo build --locked --release \
  --features hwcodec,flutter,unix-file-copy-paste,screencapturekit
cp target/release/liblibrustdesk.dylib target/release/librustdesk.dylib
cd flutter
flutter pub get --enforce-lockfile
flutter build macos --release --no-pub
```

The Xcode product is written under `flutter/build/macos/Build/Products/Release/`. Its display name is SlateHop. Configure macOS code signing for the app and its embedded frameworks before distributing a build.
