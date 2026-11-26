import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// key.properties の有無が「リリース署名を出せるか」を決める。
// WHY: デバッグ鍵（CN=Android Debug）へのフォールバックを残すと、鍵を設定し忘れたまま
// release APK が「成功」してしまい、誰でも同じ署名で偽 APK を作れる状態で配布される。
// 一方で、鍵が無いだけで debug ビルドまで失敗させると、clone 直後に flutter run すら
// 動かないため開発を始められない（2026-11-25 に wt/feat-a の fresh-clone 検証で発覚）。
// そのため「debug / profile は通す・release は明確に失敗させる」に分ける。
// パスは android/app/ からの相対で android/key.properties を指す。
// NOTE: plugins {} より前には import 以外を書けないため、この位置に置いている。
val keyPropsFile = file("../key.properties")
val hasReleaseKey = keyPropsFile.exists()
val keyProps = Properties()
if (hasReleaseKey) {
    keyPropsFile.inputStream().use { keyProps.load(it) }
}

android {
    namespace = "com.scoreyomipm.app"
    compileSdk = 37 // receive_sharing_intent 1.9.0 要件（2026-11-23 Task F）
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // WHY: applicationId は公開後にもう変更しない。変更すると Android は別アプリとして
        // 扱うため、既存利用者が上書き更新できなくなる（旧 com.pmscoreman.* からの移行で
        // 一度だけ変更済み）。
        // テンプレート由来の「TODO: Specify your own unique Application ID」は設定済みのため削除した。
        applicationId = "com.scoreyomipm.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // 鍵が無いときはリリース署名設定そのものを作らない。
        // 空の署名設定を作ると Gradle が「署名済み」として扱おうとして失敗の原因が
        // 分かりにくくなるため、存在しない状態を保つ。
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKey) {
                signingConfig = signingConfigs.getByName("release")
            }
            // WHY: リリース Dex 変換の R8 が google_mlkit_text_recognition の
            // compileOnly 参照（Chinese/Devanagari/Korean の
            // TextRecognizerOptions・本アプリは Japanese を使用し未使用）を
            // 欠落クラス検出で失敗させるため、proguard-rules.pro の
            // -dontwarn を読ませる。minify / shrinkResources は明示的に無効:
            // minify 有効のまま実機 OCR を動かすと ML Kit 内部で
            // NullPointerException（getClass() on null・R8 リネーム由来）が
            // 発生し OCR が必ず失敗する（2026-11-22 release 実測で確認）。
            // PoC では動作優先で両者を無効化する。
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

// WHY: release 系のタスクが実際に要求されたときだけ、鍵の不在を明確なメッセージで
// 失敗させる。android {} の中で無条件に error() を投げると、Gradle の構成フェーズは
// ビルド種別に関係なく走るため debug ビルドまで巻き添えで失敗してしまう。
// タスクグラフが確定した時点（whenReady）で判定すれば、debug / profile は通しつつ
// release だけを確実に止められる。
// 注意: ここを外すと、鍵が無いまま未署名 APK が生成され「APK が無い」という
// 原因の分かりにくいエラーになる（Flutter 側のメッセージでは鍵の話が出てこない）。
// NOTE: whenReady は Kotlin のラムダではなく org.gradle.api.Action を要求し、
// その Action はレシーバ形式（引数ではなく this が TaskExecutionGraph）で書く。
// 引数付きラムダ `whenReady { graph -> }` は Closure 版に解決されて型エラーになる。
gradle.taskGraph.whenReady(Action {
    val wantsRelease = allTasks.any { it.name.endsWith("Release") }
    if (wantsRelease && !hasReleaseKey) {
        throw GradleException(
            "リリース署名が未設定です: ${keyPropsFile.absolutePath} が見つかりません。" +
                " release APK は keystore 署名が必須で、デバッグ鍵へのフォールバックは" +
                "意図的に用意していません。手順は RELEASING.md を参照してください。"
        )
    }
})

dependencies {
    // google_mlkit_text_recognition 1.0.3 は Android 向けに Latin モデルのみ
    // バンドルし、日本語モデルはプラグイン側で compileOnly 宣言のため、
    // 本アプリの既定スクリプト（MlKitScript.japanese）を使うには
    // アプリ側で明示的に依存を追加する必要がある。
    // バージョンはプラグインが参照する実バージョン（16.0.1）と一致させること。
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
