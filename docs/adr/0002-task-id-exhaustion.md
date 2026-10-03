---
status: accepted
---

# 世代不循環，用盡後停用 task slot

為讓可直接複製的 Task ID 在本次開機期間持續拒絕舊生命週期，採 `u32` 的 slot 加 generation 編碼，generation 不循環。
最後有效世代的 task 回收後，停用該 slot，以有限次配置換取舊 ID 不會重新有效的保證。
更寬的 ID 能延後用盡，Linux 式引用則需要持有與釋放契約，本里程碑先保留固定 table 的 generation 方案。

低 2 位表示 slot，高 30 位表示 generation，保留全為 1 的 generation。
工作 slot 每格最多建立 1,073,741,823 次 task，boot ID 固定為 0。
世代用盡會減少可配置容量，因此立即重用的保證只適用於尚有可用世代的 slot。

本紀錄的完整用盡政策與容量例外已完成整體確認，契約與驗收條件見[設計文件](../task-lifecycle-plan.md)。
參考差異見 [Linux task 身分與回收調查](../linux-task-identity-research.md)。
