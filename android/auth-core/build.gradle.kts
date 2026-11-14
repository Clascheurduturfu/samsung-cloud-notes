plugins { id("com.android.library") }

val appVersion: String = rootDir.resolve("../Sources/Shared/Cloud.swift").readLines()
    .first { it.startsWith("let appVersion = ") }.substringAfter('"').substringBefore('"')

android {
    namespace = "local.samsungcloudnotes.authcore"
    compileSdk = 37
    defaultConfig {
        minSdk = 26
        buildConfigField("String", "APP_VERSION", "\"$appVersion\"")
    }
    buildFeatures { buildConfig = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies { api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2") }
