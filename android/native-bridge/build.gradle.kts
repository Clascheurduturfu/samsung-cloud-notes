plugins { id("com.android.library") }

android {
    namespace = "local.samsungcloudnotes.nativebridge"
    compileSdk = 37
    defaultConfig { minSdk = 29 }
    buildFeatures { buildConfig = true }
    defaultConfig {
        // Local validation only. Normal builds cannot upload through the probe.
        val probe = providers.gradleProperty("nativeUploadProbeUUID").orElse("").get()
        require(probe.isEmpty() || Regex("[a-f0-9-]{36}").matches(probe))
        buildConfigField("String", "UPLOAD_PROBE_UUID", "\"$probe\"")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":auth-core"))
    testImplementation("junit:junit:4.13.2")
}
