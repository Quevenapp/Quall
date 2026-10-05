// Mesmas versões do `apps/android`, para o Gradle reaproveitar o cache (o portão roda --offline).
plugins {
    id("com.android.application") version "8.7.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}

// Saídas fora do disco do sistema e fora do repositório (QUALL_ALVO_R5, padrão no quall-scratch).
val alvo = System.getenv("QUALL_ALVO_R5") ?: rootProject.file("build/sonda-r5").absolutePath
allprojects {
    layout.buildDirectory.set(file("$alvo/${project.name}"))
}
