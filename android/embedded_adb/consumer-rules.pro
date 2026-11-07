# Android provides this TLS exporter at runtime. The compile-only hidden-API
# stub is intentionally not packaged; keep this exception limited to that class.
-dontwarn com.android.org.conscrypt.Conscrypt

# JNI_OnLoad registers this exact class and method names from adb_pairing.cpp.
-keep class org.skivu.engine.adb.PairingContext { *; }
