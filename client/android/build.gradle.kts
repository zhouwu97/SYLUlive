import com.android.build.api.dsl.LibraryExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile

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

    // Flutter 插件的 Java 目标可能是 1.8 或 17；Kotlin 默认值却会受当前 JDK 影响。
    // 在插件完成自身配置后让 Kotlin 跟随 Java，避免两类任务目标不一致。
    plugins.withId("com.android.library") {
        afterEvaluate {
            val javaTarget = extensions.getByType<LibraryExtension>()
                .compileOptions.targetCompatibility
            val kotlinTarget = JvmTarget.fromTarget(javaTarget.toString())
            tasks.withType<KotlinJvmCompile>().configureEach {
                compilerOptions.jvmTarget.set(kotlinTarget)
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
