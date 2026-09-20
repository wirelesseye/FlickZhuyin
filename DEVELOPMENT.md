# FlickZhuyin 開發文件

本文件面向開發者，說明專案結構、架構、建置測試與詞典編譯流程。使用者操作說明請見 [README.md](README.md)，第三方授權細節請見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 專案結構

```text
FlickZhuyinApp/                SwiftUI 容器 App、設定與測試文字欄
FlickZhuyinKeyboard/           UIKit Keyboard Extension、按鍵與 Flick UI
KeyboardCore/                  鍵盤狀態機、按鍵模型及注音配置
KeyboardCore/ChineseInput/     音節解析、詞庫查詢、詞格與 Top-K 解碼
FlickZhuyinTests/              狀態機、Flick 映射、中文輸入與效能測試
Tools/DictionaryCompiler/      Rime 詞典離線編譯器與 Python 測試
Vendor/rime-terra-pinyin/      鎖定版本的上游詞典、授權與 manifest
Vendor/rime-essay/             鎖定版本的上游預設詞彙、授權與 manifest
Generated/                     編譯產物（SQLite 詞典與 report）
```

## 架構

### 鍵盤狀態機

`KeyboardEngine` 是純 Swift 狀態機：輸入事件產生一組 `KeyboardUpdate`（文件 effects、候選請求、是否作廢候選），`KeyboardViewController` 只依序把 effects 寫進文件，不自行推斷何時提交。`ZhuyinComposition` 保存已選 chunks 與 pending tokens，`ZhuyinInputToken` 同時供鍵盤狀態與 Parser 使用。這讓組字、刪除、提交與模式切換都能獨立測試。

### 中文輸入核心（`KeyboardCore/ChineseInput/`）

- `SyllableParser` 從詞庫的合法音節清單建立音節格（syllable lattice），支援省略聲調、部分聲調與完整聲調；可同時作為完整音節與聲母前綴的符號（例如 `ㄓ`）會產生完整與聲母縮寫兩條 edge。
- `SQLiteLexiconStore` 以唯讀模式開啟 bundle 內的 SQLite 詞典，只把 400 多個合法無調注音載入記憶體。完整注音查詢走 `base_key`，pattern（exact／initial 混合）查詢由 pattern 推導 `initial_key` 後走索引掃描，掃描量受 scan limit 限制，再逐列套用 exact 條件並在收集滿 result limit 後停止；三種查詢各有具上限的 LRU cache。
- `DictionaryMatcher` 沿音節格以統一的 pattern expansion 查詢詞庫：完整 edge 產生 `.exact`、單符號無調 edge 產生 `.initial`，同一位置可同時保留兩種解讀，全部 exact 時仍走快速 `exactMatches`；pattern 與查詢結果都會記憶化，混合查詢受 `patternMatchResultLimit`／`patternMatchScanLimit` 限制。
- `Decoder` 將詞格與 raw 注音音節合併成永遠連通的解碼圖，以精確 Top-K DAG 動態規劃輸出穩定排序的候選；沒有詞典匹配的片段會以原始注音保留。
- `LexiconChineseInputPipeline` 在初始化時建立並長期持有 store、parser、matcher 與 decoder，把 Top-K 結果轉成精簡的 `InputCandidate`；轉換時依文字合併候選、每組保留分數最低者，raw 注音候選不受合併影響，並在必要時補上 raw 注音候選；若游標前輸入是全範圍的完整單一音節，再從 store 取出該音節所有單字詞條、以同一 scorer 計分後接在最後。
- 排序由可替換的 `DecoderScorer` 負責，目前 `BaselineDecoderScorer` 使用 Essay 詞頻 `sourceWeight`、Terra 讀音可信度 `pronunciationWeight`、parser cost 與簡易分詞懲罰，不是完整的語言模型排序。
- Keyboard Extension 的 decoder 上限為 30 個候選（`KeyboardViewController.maximumCandidateCount`）；`KeyboardCore` 的 `DecoderConfiguration.maximumCandidates` 預設為 10。

### Extension 整合

`FlickZhuyinKeyboard/ChineseInputCoordinator.swift` 負責非同步協調：每次 pending tokens 改變就增加 revision 並進入 loading，但保留既有候選直到新結果抵達，背景完成後只在 revision 與 token snapshot 都相符時套用結果；詞典缺失或查詢失敗時才發布 raw 注音 fallback。`KeyboardDocumentClient` 與 `DocumentEffectApplier` 隔離 `UITextDocumentProxy`，`CandidateBarView` 以水平 `UICollectionView` 提供固定高度的候選列與展開按鈕，`ExpandedCandidateView` 以垂直 `UICollectionView` 提供展開後的候選列表，兩者都只建立可見範圍的 cell，選項依原寬度自動換行排列。

### 詞典資料

