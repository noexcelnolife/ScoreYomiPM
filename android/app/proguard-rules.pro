# google_mlkit_text_recognition は Latin 以外の言語モデル（Chinese/
# Devanagari/Korean）を compileOnly で参照するため、リリース Dex 変換に
# 関与する R8 が欠落クラス検出で失敗する。
# これらのモデルは本アプリ未使用（既定スクリプトは Japanese で、
# build.gradle.kts の text-recognition-japanese 明示追加が正）なので、
# AGP 生成の missing_rules.txt（build/app/outputs/mapping/release/）に
# 相当する -dontwarn を置いて警告を抑制する。
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder
-dontwarn com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions
