allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Fix namespace for old plugins (on_audio_query etc.) that break on AGP 8+
subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library") || plugins.hasPlugin("com.android.application")) {
            extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.let { androidExt ->
                if (androidExt.namespace.isNullOrEmpty()) {
                    // Prefer known namespace for on_audio_query, otherwise use project name
                    androidExt.namespace = if (name.contains("on_audio_query")) {
                        "com.lucasjosino.on_audio_query"
                    } else {
                        name
                    }
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
