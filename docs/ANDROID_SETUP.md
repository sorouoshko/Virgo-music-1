# Android media permission

After running `flutter create .` in this directory, merge the following permissions into `android/app/src/main/AndroidManifest.xml` (directly under `<manifest>`):

```xml
<uses-permission android:name="android.permission.READ_MEDIA_AUDIO" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
```

The app requests permission at runtime through `on_audio_query` before scanning local music.
