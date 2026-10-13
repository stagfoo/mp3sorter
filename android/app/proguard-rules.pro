# Release builds shrink and minify, and `flutter analyze`/`flutter test`
# never touch Gradle — so a broken release config sits invisible until
# someone actually builds one.

# file_picker and permission_handler are both reached through the plugin
# registrant rather than by direct reference.
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-keep class com.baseflow.permissionhandler.** { *; }
