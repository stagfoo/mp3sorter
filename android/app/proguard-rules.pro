# Release builds shrink and minify, and `flutter analyze`/`flutter test`
# never touch Gradle — so a broken release config sits invisible until
# someone actually builds one.

# file_picker and permission_handler are both reached through the plugin
# registrant rather than by direct reference.
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-keep class com.baseflow.permissionhandler.** { *; }

# just_audio plays through ExoPlayer (androidx.media3), parts of which are
# found reflectively — extractors in particular. Minified away, a release
# build loads a file and then sits in an error state with nothing logged.
-keep class com.ryanheise.just_audio.** { *; }
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**
