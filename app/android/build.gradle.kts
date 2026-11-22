// Top-level build file: Flutter 3.35 template layout.
// The buildDir redirection below is load-bearing: `flutter build apk`
// copies the APK to <repo>/build/app/outputs/flutter-apk/ only when the
// root build directory is redirected to ../../build (repo root).
// Without it, CI's artifact path (build/app/outputs/flutter-apk/*.apk)
// would be empty.
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
