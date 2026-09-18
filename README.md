# FlickZhuyin

FlickZhuyin 是一個實驗性的 iOS 自訂注音鍵盤，使用類似日文假名鍵盤的 Flick（滑動）操作，在九宮格上輸入注音符號。

目前專案仍處於基礎輸入原型階段：中文模式只會把輸入的注音顯示為候選並原樣送出。核心已具備注音音節解析、詞庫查詢與詞格（word lattice）建立，但尚未接到鍵盤 UI，也還沒有自動選字。

## 功能

- 注音九宮格 Flick 輸入
- 中文與全鍵盤 ABC 模式切換
- 注音候選列
- 第一至第四聲 Flick 選擇
- 獨立輕聲鍵
- Shift、Caps Lock、刪除、空白與 Return
- iPhone 直向與橫向版面
- 深色及淺色模式
- 不需要「允許完整取用」

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
7. 在文字欄中使用地球鍵切換至 FlickZhuyin。

鍵盤不需要開啟「允許完整取用」。容器 App 本身只提供一個文字欄，方便測試鍵盤。

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

### 候選與確認

- 尚未確認的注音只會顯示在候選列，不會立即送進文字欄。
- 點擊候選即可原樣送出整串注音。
- 有未確認內容時切換至 ABC 或按 Return，會先送出注音。
- 刪除鍵會先刪除候選列最後一個注音或聲調；候選為空時才刪除文字欄內容。
- 沒有候選時，中央按鍵是一般空白鍵。

目前候選列只有一個候選。中文輸入核心已能解析注音音節與查詢詞庫，但尚未接到候選列。

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
KeyboardCore/ChineseInput/     音節解析、詞庫查詢與詞格（實驗中）
FlickZhuyinTests/              狀態機、Flick 映射與中文輸入核心測試
Tools/DictionaryCompiler/      Rime 詞典離線編譯器與 Python 測試
Vendor/rime-terra-pinyin/      鎖定版本的上游詞典、授權與 manifest
Generated/                     編譯產物（SQLite 詞典與 report）
```

鍵盤核心不直接操作 `UITextDocumentProxy`，而是回傳輸入命令，再由 `KeyboardViewController` 寫入目前文件。這讓注音組字、模式切換與刪除行為可以獨立測試。

中文輸入核心位於 `KeyboardCore/ChineseInput/`：

- `SyllableParser` 從詞庫的合法音節清單建立音節格（syllable lattice），支援省略聲調、部分聲調與完整聲調。
- `SQLiteLexiconStore` 以唯讀模式開啟 bundle 內的 SQLite 詞典，只把 400 多個合法無調注音載入記憶體，發音資料則按需求查詢。
- `DictionaryMatcher` 沿音節格查詢詞庫，產生可含多詞、多讀音的詞格，不做 `5^n` 聲調展開。

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
- 候選確認、刪除、Return 與模式切換
- SQLite 詞庫查詢（完整聲調、省略聲調、混合聲調、輕聲、多音字）
- 音節格切分、incomplete/fallback 連通性
- 詞格的多字詞、去重與展開上限
- production 詞典的 metadata、entry count 與代表性查詢

Python 詞典編譯器另有單元測試與完整 corpus 驗證：

```sh
python3 -m unittest discover \
  -s Tools/DictionaryCompiler/tests \
  -t Tools/DictionaryCompiler/tests
```

## 第三方資料

中文詞庫來自 Rime 的 Terra Pinyin，以 pinned commit 方式鎖定：

- Repository：<https://github.com/rime/rime-terra-pinyin>
- Commit：`8a2c895ad7ee8e2b137d91be77f18f86b04d7fc9`
- 詞典：<https://raw.githubusercontent.com/rime/rime-terra-pinyin/8a2c895ad7ee8e2b137d91be77f18f86b04d7fc9/terra_pinyin.dict.yaml>
- Repository 授權：LGPL-3.0（`Vendor/rime-terra-pinyin/LICENSE`）
- 詞典 header 另註明參考 CC-CEDICT，採 CC BY-SA 3.0

`Vendor/rime-terra-pinyin/SOURCE.json` 記錄來源、commit、SHA-256 與詞典版本；`build` 會驗證 source 的 SHA-256，`fetch` 只能在明確更新 commit 時使用，一般 build 與 App 執行期都不連網。完整 attribution、修改說明與授權連結見 `THIRD_PARTY_NOTICES.md`；同一份 notices 與上游 LGPL 授權會打包進主 App 及 Keyboard Extension，App 內可從「第三方授權」開啟閱讀。SQLite 衍生資料的 sidecar 授權位於 `Generated/LICENSE.md`。發佈前仍需人工確認最終合規方式。

FlickZhuyin 自有程式碼目前採 repository 根目錄 `LICENSE` 所列的 All Rights Reserved 條款；第三方材料及衍生詞典不受該條款涵蓋。

## 詞典編譯

重建 production 詞典與 report（不需要網路）：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build \
  --source Vendor/rime-terra-pinyin/terra_pinyin.dict.yaml \
  --manifest Vendor/rime-terra-pinyin/SOURCE.json \
  --output Generated/flickzhuyin.sqlite3 \
  --report Generated/dictionary-report.json
```

在相同 Python 與 SQLite library 版本下，相同 source bytes 與 compiler 版本會產生 byte-for-byte 相同的 SQLite 檔案；不同 SQLite library 版本只保證 schema、metadata、排序後資料內容與 report 相同，不保證實體 page layout 或檔案 hash 相同。output 只加入 `FlickZhuyinKeyboard` 的 bundle resources。Swift 測試使用的迷你 fixture 由下列命令產生，Python 測試以 logical database snapshot 檢查它是否與 fixture source 同步：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build \
  --source Tools/DictionaryCompiler/tests/fixtures/zhuyin_tests.dict.yaml \
  --manifest Tools/DictionaryCompiler/tests/fixtures/zhuyin_tests.SOURCE.json \
  --output FlickZhuyinTests/Fixtures/flickzhuyin-tests.sqlite3 \
  --report /tmp/flickzhuyin-fixture-report.json
```

## 隱私

FlickZhuyin Keyboard Extension：

- 不要求 Full Access
- 不使用網路
- 不儲存或傳送輸入內容
- 只以唯讀模式查詢 App bundle 內建的 SQLite 詞庫，不寫入資料庫
- 不使用 App Group、共享容器或雲端同步

## 尚未支援

- 將詞格接到鍵盤 UI 顯示漢字候選
- Viterbi／beam search 排序與自動選字
- unigram/bigram 語言模型、使用者詞典與學習
- 簡繁轉換
- 數字及符號頁面
- 按鍵音、觸覺回饋與長按刪除
- iPad 專用版面
