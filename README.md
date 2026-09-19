# FlickZhuyin

FlickZhuyin 是一個實驗性的 iOS 自訂注音鍵盤，使用類似日文假名鍵盤的 Flick（滑動）操作，在九宮格上輸入注音符號。

目前專案仍處於輸入原型階段：中文模式已把注音音節解析、詞庫查詢、詞格（word lattice）建立與 Top-K 解碼接到鍵盤，會用 iOS marked text 在宿主輸入框即時顯示「已選字＋未選注音」，並可從候選列選字。目前的候選排序仍是 baseline，還不是自然的語言模型選字，也沒有使用者學習與自動選字。

## 功能

- 注音九宮格 Flick 輸入
- 中文與全鍵盤 ABC 模式切換
- Inline 組字：宿主輸入框即時顯示已選字與未選注音
- 最多 10 個漢字／注音候選，可點選組字
- 第一至第四聲 Flick 選擇
- 獨立輕聲鍵
- Shift、Caps Lock、刪除、空白與 Return
- iPhone 直向與橫向版面
- 深色及淺色模式
- 按鍵與 Flick 方向切換的觸覺回饋（需要「允許完整取用」）

## 系統需求

- iOS 17.0 或以上
- Xcode 15 或以上
- 可用的 Apple Development Team（安裝至實機時需要）

專案目前只以 iPhone 為目標裝置，尚未針對 iPad 最佳化。

## 安裝與啟用

1. 使用 Xcode 開啟 `FlickZhuyin.xcodeproj`。
2. 在 `FlickZhuyin` 與 `FlickZhuyinKeyboard` targets 的 Signing & Capabilities 中選擇 Development Team。
3. 在模擬器或實機上執行 `FlickZhuyin` App。
4. 開啟 iOS「設定」。
5. 前往「一般」→「鍵盤」→「鍵盤」→「新增鍵盤」。
6. 選擇 FlickZhuyin。
7. 返回鍵盤列表，點選 FlickZhuyin，開啟「允許完整取用」並確認授權。這是第三方鍵盤觸發觸覺回饋所需的權限。
8. 在文字欄中使用地球鍵切換至 FlickZhuyin。

若未開啟「允許完整取用」，鍵盤仍可輸入，但按鍵與 Flick 方向切換不會產生觸覺回饋。容器 App 本身只提供一個文字欄，方便測試鍵盤。

## 注音模式

九宮格只顯示每一族的第一個符號。按住按鍵後會出現方向選項，滑向目標方向並放開即可輸入。

符號順序依序對應：**點按、左滑、上滑、右滑、下滑**。

| 按鍵中央 | 可輸入符號 |
| --- | --- |
| ㄅ | ㄅ、ㄆ、ㄇ、ㄈ |
| ㄉ | ㄉ、ㄊ、ㄋ、ㄌ |
| ㄍ | ㄍ、ㄎ、ㄏ、ㄐ、ㄑ |
| ㄓ | ㄓ、ㄔ、ㄕ、ㄖ、ㄒ |
| ㄗ | ㄗ、ㄘ、ㄙ |
| ㄧ | ㄧ、ㄨ、ㄩ、ㄦ |
| ㄚ | ㄚ、ㄛ、ㄜ、ㄝ |
| ㄞ | ㄞ、ㄟ、ㄠ、ㄡ |
| ㄢ | ㄢ、ㄣ、ㄤ、ㄥ |

### 聲調

輸入至少一個注音符號後，空白鍵會變成聲調鍵：

| 操作 | 聲調 |
| --- | --- |
| 點按 | 第一聲 `ˉ` |
| 左滑 | 第二聲 `ˊ` |
| 上滑 | 第三聲 `ˇ` |
| 右滑 | 第四聲 `ˋ` |

輕聲 `˙` 使用 Delete 上方的獨立按鍵，並且只在已有注音輸入時顯示。

聲調會保留在輸入位置。只有連續輸入聲調時，新的聲調才會取代上一個聲調，因此可以組成：

```text
ㄓㄨˋㄧㄣˉ
```

### Inline 組字與候選

