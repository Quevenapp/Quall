// Projeto Gradle do emissor/receptor Android do Quall (Frente 4, M2).
//
// Sem `gradlew`: a bancada já tem `gradle` 8.10.2 fixo no PATH (ver `docs/bancada.md`), e gerar o
// wrapper baixaria uma distribuição inteira do Gradle só para repetir o que já está instalado.
// Quem builda numa máquina sem esse `gradle` precisa instalar a 8.10+ compatível com AGP 8.7.

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

rootProject.name = "quall-android"
include(":app")
