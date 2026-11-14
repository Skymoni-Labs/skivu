
# dsh-go privileged shell entry points are reached by class name.
-keep class com.skyjjgw.independent.ski.dshgo.phone.** { *; }
# Original upstream provider/ADB rules. Android does not ship the desktop JNDI
# APIs referenced by unused Bouncy Castle DANE helpers, nor pre-Lollipop sockets.
-dontwarn com.android.org.conscrypt.SSLParametersImpl
-dontwarn org.apache.harmony.xnet.provider.jsse.SSLParametersImpl
-keep class org.conscrypt.** { *; }
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-keep class io.github.muntashirakon.adb.** { *; }