pinned Terra 詞典經過碼表最小化，常見詞如「注音」「你好」原本屬於 Rime 的 preset vocabulary，未包含在 `terra_pinyin.dict.yaml` 中。編譯器改以 pinned Rime Essay 補齊這些常用詞：Terra 提供字音、多音字與明確詞條，Essay 提供常用詞與詞頻；沒有 Terra 明確讀音的 Essay 詞條會以各字的 Terra 單字讀音離線自動標音。

自動標音時，若某字已有正權重讀音，Terra 明確標為 `0%` 的罕見讀音不參與組合（未標權重的讀音仍會保留，例如「於」合成「於是」只會得到 `ㄩˊ ㄕˋ`）；只有當所有讀音皆為 `0%` 或未標權重時，才保留全部讀音作為 fallback。

合併後的 SQLite 以 `(text, base_key, tone_key)` 為唯一鍵，Essay 詞頻經 log1p 正規化為 `source_weight`，因此「注音」「你好」等詞是帶權重的單一詞條，而不是多個無權重單字臨時拼接。schema v4 把詞頻與發音可信度分開：`source_weight` 只存 Essay 詞頻，`pronunciation_weight` 存 Terra 的讀音權重；Terra 單字讀音低於 5% 時以 5% 為下限（例如「於」的 `ㄨˉ` 保留為 0.05，不再被 Essay 詞頻放大），Runtime 成本為詞頻成本加 `-log(pronunciation_weight)`。schema v4 也為每個 canonical 讀音寫入 `initial_key`（每個音節第一個注音符號，以 U+001F 分隔）並建立 `pronunciation_initial_key` 索引，供聲母縮寫與完整／縮寫混合的 pattern 查詢等值掃描。無法標音或超過組合上限的詞條會統計在編譯報告中，不會靜默遺失。

## 建置與測試

在 Xcode 中選擇 `FlickZhuyin` scheme 後執行 Build 或 Test，或使用命令列（將 `name` 替換成 Xcode 中現有的 iPhone 模擬器）：

```sh
xcodebuild \
  -project FlickZhuyin.xcodeproj \
  -scheme FlickZhuyin \
  -destination 'platform=iOS Simulator,name=<模擬器名稱>' \
  test
```

Swift 測試涵蓋：

- 鍵盤狀態機：ABC 大小寫與 Caps Lock、Flick 方向映射、第一至第四聲與獨立輕聲、聲調保留與連續聲調取代、候選選擇／刪除／Return／空白與模式切換的 effect 順序
- Composition：inline marked text 組合、已選 chunk 撤銷與 source token 還原、音調鍵顯示
- 音節格切分、incomplete／fallback 連通性、完整／聲母縮寫雙重解讀與 eligible edge 判定
- 詞格的多字詞、去重、展開上限，以及 pattern lookup 的記憶化、result／scan limit、cheapest-segmentation 去重與 exact／initial 去重
- Decoder 的 scoring、lattice 驗證、Top-K 限制、去重與 deterministic tie-break
- Pipeline 的 fixture 與 production 候選、同文字候選合併、raw fallback 保留、空輸入與錯誤傳遞
- 完整單一音節輸入會在 Top-K 之後補上該音節所有完全匹配的單字（含省略聲調、超過 Top-K 與去重），多音節輸入不追加
- 聲母與混合縮寫：`ㄅ`、`ㄅㄅ` 的漢字候選與排序，`ㄅㄨㄓㄉ`、`ㄓㄉ`、`ㄎㄧㄎ` 的詞條查詢，以及縮寫候選刪除後還原原始 tokens
- Coordinator 的 stale result 防護、載入期間保留既有候選、invalidate 與初始化失敗 fallback
- Document effect applier 的 UTF-16 selection、替換 marked text 與提交順序
- 候選列與展開列表只建立可見範圍的 cell、第一列可見數計算與展開／收合狀態
- production 詞典的 metadata、entry count、initial key 完整性、來源 manifest 比對、代表性查詢，以及 `EXPLAIN QUERY PLAN` 索引驗證

Python 詞典編譯器另有單元測試與完整 corpus 驗證：

```sh
python3 -m unittest discover \
  -s Tools/DictionaryCompiler/tests \
  -t Tools/DictionaryCompiler/tests
```

## 詞典編譯

上游資料只在更新來源時以 `fetch-terra`／`fetch-essay` 下載，兩者都必須指定完整的 40 字元 commit：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py fetch-terra \
  --commit <terra-commit> --dest Vendor/rime-terra-pinyin

python3 Tools/DictionaryCompiler/compile_dictionary.py fetch-essay \
  --commit <essay-commit> --dest Vendor/rime-essay
```

重建 production 詞典與 report（不需要網路）：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build \
  --terra-source Vendor/rime-terra-pinyin/terra_pinyin.dict.yaml \
  --terra-manifest Vendor/rime-terra-pinyin/SOURCE.json \
  --essay-source Vendor/rime-essay/essay.txt \
  --essay-manifest Vendor/rime-essay/SOURCE.json \
  --output Generated/flickzhuyin.sqlite3 \
  --report Generated/dictionary-report.json
```

