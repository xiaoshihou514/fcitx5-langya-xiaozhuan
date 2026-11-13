plugins {
    id("org.fcitx.fcitx5.android.app-convention")
    id("org.fcitx.fcitx5.android.plugin-app-convention")
    id("org.fcitx.fcitx5.android.native-app-convention")
    id("org.fcitx.fcitx5.android.build-metadata")
    id("org.fcitx.fcitx5.android.data-descriptor")
    id("org.fcitx.fcitx5.android.fcitx-component")
}

android {
    namespace = "org.fcitx.fcitx5.android.plugin.langya"

    defaultConfig {
        applicationId = "org.fcitx.fcitx5.android.plugin.langya"

        @Suppress("UnstableApiUsage")
        externalNativeBuild {
            cmake {
                targets(
                    "langya"
                )
            }
        }
    }

    buildFeatures {
        resValues = true
    }

    buildTypes {
        release {
            resValue("string", "app_name", "@string/app_name_release")
            proguardFile("proguard-rules.pro")
        }
        debug {
            resValue("string", "app_name", "@string/app_name_debug")
        }
    }

    packaging {
        jniLibs {
            excludes += setOf(
                "**/libc++_shared.so",
                "**/libFcitx5*",
                // libIME 双库与 punctuation 模块宿主 APK 自带，无需重复
                // 打包（jyutping 同款做法；DT_NEEDED 按文件名解析到宿主副本）
                "**/libIMECore.so",
                "**/libIMEPinyin.so",
                "**/libpunctuation.so"
            )
        }
    }
}

fcitxComponent {
    installPrebuiltAssets = true
}

dependencies {
    implementation(project(":lib:fcitx5"))
    // libime prefab（拼音内核，词典/语言模型用宿主数据）
    implementation(project(":lib:libime"))
    // punctuation 模块（中文标点，zh_CN 表与拼音共用）
    implementation(project(":lib:fcitx5-chinese-addons"))
    implementation(project(":lib:plugin-base"))
}
