allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

subprojects {
    project.plugins.withType<com.android.build.gradle.BasePlugin>() {
        project.extensions.findByType<com.android.build.gradle.BaseExtension>()?.apply {
            compileSdkVersion(36)
        }
    }

    tasks.withType<org.gradle.api.tasks.compile.JavaCompile>().configureEach {
        options.compilerArgs.add("-Xlint:-options")
        sourceCompatibility = JavaVersion.VERSION_17.toString()
        targetCompatibility = JavaVersion.VERSION_17.toString()
    }

    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    // For non-app subprojects, apply afterEvaluate override
    if (project.name != "app") {
        project.afterEvaluate {
            project.extensions.findByType<com.android.build.gradle.BaseExtension>()?.apply {
                compileSdkVersion(36)
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
