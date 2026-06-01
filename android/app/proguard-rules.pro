# =========================
# Flutter Core (最小化保留)
# =========================
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.common.** { *; }
-keep class io.flutter.embedding.engine.FlutterEngine { *; }
-keep class io.flutter.embedding.android.FlutterActivity { *; }
-keep class io.flutter.view.FlutterMain { *; }

# =========================
# Native Methods (必须保留)
# =========================
-keepclasseswithmembernames class * {
    native <methods>;
}

# =========================
# Project Specific
# =========================
-keep class org.moontechlab.lunatv.MainActivity { *; }

# =========================
# 关键属性 (用于调试)
# =========================
-keepattributes SourceFile,LineNumberTable
-keepattributes Signature
-keepattributes Exceptions
-renamesourcefileattribute SourceFile

# =========================
# Kotlin (最小化)
# =========================
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**

# Kotlin 反射 (按需保留)
-keepclassmembers class kotlin.Metadata {
    public <methods>;
}

# =========================
# Video Players (只保留必要的)
# =========================
# Media Kit - 只保留公共 API
-keep class com.alexmercerind.**.MediaKitPlugin { *; }
-dontwarn com.alexmercerind.**

# =========================
# Network (最小化)
# =========================
# OkHttp - 只保留必要的
-dontwarn okhttp3.**
-dontwarn okio.**

# =========================
# Flutter Plugins (通用规则)
# =========================
# 保留所有 Plugin 注册类
-keep class * implements io.flutter.plugin.common.PluginRegistry$Registrar {
    public <init>();
}
-keep class * implements io.flutter.embedding.engine.plugins.FlutterPlugin {
    public <init>();
}

# =========================
# Serialization (最小化)
# =========================
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
}

# =========================
# R8 完全优化
# =========================
# 移除所有日志
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
    public static *** i(...);
    public static *** w(...);
    public static *** e(...);
}

# 移除调试代码
-assumenosideeffects class java.lang.Throwable {
    public void printStackTrace();
}

# 移除 Kotlin 断言
-assumenosideeffects class kotlin.jvm.internal.Intrinsics {
    static void check*(...);
    static void throw*(...);
}

# =========================
# 允许激进优化
# =========================
# 允许访问修饰符优化
-allowaccessmodification

# 允许重新打包类
-repackageclasses

# =========================
# Warnings to Ignore
# =========================
-dontwarn javax.annotation.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
