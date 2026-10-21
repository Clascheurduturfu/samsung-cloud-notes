plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// The app version lives in Sources/Shared/Cloud.swift so every client reports the same release.
val appVersion: String = rootDir.resolve("../Sources/Shared/Cloud.swift").readLines()
    .first { it.startsWith("let appVersion = ") }.substringAfter('"').substringBefore('"')

android {
    namespace = "local.samsungcloudnotes"
    compileSdk = 37

    defaultConfig {
        applicationId = "local.samsungcloudnotes"
        minSdk = 26
        targetSdk = 36
        versionCode = 10100
        versionName = appVersion
        buildConfigField("String", "APP_VERSION", "\"$appVersion\"")
    }

    // Release key from the environment (see scripts/build-android.sh); otherwise the local debug key.
    val releaseStore = System.getenv("SCN_ANDROID_KEYSTORE")?.let(::file)?.takeIf { it.exists() }
    signingConfigs {
        if (releaseStore != null) create("release") {
            storeFile = releaseStore
            storePassword = System.getenv("SCN_ANDROID_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("SCN_ANDROID_KEY_ALIAS") ?: "samsung-cloud-notes"
            keyPassword = System.getenv("SCN_ANDROID_KEYSTORE_PASSWORD")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    testOptions { unitTests.isReturnDefaultValues = false }
}

// Project and upstream (samsung-re-health) license notices ship inside the APK, as in the Mac app.
abstract class CopyNotices : DefaultTask() {
    @get:InputFiles abstract val notices: ConfigurableFileCollection
    @get:OutputDirectory abstract val output: DirectoryProperty
    @TaskAction fun copy() {
        val target = output.get().asFile.resolve("notices").apply { deleteRecursively(); mkdirs() }
        notices.forEach { it.copyTo(target.resolve(it.name), overwrite = true) }
    }
}
val copyNotices = tasks.register<CopyNotices>("copyNotices") {
    notices.from(rootDir.resolve("../LICENSE"), rootDir.resolve("../docs/THIRD_PARTY_NOTICES.md"), rootDir.resolve("../docs/third-party/samsung-re-health-LICENSE.txt"))
}
androidComponents {
    onVariants { variant -> variant.sources.assets?.addGeneratedSourceDirectory(copyNotices, CopyNotices::output) }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material:material-icons-core:1.7.8")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.browser:browser:1.10.0")
    implementation("androidx.core:core-ktx:1.19.1")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20250517")
}