中文 composition 由「已選文字」與「未選注音」兩部分組成，會以 marked text 即時顯示在宿主輸入框。例如 `ㄓㄨˋ → 注 → ㄧㄣˉ → 注音`：

- 輸入注音後，輸入框立即顯示原始注音（例如 `注ㄧㄣˉ`），候選列同步查詢 production 詞典。
- 候選列在查詢完成前先顯示原始注音 fallback，完成後換成 Decoder 的 Top-K 候選；raw 注音候選一定保留。
- 點擊候選會把文字加入 composition，並保留產生它的注音；可繼續輸入下一段，不會提前結束組字。
- 有未選注音時，中央按鍵是聲調鍵；只有已選文字時，中央按鍵是一般空白鍵。
- Return 會提交 composition（`unmarkText` 後插入換行）；尚未選字的注音會原樣提交。
- 切換至 ABC 或切換系統鍵盤前，會先提交 composition。
- 刪除鍵依序刪除 pending 注音、撤銷最後一次選字（還原其原始注音）、最後才刪除文件內容。
- 宿主切換輸入欄位或游標位置改變時，會清除本地 composition，不重複插入文字。

候選查詢在背景執行，並以遞增 revision 防止較舊的非同步結果覆蓋較新的輸入；詞典缺失或查詢失敗時退回原始注音候選，鍵盤與 ABC 模式仍可正常使用。

## ABC 模式

按下中文模式中的 `ABC` 鍵可切換至全鍵盤英文模式；按下 `中` 可切回注音模式。

ABC 模式提供：

- QWERTY 字母排列
- 單次 Shift
- 雙擊 Shift 開啟 Caps Lock
- Delete、Space 與 Return
- 系統鍵盤切換鍵

模式會在同一次 Keyboard Extension 生命週期內保留，但不會跨程序重新啟動保存。

## 專案結構

```text
FlickZhuyinApp/                SwiftUI 容器 App 與測試文字欄
FlickZhuyinKeyboard/           UIKit Keyboard Extension、按鍵與 Flick UI
KeyboardCore/                  鍵盤狀態機、按鍵模型及注音配置
KeyboardCore/ChineseInput/     音節解析、詞庫查詢、詞格與 Top-K 解碼（實驗中）
FlickZhuyinTests/              狀態機、Flick 映射與中文輸入核心測試
Tools/DictionaryCompiler/      Rime 詞典離線編譯器與 Python 測試
Vendor/rime-terra-pinyin/      鎖定版本的上游詞典、授權與 manifest
Vendor/rime-essay/             鎖定版本的上游預設詞彙、授權與 manifest
Generated/                     編譯產物（SQLite 詞典與 report）
```

`KeyboardEngine` 是純 Swift 狀態機：輸入事件產生一組 `KeyboardUpdate`（文件 effects、候選請求、是否作廢候選），`KeyboardViewController` 只依序把 effects 寫進文件，不自行推斷何時提交。`ZhuyinComposition` 保存已選 chunks 與 pending tokens，`ZhuyinInputToken` 同時供鍵盤狀態與 Parser 使用。這讓組字、刪除、提交與模式切換都能獨立測試。

中文輸入核心位於 `KeyboardCore/ChineseInput/`：

- `SyllableParser` 從詞庫的合法音節清單建立音節格（syllable lattice），支援省略聲調、部分聲調與完整聲調。
- `SQLiteLexiconStore` 以唯讀模式開啟 bundle 內的 SQLite 詞典，只把 400 多個合法無調注音載入記憶體，發音資料則按需求查詢。
- `DictionaryMatcher` 沿音節格查詢詞庫，產生可含多詞、多讀音的詞格，不做 `5^n` 聲調展開。
- `Decoder` 將詞格與 raw 注音音節合併成永遠連通的解碼圖，以精確 Top-K DAG 動態規劃輸出穩定排序的候選；沒有詞典匹配的片段會以原始注音保留。
- `LexiconChineseInputPipeline` 在初始化時建立並長期持有 store、parser、matcher 與 decoder，把 Top-K 結果轉成精簡的 `InputCandidate`，並在必要時補上 raw 注音候選。
- 排序由可替換的 `DecoderScorer` 負責，目前 `BaselineDecoderScorer` 只使用稀疏的 Rime `sourceWeight`、parser cost 與簡易分詞懲罰，不是完整的語言模型排序。

