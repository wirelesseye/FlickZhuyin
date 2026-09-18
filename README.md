# FlickZhuyin

FlickZhuyin 是一個實驗性的 iOS 自訂注音鍵盤，使用類似日文假名鍵盤的 Flick（滑動）操作，在九宮格上輸入注音符號。

目前專案仍處於基礎輸入原型階段：中文模式只會把輸入的注音顯示為候選並原樣送出，尚未加入詞庫、漢字轉換或自動選字。

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

目前候選列只有一個候選，也不會檢查注音組合是否符合合法音節。

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
FlickZhuyinApp/        SwiftUI 容器 App 與測試文字欄
FlickZhuyinKeyboard/   UIKit Keyboard Extension、按鍵與 Flick UI
KeyboardCore/          鍵盤狀態機、按鍵模型及注音配置
FlickZhuyinTests/      狀態機與 Flick 映射單元測試
```

鍵盤核心不直接操作 `UITextDocumentProxy`，而是回傳輸入命令，再由 `KeyboardViewController` 寫入目前文件。這讓注音組字、模式切換與刪除行為可以獨立測試。

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

## 隱私

FlickZhuyin Keyboard Extension：

- 不要求 Full Access
- 不使用網路
- 不儲存或傳送輸入內容
- 不使用 App Group 或外部資料庫

## 尚未支援

- 注音詞庫與漢字候選
- 自動選字、聯想與自動修正
- 注音音節合法性檢查
- 數字及符號頁面
- 按鍵音、觸覺回饋與長按刪除
- iPad 專用版面