編譯流程：

- 編譯器先編譯 Terra，建立完整詞與單字讀音索引；Essay 詞條優先使用 Terra 明確詞讀音，否則以單字讀音自動組合，每個詞最多保留 16 組讀音，超過上限會記錄於 report。合成時排除該字已有正權重讀音時 Terra 明確標為 `0%` 的讀音，排除數量記於 report 的 `excludedZeroWeightReadings`；Terra 單字本身的 `0%` 讀音仍會保留在詞典中。
- Essay 詞頻以 `log1p(frequency) / log1p(max_frequency)` 正規化為 `source_weight`，與 Terra 詞條以 `(text, base_key, tone_key)` 合併。Terra 的讀音權重獨立寫入 `pronunciation_weight`（單字讀音下限 5%，合成詞取各字讀音權重乘積，來源未標權重時為 NULL），Runtime 以兩者相加計分。
- 每個 canonical 讀音另計算 `initial_key`（schema v4）並建立索引，且驗證其分段數等於 `syllable_count`；完整性統計會寫入 report。
- 無法標音的詞條只會統計在 report；格式錯誤或 hash 不符則會讓 build 失敗。report 也會記錄資料庫大小與編譯時間，資料庫大小有硬上限。

在相同 Python 與 SQLite library 版本下，相同 source bytes 與 compiler 版本會產生 byte-for-byte 相同的 SQLite 檔案與 report；不同 SQLite library 版本只保證 schema、metadata、排序後資料內容與 report 相同，不保證 SQLite 實體 page layout 或檔案 hash 相同。編譯耗時不寫入可重現的 report。output 只加入 `FlickZhuyinKeyboard` 的 bundle resources。

Swift 測試使用的迷你 fixture 由下列命令產生，Python 測試以 logical database snapshot 檢查它是否與 fixture source 同步：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build \
  --terra-source Tools/DictionaryCompiler/tests/fixtures/zhuyin_tests.dict.yaml \
  --terra-manifest Tools/DictionaryCompiler/tests/fixtures/zhuyin_tests.SOURCE.json \
  --essay-source Tools/DictionaryCompiler/tests/fixtures/zhuyin_tests.essay.txt \
  --essay-manifest Tools/DictionaryCompiler/tests/fixtures/zhuyin_tests.essay.SOURCE.json \
  --output FlickZhuyinTests/Fixtures/flickzhuyin-tests.sqlite3 \
  --report /tmp/flickzhuyin-fixture-report.json
```

## 效能

`ChineseInputPerformanceTests` 與 `DecoderPerformanceTests` 是防止演算法或 I/O 發生災難性退化的寬鬆保護，不代表產品延遲目標。Release 模擬器的 Decoder p95 上限為 100 ms，完整 parser → matcher → decoder Pipeline p95 上限為 250 ms；測試直接 assert 全部樣本的 p95，並輸出 min、平均與 p95 供比較。SQLite open、冷／熱查詢、pattern 查詢、parser 與 matcher 也分別設有 Debug／Release 寬鬆門檻，並涵蓋 2、4、8 個連續聲母的 matcher 測試與「每次 pattern query 最多回傳 result limit」的界線。

加入 Essay、讀音 provenance 與聲母索引後 production 資料庫約 165 MB（仍在 256 MB 上限內）。Extension 啟動仍只把音節 inventory 載入記憶體，詞條查詢維持依 `base_key` 與 `syllable_count`、pattern 查詢依 `initial_key` 與 `syllable_count` 使用索引，掃描量與單次回傳數都有硬上限，pattern 結果與掃描列另有具上限的 LRU cache。

## 資源檔案與 Git LFS

`Generated/flickzhuyin.sqlite3` 是鍵盤執行所需的可重現資源，因此不加入 `.gitignore`；由於檔案超過 GitHub 一般 Git blob 的 100 MB 限制，repository 透過 Git LFS 追蹤它。clone 後需安裝 Git LFS 才能取得完整資料庫。

## 第三方資料

詞典來源以 pinned commit 鎖定，各 `SOURCE.json` 記錄來源、commit、SHA-256 與取得時間，Essay manifest 另記錄 LICENSE SHA-256 與格式版本；`build` 會驗證 source 與 license 的 SHA-256，`fetch-terra`／`fetch-essay` 只能在明確指定 commit 時使用，一般 build 與 App 執行期都不連網。

`Generated/flickzhuyin.sqlite3` 同時包含 Terra Pinyin 與 Rime Essay 的衍生資料，sidecar 授權位於 `Generated/LICENSE.md`。完整 attribution、修改說明與授權連結見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；同一份 notices 與上游 LGPL 授權會打包進主 App 及 Keyboard Extension，App 內可從「第三方授權」開啟閱讀。發佈前仍需人工確認最終合規方式。
