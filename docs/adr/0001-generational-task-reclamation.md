---
status: accepted
---

# 以世代識別值支援 task 自動回收

為讓有限的靜態容量服務多次 task 生命週期，核心在確認退出 task 的 stack 可安全重用後，自動回收其 slot。
下一個 task 開始或恢復執行時，必須已能使用剛釋出的容量，首次啟動也適用。
世代用盡時的容量例外，列於 [ADR 0002](0002-task-id-exhaustion.md)。
公開 join、退出碼與父子關係另行設計。
Task ID 採 slot 加 generation，查詢必須拒絕舊 Task ID，以防止呼叫者把重用同一 slot 的新 task 誤認為舊 task。
此設計取代等待其他 task 明確收取的回收方式，也取代固定以 slot 識別 task 的方式，其代價是必須定義識別值的失效與世代用盡規則。

Task 必須在 entry 返回前，確保所有外部使用者停止存取其 stack 資料。
本里程碑由 task 負責這項生命週期責任，引用計數或資源登記機制另行設計。

本紀錄確認回收、識別與資源責任的設計方向。完整契約與驗收門檻見已確認的[設計文件](../task-lifecycle-plan.md)。
