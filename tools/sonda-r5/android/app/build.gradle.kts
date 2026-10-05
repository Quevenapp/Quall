plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.quall.bancada.sondar5"
    compileSdk = 36

    defaultConfig {
        // Pacote próprio: instala ao lado do `com.quall.android` sem tocar nele.
        applicationId = "com.quall.bancada.sondar5"
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "0.1-bancada"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.lifecycle:lifecycle-service:2.8.7")
    // As mesmas do produto (`apps/android/app/build.gradle.kts`): a S-A2 pergunta justamente o que
    // o CameraX **desta versão** aceita.
    implementation("androidx.camera:camera-core:1.4.2")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-video:1.4.2")
    // Sem appcompat/material (que o produto tem), o grafo desta sonda resolve versões que não estão
    // na cache do Gradle desta bancada (`kotlin-stdlib-jdk8:1.8.20`, `collection:1.0.0`…), e o
    // build é `--offline`. Os pinos abaixo são as versões que o `debugRuntimeClasspath` do produto
    // resolve (`gradle :app:dependencies` em `apps/android`, 24/09): mesmo grafo, mesma cache.
    constraints {
        listOf(
            "androidx.activity:activity:1.9.3",
            "androidx.annotation:annotation-experimental:1.4.1",
            "androidx.annotation:annotation:1.8.1",
            "androidx.arch.core:core-common:2.2.0",
            "androidx.collection:collection:1.1.0",
            "androidx.concurrent:concurrent-futures:1.1.0",
            "androidx.core:core:1.13.1",
            "androidx.lifecycle:lifecycle-common:2.8.7",
            "androidx.lifecycle:lifecycle-livedata-core:2.8.7",
            "androidx.lifecycle:lifecycle-livedata:2.8.7",
            "androidx.lifecycle:lifecycle-process:2.8.7",
            "androidx.lifecycle:lifecycle-runtime-ktx:2.8.7",
            "androidx.lifecycle:lifecycle-runtime:2.8.7",
            "androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7",
            "androidx.lifecycle:lifecycle-viewmodel-savedstate:2.8.7",
            "androidx.lifecycle:lifecycle-viewmodel:2.8.7",
            "androidx.savedstate:savedstate:1.2.1",
            "androidx.startup:startup-runtime:1.1.1",
            "androidx.tracing:tracing:1.2.0",
            "org.jetbrains.kotlin:kotlin-stdlib-common:2.0.21",
            "org.jetbrains.kotlin:kotlin-stdlib-jdk7:1.8.22",
            "org.jetbrains.kotlin:kotlin-stdlib-jdk8:1.8.22",
            "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.7.3",
            "org.jetbrains:annotations:23.0.0",
        ).forEach { implementation(it) }
    }
}
