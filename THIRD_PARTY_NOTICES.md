# 第三方授權聲明

FlickZhuyin 包含由第三方資料轉換而成的中文詞典。以下授權只適用於相應的第三方材料及其衍生資料，不適用於 FlickZhuyin 自有程式碼。

## Rime Terra Pinyin

- 名稱：Terra Pinyin（地球拼音）
- 作者／維護者：Rime contributors
- 來源：<https://github.com/rime/rime-terra-pinyin>
- 使用版本：commit `8a2c895ad7ee8e2b137d91be77f18f86b04d7fc9`
- 上游 repository 授權：GNU Lesser General Public License v3.0
- 授權全文：隨 App 一併提供的 `LICENSE`，或 <https://www.gnu.org/licenses/lgpl-3.0.html>

使用的原始檔為 `terra_pinyin.dict.yaml`。FlickZhuyin 將其中的拼音讀音轉換為無調注音與聲調，去除重複項目，並重新編排為 SQLite 資料庫，以供離線唯讀查詢。轉換工具及來源 manifest 可在 FlickZhuyin repository 的 `Tools/DictionaryCompiler/` 與 `Vendor/rime-terra-pinyin/` 找到。

## Rime Essay

- 名稱：Rime Essay（Rime 共用預設詞彙表）
- 作者／維護者：Rime contributors
- 來源：<https://github.com/rime/rime-essay>
- 使用版本：commit `e2652ea18609a879eae3e87db5d25b7fbc1a4f93`
- 上游 repository 授權：GNU Lesser General Public License v3.0
- 授權全文：隨 App 一併提供的 `LICENSE`，或 <https://www.gnu.org/licenses/lgpl-3.0.html>

使用的原始檔為 `essay.txt`，內容為共用詞彙與出現頻率。FlickZhuyin 以 Terra Pinyin 的讀音為 Essay 詞條離線標音，將詞頻以 log1p 函數正規化後合併進 SQLite 詞典，作為候選排序的權重；無法由 Terra 標音的詞條會被跳過並記錄於編譯報告。轉換工具及來源 manifest 可在 FlickZhuyin repository 的 `Tools/DictionaryCompiler/` 與 `Vendor/rime-essay/` 找到。

## CC-CEDICT-derived dictionary data

Terra Pinyin 的詞典 header 說明其參考 CC-CEDICT，並將詞典資料標示為 Creative Commons Attribution-ShareAlike 3.0 Unported（CC BY-SA 3.0）。

- CC-CEDICT：<https://cc-cedict.org/>
- 發布者：MDBG
- 授權：<https://creativecommons.org/licenses/by-sa/3.0/>

FlickZhuyin 所附的 `flickzhuyin.sqlite3` 同時包含 Terra Pinyin 與 Rime Essay 的衍生資料：Terra 詞條與讀音部分依 CC BY-SA 3.0 提供，Essay 詞頻部分依 LGPL-3.0 提供。修改內容包括拼音至注音轉換、離線自動標音、詞頻正規化、資料去重、欄位正規化、完整讀音與聲母（initial）索引建立及 SQLite 封裝。來源、commit、SHA-256、詞典版本及 compiler 版本均保存在 repository 的 `Vendor/` 下各 `SOURCE.json` 與 SQLite `metadata` table。

此資料不附帶任何擔保。CC BY-SA 3.0 的免責與責任限制條款適用。
