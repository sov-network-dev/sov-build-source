import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Release signing — a NETWORK key, never a founder key ─────────────────────
// The king does not remain in the picture after launch, so nothing here may
// depend on one person. The Android signing key is NOT a trust root for SOV:
// protocol trust is source_root + multi-builder hash attestation
// (SELF_VALIDATING_RELEASE_DESIGN §A5). The key exists only because Android
// refuses to install an update signed by a different key, so update continuity
// needs ONE stable key for the life of the app.
//
// That makes key CUSTODY the real question, and the answer is the same as every
// other authority in SOV: it is held by the earned operator set under threshold
// custody (k-of-n shares), not by a person. See docs/APK_SIGNING_CUSTODY.md.
//
// Credentials are read from (in order) the environment, then android/key.properties.
// Neither is ever committed. A builder reconstructing the key from shares can
// export the env vars and never write the secret to disk.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) load(FileInputStream(keystorePropertiesFile))
}
fun signingValue(env: String, prop: String): String? =
    (System.getenv(env) ?: keystoreProperties.getProperty(prop))?.takeIf { it.isNotBlank() }

val ksStore = signingValue("SOV_KEYSTORE_FILE", "storeFile")
val ksStorePw = signingValue("SOV_KEYSTORE_PASSWORD", "storePassword")
val ksAlias = signingValue("SOV_KEY_ALIAS", "keyAlias")
val ksKeyPw = signingValue("SOV_KEY_PASSWORD", "keyPassword")
val hasReleaseKey = ksStore != null && ksStorePw != null && ksAlias != null && ksKeyPw != null

// Explicit, loud opt-in for local testing only. It must be a deliberate act:
// the previous config silently fell back to the DEBUG key, which is public, so a
// release APK went out that anyone could forge an "update" for — and nothing said so.
val allowDebugSigning = (System.getenv("SOV_ALLOW_DEBUG_SIGNING") ?: "").lowercase() in listOf("1", "true", "yes")

android {
    namespace = "network.sov.node"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (and other plugins using
        // Java 8+ APIs on older Android versions via D8 desugaring).
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "network.sov.node"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(ksStore!!)
                storePassword = ksStorePw
                keyAlias = ksAlias
                keyPassword = ksKeyPw
            }
        }
    }

    buildTypes {
        release {
            signingConfig = when {
                hasReleaseKey -> signingConfigs.getByName("release")
                // Marked, deliberate, local-only. Never produces a distributable APK.
                allowDebugSigning -> {
                    logger.warn("⚠️  SOV: release APK signed with the PUBLIC ANDROID DEBUG KEY " +
                        "(SOV_ALLOW_DEBUG_SIGNING is set). Local testing ONLY — anyone can forge " +
                        "an update for this signature. Do NOT distribute this artifact.")
                    signingConfigs.getByName("debug")
                }
                // Fail closed. See the guard below for the actionable message.
                else -> null
            }
        }
    }
}

// Fail LOUDLY, not silently, when a release build has no key. The old config
// quietly used the debug key, so an unsignable release looked like a successful
// one — the failure mode that put a debug-signed APK on disk in the first place.
// Only fires when a release artifact is actually being requested, so debug builds
// and `flutter analyze` are unaffected.
gradle.taskGraph.whenReady {
    val buildingRelease = allTasks.any { t ->
        val n = t.name
        (n.contains("Release") && (n.startsWith("assemble") || n.startsWith("bundle") || n.startsWith("package")))
    }
    if (buildingRelease && !hasReleaseKey && !allowDebugSigning) {
        throw GradleException(
            "\n" +
            "SOV release build has no signing key.\n" +
            "\n" +
            "  Android will not let an app be updated by a differently-signed APK, so the\n" +
            "  release key must be the network's ONE stable key — held by the earned operator\n" +
            "  set under threshold custody, never by a person. See docs/APK_SIGNING_CUSTODY.md.\n" +
            "\n" +
            "  Provide it via environment (preferred — the secret never touches disk):\n" +
            "    SOV_KEYSTORE_FILE  SOV_KEYSTORE_PASSWORD  SOV_KEY_ALIAS  SOV_KEY_PASSWORD\n" +
            "  or android/key.properties (see android/key.properties.template; never commit it).\n" +
            "\n" +
            "  For LOCAL TESTING ONLY, set SOV_ALLOW_DEBUG_SIGNING=true — this signs with the\n" +
            "  PUBLIC debug key and must never be distributed.\n"
        )
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Core library desugaring — required by flutter_local_notifications
    // to use java.time APIs on Android < 26 (API level 26 = Android 8).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
