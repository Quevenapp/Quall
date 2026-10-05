plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val alvo = System.getenv("QUALL_ALVO_DV") ?: rootProject.file("build/espiao-dv").absolutePath

android {
    namespace = "com.quall.bancada.espiaodv"
    compileSdk = 36
    ndkVersion = "27.2.12479018"

    defaultConfig {
        // Pacote próprio: instala ao lado do `com.quall.android` sem tocar nele.
        applicationId = "com.quall.bancada.espiaodv"
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "0.1-bancada"
        // Só o S24 (arm64).
        ndk { abiFilters += listOf("arm64-v8a") }
        externalNativeBuild {
            cmake { cFlags += listOf("-Wall", "-Wextra", "-O2") }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
            buildStagingDirectory = file("$alvo/cxx")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
