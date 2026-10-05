// Espião DV do S24: APK de bancada, separado do app de produto (`apps/android`).
// Conta quadros DV por segundo vindos de uma filmadora UVC em modo DV. Ver README.md.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "espiao-dv-s24"
include(":app")