`FlickZhuyinKeyboard/ChineseInputCoordinator.swift` 負責非同步協調：每次 pending tokens 改變就增加 revision、先發布 raw fallback，背景完成後只在 revision 與 token snapshot 都相符時套用結果；`KeyboardDocumentClient` 與 `DocumentEffectApplier` 隔離 `UITextDocumentProxy`，`CandidateBarView` 提供固定高度的水平候選列。

pinned Terra 詞典經過碼表最小化，常見詞如「注音」「你好」原本屬於 Rime 的 preset vocabulary，未包含在 `terra_pinyin.dict.yaml` 中。編譯器改以 pinned Rime Essay 補齊這些常用詞：Terra 提供字音、多音字與明確詞條，Essay 提供常用詞與詞頻；沒有 Terra 明確讀音的 Essay 詞條會以各字的 Terra 單字讀音離線自動標音。合併後的 SQLite 以 `(text, base_key, tone_key)` 為唯一鍵，Essay 詞頻經 log1p 正規化為 `source_weight`，因此「注音」「你好」等詞是帶權重的單一詞條，而不是多個無權重單字臨時拼接。無法標音或超過組合上限的詞條會統計在編譯報告中，不會靜默遺失。

## 建置與測試

在 Xcode 中選擇 `FlickZhuyin` scheme 後執行 Build 或 Test，或使用命令列：

```sh
xcodebuild \
  -project FlickZhuyin.xcodeproj \
  -scheme FlickZhuyin \
  -destination 'platform=iOS Simulator,name=<模擬器名稱>' \
  test
```

若本機使用的模擬器名稱不同，請將 `name` 替換成 Xcode 中現有的 iPhone 模擬器。

目前測試涵蓋：

- ABC 大小寫與 Caps Lock
- 九宮格 Flick 方向映射
- 第一至第四聲與獨立輕聲
- 聲調保留位置及連續聲調取代
- 候選選擇、刪除、Return、空白與模式切換的 effect 順序
- inline marked text 組合、已選 chunk 撤銷與 source token 還原
- 音調鍵顯示只依 pending tokens
- SQLite 詞庫查詢（完整聲調、省略聲調、混合聲調、輕聲、多音字）
- 音節格切分、incomplete/fallback 連通性
- 詞格的多字詞、去重與展開上限
- decoder 的 scoring、lattice 驗證、Top-K 限制、去重與 deterministic tie-break
- pipeline 的 fixture 與 production 候選、raw fallback 保留、空輸入與錯誤傳遞
- coordinator 的 stale result 防護、invalidate 與初始化失敗 fallback
- document effect applier 的 UTF-16 selection、替換 marked text 與提交順序
- 「注音」在有聲調與無聲調輸入下都出現在 Top 10，且來自單一詞典詞條
- production 詞典的 metadata、entry count、兩份來源 manifest 比對與代表性查詢
- production lookup 的 `EXPLAIN QUERY PLAN` 確認使用 `pronunciation_base_key` 索引

Python 詞典編譯器另有單元測試與完整 corpus 驗證：

```sh
python3 -m unittest discover \
  -s Tools/DictionaryCompiler/tests \
  -t Tools/DictionaryCompiler/tests
```

## 第三方資料

中文詞庫來自兩份 Rime 資料，皆以 pinned commit 方式鎖定：

- Terra Pinyin：<https://github.com/rime/rime-terra-pinyin>，commit `8a2c895ad7ee8e2b137d91be77f18f86b04d7fc9`
  - 詞典：<https://raw.githubusercontent.com/rime/rime-terra-pinyin/8a2c895ad7ee8e2b137d91be77f18f86b04d7fc9/terra_pinyin.dict.yaml>
  - Repository 授權：LGPL-3.0（`Vendor/rime-terra-pinyin/LICENSE`）
  - 詞典 header 另註明參考 CC-CEDICT，採 CC BY-SA 3.0
