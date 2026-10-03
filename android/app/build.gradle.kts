import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import org.jetbrains.kotlin.konan.properties.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val agpMajorVersion = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION
    .substringBefore('.')
    .toInt()
val builtInKotlinProperty = providers.gradleProperty("android.builtInKotlin").orNull
val isBuiltInKotlinEnabled = agpMajorVersion >= 9 &&
        (builtInKotlinProperty == null || builtInKotlinProperty.toBoolean())
if (!isBuiltInKotlinEnabled) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.piliplus"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.piliplus"
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    packagingOptions.jniLibs.useLegacyPackaging = true

    val keyProperties = Properties().also {
        val properties = rootProject.file("key.properties")
        if (properties.exists())
            it.load(properties.inputStream())
    }

    // 签名参数优先读环境变量(CI 直传, 原样字节), 其次 key.properties
    // (本地开发)。不经过 Properties 文件转义 —— 密码含 \ 等字符时
    // key.properties 会被 Java Properties 解析改变, 导致
    // "Given final block not properly padded"(第十七轮 CI 实录)。
    val storeFilePath = System.getenv("PILI_KEYSTORE_FILE")
        ?: keyProperties.getProperty("storeFile")
    val config = storeFilePath?.let {
        signingConfigs.create("release") {
            storeFile = file(it)
            // PKCS12 库必须显式声明类型(AGP 默认按 JKS 处理会解密失败)
            (System.getenv("PILI_KEYSTORE_TYPE")
                ?: keyProperties.getProperty("storeType"))?.takeIf { t -> t.isNotEmpty() }
                ?.let { t -> storeType = t }
            storePassword = System.getenv("PILI_KEYSTORE_PASSWORD")
                ?: keyProperties.getProperty("storePassword")
            keyAlias = System.getenv("PILI_KEY_ALIAS")
                ?: keyProperties.getProperty("keyAlias")
            keyPassword = System.getenv("PILI_KEY_PASSWORD")
                ?: keyProperties.getProperty("keyPassword")
            enableV1Signing = true
            enableV2Signing = true
        }
    }

    buildTypes {
        all {
            signingConfig = config ?: signingConfigs["debug"]
        }
        release {
            // dev 构建(CI 测试包)只改包名后缀以便与正式版共存;
            // 显示名统一为 piliplayer(第十七轮, 走 strings.xml 的 app_name)
            if (project.hasProperty("dev")) {
                applicationIdSuffix = ".dev"
            }
//            proguardFiles(
//                getDefaultProguardFile("proguard-android-optimize.txt"),
//                "proguard-rules.pro"
//            )
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    applicationVariants.all {
        val variant = this
        variant.outputs.forEach { output ->
            (output as ApkVariantOutputImpl).versionCodeOverride = flutter.versionCode
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
