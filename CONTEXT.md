# ZOS Task 生命週期

本詞彙表記錄已確認的 task 生命週期用語。

## Language

**Task（核心執行緒）**：
ZOS 排程器管理的一條核心執行流程，具有一次建立到終止的生命週期。
_Avoid_：將 task 與 slot 視為同一物件。

**Task slot（task 欄位）**：
容納 task 的固定容量單位。不同生命週期的 task 可以先後占用同一個 slot。
_Avoid_：以 slot 表示其中某個 task 的完整生命週期。

**Task ID（task 識別值）**：
識別一次 task 生命週期的值。同一 slot 中的不同 task 具有不同 Task ID。
_Avoid_：以 slot 編號代替 Task ID。

**過期 Task ID**：
所指 task 的記錄已回收，因此已失效的 Task ID。
_Avoid_：以過期 Task ID 表示新 task 的識別值。

**Slot generation（slot 世代）**：
區分同一 slot 中不同 task 生命週期的識別部分。
_Avoid_：以建立順序或 slot 編號代替世代。

**停用 task slot**：
因世代已用盡而不能再容納新 task 的 slot。
_Avoid_：以停用表示 slot 暫時沒有 task。

**Task 終止**：
Task 不再恢復執行的生命週期事件。
_Avoid_：以終止表示 slot 已可重用。

**Task 回收**：
解除已終止 task 對 slot 與對應資源的占用。
_Avoid_：以回收表示 task 剛停止工作。

**Task stack 借用**：
其他 task 或 IRQ 對某個 task 的 stack 資料所持有的暫時存取關係。
_Avoid_：以借用表示資料所有權已轉移。

**累計 task 數**：
本次開機成功建立的 task 數，包含 boot task。Task 終止或回收不減少這個數量。
_Avoid_：以累計 task 數表示目前的容量占用。

**存活 task 數**：
已建立且尚未終止的 task 數，包含 boot task，以及等待執行、正在執行或等待事件的 task。
_Avoid_：以存活 task 數表示僅能立即執行的 task 數。
