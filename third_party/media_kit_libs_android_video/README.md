# media_kit_libs_android_video (vendored, PiliPlus)

Vendored copy of `media_kit_libs_android_video` from the media-kit fork
[`My-Responsitories/media-kit`](https://github.com/My-Responsitories/media-kit)
ref `native` @ `73771ec` (package version 1.3.7), which is what this app's
`pubspec.yaml` overrides all media_kit packages to.

**Why vendored:** the `piliplayer` branch ships a VR-patched libmpv for
arm64-v8a (built by `.github/workflows/libmpv_vr.yml` from
`tool/libmpv-vr`, published to this repo's rolling `libmpv-vr` release).
The only local modification is `android/build.gradle`: the arm64-v8a jar is
downloaded from that release instead of the pinned upstream one. The
armeabi-v7a and x86_64 jars (and everything else in this package) are
byte-identical to upstream.

If the upstream fork changes, re-vendor:

    cp -r <media-kit>/libs/android/media_kit_libs_android_video third_party/
    # then re-apply the build.gradle arm64 URL change (git diff shows it)
