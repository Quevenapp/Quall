// Sondas da fase 0 do R5 (docs/teleprompter-com-camera.md §8.1): APK de bancada, separado do app de
// produto (`apps/android`). Pacote próprio: instala ao lado do `com.quall.android` sem tocar nele.
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

rootProject.name = "sonda-r5"
include(":app")