- Rime Essay：<https://github.com/rime/rime-essay>，commit `e2652ea18609a879eae3e87db5d25b7fbc1a4f93`
  - 詞彙：<https://raw.githubusercontent.com/rime/rime-essay/e2652ea18609a879eae3e87db5d25b7fbc1a4f93/essay.txt>
  - Repository 授權：LGPL-3.0（`Vendor/rime-essay/LICENSE`）

各 `SOURCE.json` 記錄來源、commit、SHA-256 與取得時間，Essay manifest 另記錄 LICENSE SHA-256 與格式版本；`build` 會驗證 source 與 license 的 SHA-256，`fetch-terra`／`fetch-essay` 只能在明確指定 commit 時使用，一般 build 與 App 執行期都不連網。完整 attribution、修改說明與授權連結見 `THIRD_PARTY_NOTICES.md`；同一份 notices 與上游 LGPL 授權會打包進主 App 及 Keyboard Extension，App 內可從「第三方授權」開啟閱讀。SQLite 衍生資料的 sidecar 授權位於 `Generated/LICENSE.md`。發佈前仍需人工確認最終合規方式。

FlickZhuyin 自有程式碼目前未授予開源授權，repository 根目錄也刻意不包含自有程式碼的 `LICENSE` 檔；第三方材料及衍生詞典的授權如上述，不受影響。

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

編譯器會先編譯 Terra，建立完整詞與單字讀音索引；Essay 詞條優先使用 Terra 明確詞讀音，否則以單字讀音自動組合，每個詞最多保留 16 組讀音，超過上限會在 report 中記錄。Essay 詞頻以 `log1p(frequency) / log1p(max_frequency)` 正規化為 `0...1` 權重，與 Terra 詞條以 `(text, base_key, tone_key)` 合併；無法標音的詞條只會統計在 report，格式錯誤或 hash 不符則會讓 build 失敗。report 也會記錄資料庫大小與編譯時間，資料庫大小有硬上限。

在相同 Python 與 SQLite library 版本下，相同 source bytes 與 compiler 版本會產生 byte-for-byte 相同的 SQLite 檔案與 report；不同 SQLite library 版本只保證 schema、metadata、排序後資料內容與 report 相同，不保證 SQLite 實體 page layout 或檔案 hash 相同。編譯耗時不寫入可重現的 report。output 只加入 `FlickZhuyinKeyboard` 的 bundle resources。Swift 測試使用的迷你 fixture 由下列命令產生，Python 測試以 logical database snapshot 檢查它是否與 fixture source 同步：

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

`ChineseInputPerformanceTests` 與 `DecoderPerformanceTests` 是防止演算法或 I/O 發生災難性退化的寬鬆保護，不代表產品延遲目標。Release 模擬器的 Decoder p95 上限為 100 ms，完整 parser → matcher → decoder Pipeline p95 上限為 250 ms；測試直接 assert 全部樣本的 p95，並輸出 min、平均與 p95 供比較。SQLite open、冷／熱查詢、parser 與 matcher 也分別設有 Debug／Release 寬鬆門檻。加入 Essay 與讀音 provenance 後 production 資料庫約 140 MB，Extension 啟動仍只把音節 inventory 載入記憶體，詞條查詢維持依 `base_key` 與 `syllable_count` 使用索引。

`Generated/flickzhuyin.sqlite3` 是鍵盤執行所需的可重現資源，因此不加入 `.gitignore`；由於檔案超過 GitHub 一般 Git blob 的 100 MB 限制，repository 透過 Git LFS 追蹤它。clone 後需安裝 Git LFS 才能取得完整資料庫。

## 隱私

FlickZhuyin Keyboard Extension：

- 僅為觸覺回饋要求 Full Access
- 不使用網路
- 不儲存或傳送輸入內容
- 只以唯讀模式查詢 App bundle 內建的 SQLite 詞庫，不寫入資料庫
- 不使用 App Group、共享容器或雲端同步

開啟 Full Access 會解除 iOS 對第三方鍵盤的部分系統限制，但 FlickZhuyin 不會藉此讀取、儲存或傳送使用者輸入內容。

## 尚未支援

- bigram／語言模型排序與自動選字
- 使用者詞典、學習與持久化
- 簡繁轉換
- 數字及符號頁面
- 按鍵音與長按刪除
- iPad 專用版面
